#!/usr/bin/env ruby
# Local workflow contract tests. Uses macOS's bundled Ruby and YAML parser.
require 'yaml'
require 'json'
require 'minitest/autorun'
require 'strscan'
require 'open3'
require 'tmpdir'

# Evaluate only the boolean/string subset used by the release job condition.
# Unknown syntax fails closed. This is a local policy probe, not a runner:
# actionlint validates GitHub syntax; the post-merge release proves execution.
# String comparisons support ASCII only. Both boolean operands are evaluated;
# short-circuit semantics remain outside this policy probe.
class WorkflowCondition
  class Error < ArgumentError; end
  attr_reader :tree

  def initialize(expression)
    raise Error, 'workflow probe requires a string condition' unless expression.is_a?(String)
    @input = StringScanner.new(expression.strip.sub(/\A\$\{\{\s*/, '').sub(/\s*\}\}\z/, ''))
    @tree = disjunction
    raise Error, 'unparsed condition' unless @input.rest.strip.empty?
  end

  def evaluate(context)
    value = evaluate_node(tree, context)
    raise Error, 'condition is not boolean' unless [true, false].include?(value)
    value
  end

  def string_literals(node = tree)
    return node[1].is_a?(String) ? [node[1]] : [] if node.first == :literal
    node.drop(1).select { |child| child.is_a?(Array) }.flat_map { |child| string_literals(child) }
  end

  def self.fold(value)
    raise Error, 'workflow probe requires string operands' unless value.is_a?(String)
    raise Error, 'workflow probe supports ASCII strings only' unless value.ascii_only?
    value.tr('A-Z', 'a-z')
  end

  private

  def evaluate_node(node, context)
    kind, *children = node
    return children.first if kind == :literal
    return context.fetch(children.first.delete_prefix('github.')) if kind == :property
    left, right = children.map { |child| evaluate_node(child, context) }
    case kind
    when :or then left || right
    when :and then left && right
    when :starts_with then self.class.fold(left).start_with?(self.class.fold(right))
    when :contains then self.class.fold(left).include?(self.class.fold(right))
    when :==, :!=
      equal = left.is_a?(String) && right.is_a?(String) ? self.class.fold(left) == self.class.fold(right) : left == right
      kind == :== ? equal : !equal
    else raise Error, 'unsupported node: ' + kind.inspect
    end
  end

  def take(pattern)
    @input.skip(/\s*/)
    @input.scan(pattern)
  end

  def expect(pattern)
    take(pattern) || raise(Error, 'expected ' + pattern.inspect + ': ' + @input.rest)
  end

  def disjunction
    value = conjunction
    while take(/\|\|/)
      right = conjunction
      value = [:or, value, right]
    end
    value
  end

  def conjunction
    value = comparison
    while take(/&&/)
      right = comparison
      value = [:and, value, right]
    end
    value
  end

  def comparison
    left = atom
    operator = take(/==|!=/)
    return left unless operator
    right = atom
    [operator.to_sym, left, right]
  end

  def atom
    if take(/\(/)
      value = disjunction
      expect(/\)/)
      value
    elsif (function = take(/(?:startsWith|contains)\(/i))
      value = atom
      expect(/,/)
      prefix = atom
      expect(/\)/)
      [function.downcase.start_with?('contains') ? :contains : :starts_with, value, prefix]
    elsif (string = take(/'(?:[^']|'')*'/))
      literal = string[1...-1].gsub("''", "'")
      self.class.fold(literal) # Reject unsupported literals before admission is evaluated.
      [:literal, literal]
    elsif (property = take(/github\.[a-z_]+/))
      [:property, property]
    elsif (boolean = take(/true\b|false\b/))
      [:literal, boolean == 'true']
    else
      raise Error, 'unsupported condition: ' + @input.rest
    end
  end
end

class WorkflowTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CASK_INPUTS = %w[/VERSION /Pensieve/Info.plist /release/homebrew/pensieve.rb
                   /release/minimum-macos.txt
                   /script/release.sh /script/release_recovery.sh /script/release_state.py
                   /script/verify_update.swift /script/minimum_system.py].freeze
  CASK_RUN = <<~'SH'.freeze
    set -euo pipefail
    ./script/release.sh --expect-tag "$GITHUB_REF_NAME" --publish-cask-only
  SH
  CASK_ENV = { 'GH_TOKEN' => '${{ github.token }}',
               'TAP_GH_TOKEN' => '${{ secrets.RELEASE_REPO_TOKEN }}' }.freeze

  def setup
    @paths = Dir[File.join(ROOT, '.github/workflows/*.{yml,yaml}')].sort
    @workflows = @paths.to_h { |path| [File.basename(path), YAML.load_file(path)] }
    @release = @workflows.fetch('release.yml').fetch('jobs').fetch('release')
    @cask = @workflows.fetch('release.yml').fetch('jobs').fetch('cask')
  end

  def strings(value)
    case value
    when Hash then value.flat_map { |key, child| strings(key) + strings(child) }
    when Array then value.flat_map { |child| strings(child) }
    when String then [value]
    else []
    end
  end

  def triggers(workflow)
    # Psych uses YAML 1.1, in which the unquoted key "on" is boolean true.
    workflow.fetch('on') { workflow.fetch(true) }
  end

  def test_releases_run_one_at_a_time
    assert_equal({ 'group' => 'release', 'cancel-in-progress' => false },
                 @workflows.fetch('release.yml')['concurrency'])
  end

  def assert_secret_confinement(workflows)
    # Whole-context access and reusable-job inheritance must be refused too.
    [{ 'secrets' => 'inherit' },
     { 'env' => { 'LEAK' => '${{ toJSON(secrets) }}' } }].each do |fixture|
      refute_empty secret_references(fixture)
    end
    workflows.each do |name, workflow|
      refute_includes strings(triggers(workflow)), 'pull_request_target'
      outside_release = Marshal.load(Marshal.dump(workflow))
      if name == 'release.yml'
        %w[release cask].each { |job| outside_release.fetch('jobs').delete(job) }
      end
      assert_empty secret_references(outside_release), name
    end
    expected = {
      'release' => %w[DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD NOTARY_API_KEY_P8
                      NOTARY_ISSUER_ID NOTARY_KEY_ID SPARKLE_PRIVATE_KEY],
      'cask' => %w[RELEASE_REPO_TOKEN]
    }
    expected.each do |job_name, secrets|
      job = workflows.fetch('release.yml').fetch('jobs').fetch(job_name)
      actual = strings(job).join("\n").scan(/secrets\.([A-Z_0-9]+)/).flatten.uniq
      assert_equal secrets.sort, actual.sort, job_name + ': secret inventory'
    end
  end

  def test_secrets_are_confined_to_release_jobs
    assert_secret_confinement(@workflows)
  end

  def secret_references(value)
    strings(value).grep(/\bsecrets\b/i)
  end

  def test_public_hygiene_push_contract
    workflow = @workflows.fetch('public-hygiene.yml')
    assert_equal({ 'push' => nil }, triggers(workflow))
    assert_equal({ 'contents' => 'read' }, workflow.fetch('permissions'))
    refute workflow.key?('concurrency')
    assert_empty secret_references(workflow)
    assert_equal ['hygiene'], workflow.fetch('jobs').keys
    job = workflow.fetch('jobs').fetch('hygiene')
    assert_equal 15, job.fetch('timeout-minutes', nil)
    refute job.key?('if')
    refute job.key?('concurrency')
    refute job.fetch('continue-on-error', false)
    assert_equal 'ubuntu-latest', job.fetch('runs-on')
    assert_equal({ 'contents' => 'read' }, job.fetch('permissions'))
    steps = job.fetch('steps')
    assert_equal ['Deleted ref', 'Checkout pushed head', 'Check pushed commits and tree'],
                 steps.map { |step| step.fetch('name') }
    assert_equal 'github.event.deleted', steps[0].fetch('if')
    steps.each { |step| refute step.fetch('continue-on-error', false) }
    assert_equal '!github.event.deleted', steps[1].fetch('if')
    assert_match(%r{\Aactions/checkout@}, steps[1].fetch('uses'))
    assert_equal({ 'ref' => '${{ github.event.after }}', 'fetch-depth' => 0,
                   'persist-credentials' => false }, steps[1].fetch('with'))
    assert_equal '!github.event.deleted', steps[2].fetch('if')
    assert_equal({ 'BEFORE' => '${{ github.event.before }}',
                   'AFTER' => '${{ github.event.after }}',
                   'DEFAULT_BRANCH' => '${{ github.event.repository.default_branch }}' }, steps[2].fetch('env'))
    assert_equal 'python3 -B script/public_hygiene_push.py --before "$BEFORE" --after "$AFTER" --default-branch "$DEFAULT_BRANCH"',
                 steps[2].fetch('run')
  end

  def test_secrets_require_release_environment
    @workflows.each do |name, workflow|
      workflow.fetch('jobs').each do |job_name, job|
        next if secret_references(job).empty?
        environment = job.fetch('environment', nil)
        environment = environment['name'] if environment.is_a?(Hash)
        assert_equal 'release', environment, "#{name}/#{job_name}: secrets require release approval"
      end
    end
  end

  def assert_approved_secret_bindings(workflows)
    allowed = {
      'release' => { 'Sign, notarize, and publish' => %w[DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD
        NOTARY_API_KEY_P8 NOTARY_ISSUER_ID NOTARY_KEY_ID SPARKLE_PRIVATE_KEY] },
      'cask' => { 'Publish Homebrew cask' => %w[RELEASE_REPO_TOKEN] }
    }
    workflows.each do |name, workflow|
      outside = Marshal.load(Marshal.dump(workflow))
      if name == 'release.yml'
        allowed.each do |job_name, bindings|
          steps = outside.fetch('jobs').fetch(job_name).fetch('steps')
          bindings.each do |step_name, secrets|
            holders = steps.select { |step| step['name'] == step_name }
            assert_equal 1, holders.length, job_name + ': exactly one secret step'
            secrets.each do |secret|
              key = secret == 'RELEASE_REPO_TOKEN' ? 'TAP_GH_TOKEN' : secret
              expected = '${{ secrets.' + secret + ' }}'
              assert_equal expected, holders.first.fetch('env').fetch(key)
              holders.first['env'].delete(key)
            end
          end
        end
      end
      assert_empty secret_references(outside), name + ': secret context outside named bindings'
    end
  end

  def test_only_named_secrets_in_approved_steps
    assert_approved_secret_bindings(@workflows)
  end

  def assert_tap_token_scope(workflows)
    cask = workflows.fetch('release.yml').fetch('jobs').fetch('cask')
    steps = cask.fetch('steps')
    holders = steps.select { |step| strings(step).any? { |value| value.match?(/RELEASE_REPO_TOKEN/i) } }
    assert_equal ['Publish Homebrew cask'], holders.map { |step| step.fetch('name') }
    assert_equal CASK_ENV, holders.first.fetch('env')
    assert_equal CASK_RUN, holders.first.fetch('run')
    workflows.each do |name, workflow|
      outside = Marshal.load(Marshal.dump(workflow))
      if name == 'release.yml'
        outside.fetch('jobs').fetch('cask').fetch('steps').reject! { |step| step['name'] == 'Publish Homebrew cask' }
      end
      assert_empty strings(outside).grep(/RELEASE_REPO_TOKEN/i), name + ': tap token outside cask step'
    end
  end

  def assert_checkout_credentials(workflows)
    workflows.each_value do |workflow|
      workflow.fetch('jobs').each_value do |job|
        job.fetch('steps').each do |step|
          next unless step.fetch('uses', '').start_with?('actions/checkout@')
          assert_equal false, step.fetch('with').fetch('persist-credentials')
        end
      end
    end
  end

  def test_tap_token_and_checkout_scope
    assert_tap_token_scope(@workflows)
    assert_checkout_credentials(@workflows)
  end

  def assert_cask_job_shape(workflows)
    assert_equal %w[concurrency jobs name on permissions],
                 workflows.fetch('release.yml').keys.map { |key| key == true ? 'on' : key }.sort
    jobs = workflows.fetch('release.yml').fetch('jobs')
    assert_equal %w[cask release], jobs.keys.sort
    cask = jobs.fetch('cask')
    assert_equal %w[environment if name needs permissions runs-on steps timeout-minutes], cask.keys.sort
    assert_equal 'release', cask.fetch('needs')
    assert_release_admission(cask.fetch('if'), 'jaredatch/pensieve', 'cask gate', stable_only: true)
    assert_equal 'release', cask.fetch('environment')
    assert_equal({ 'contents' => 'read' }, cask.fetch('permissions'))
    assert_equal 'macos-26', cask.fetch('runs-on')
    steps = cask.fetch('steps')
    assert_equal ['Checkout cask inputs', 'Download DMG artifact', 'Publish Homebrew cask'],
                 steps.map { |step| step.fetch('name') }
    steps.take(2).each { |step| assert_equal %w[name timeout-minutes uses with], step.keys.sort }
    assert_equal %w[env name run timeout-minutes], steps.last.keys.sort
    assert_match(%r{\Aactions/checkout@}, steps.first.fetch('uses'))
    assert_equal({ 'fetch-depth' => 1, 'persist-credentials' => false,
                   'sparse-checkout-cone-mode' => false,
                   'sparse-checkout' => CASK_INPUTS.join("\n") + "\n" }, steps.first.fetch('with'))
    assert_match(%r{\Aactions/download-artifact@}, steps[1].fetch('uses'))
    assert_equal({ 'name' => 'dmg', 'path' => 'build/dist' }, steps[1].fetch('with'))
    assert_equal CASK_RUN, steps.last.fetch('run')
    assert_equal CASK_ENV, steps.last.fetch('env')

    release_steps = jobs.fetch('release').fetch('steps')
    uploads = release_steps.select { |step| step.fetch('uses', '').start_with?('actions/upload-artifact@') }
    assert_equal 1, uploads.length
    upload = uploads.first
    assert_equal 'always()', upload.fetch('if')
    assert_equal({ 'name' => 'dmg', 'path' => 'build/dist/*.dmg',
                   'if-no-files-found' => 'ignore', 'retention-days' => 14,
                   'overwrite' => true }, upload.fetch('with'))
    signer = release_steps.find { |step| step['name'] == 'Sign, notarize, and publish' }
    assert_operator release_steps.index(upload), :>, release_steps.index(signer)
  end

  def test_cask_job_is_isolated_and_consumes_release_artifact
    assert_cask_job_shape(@workflows)
  end

  def test_release_workflow_top_level_keys_are_pinned
    assert_cask_job_shape(@workflows)
    [{ 'defaults' => { 'run' => { 'working-directory' => 'build/dist' } } },
     { 'defaults' => { 'run' => { 'shell' => 'bash build/dist/tool {0}' } } },
     { 'env' => { 'BASH_ENV' => 'build/dist/startup.sh' } }].each do |addition|
      fixture = Marshal.load(Marshal.dump(@workflows))
      fixture.fetch('release.yml').merge!(addition)
      assert_raises(Minitest::Assertion, addition.inspect) { assert_cask_job_shape(fixture) }
    end
  end

  def test_unsupported_cask_conditions_are_contract_refusals
    ['always()', 'unknown(github.ref)', "github.repository ==", "github.repository == 'é/repo'"].each do |condition|
      fixture = Marshal.load(Marshal.dump(@workflows))
      fixture.fetch('release.yml').fetch('jobs').fetch('cask')['if'] = condition
      error = assert_raises(Minitest::Assertion) { assert_cask_job_shape(fixture) }
      assert_includes error.message, condition
      assert_includes error.message, 'cannot evaluate condition'
    end
  end

  def assert_rerun_artifact_replacement(workflow)
    uploads = workflow.fetch('jobs').fetch('release').fetch('steps').select do |step|
      step.fetch('uses', '').start_with?('actions/upload-artifact@')
    end
    assert_equal 1, uploads.length
    assert_equal 'dmg', uploads.first.fetch('with').fetch('name')
    assert_equal true, uploads.first.fetch('with').fetch('overwrite', false),
                 'a rerun must replace the prior attempt artifact before the cask dependency can succeed'
  end

  def test_rerun_replaces_dmg_artifact
    workflow = @workflows.fetch('release.yml')
    assert_rerun_artifact_replacement(workflow)
    [false, nil].each do |value|
      fixture = Marshal.load(Marshal.dump(workflow))
      upload = fixture.fetch('jobs').fetch('release').fetch('steps').last
      value.nil? ? upload.fetch('with').delete('overwrite') : upload.fetch('with')['overwrite'] = value
      assert_raises(Minitest::Assertion) { assert_rerun_artifact_replacement(fixture) }
    end
  end

  def test_public_and_tap_credentials_have_separate_bindings
    step = @cask.fetch('steps').last
    assert_equal CASK_ENV, step.fetch('env')
    wrong_bindings = [{ 'GH_TOKEN' => '${{ secrets.RELEASE_REPO_TOKEN }}' },
                      { 'TAP_GH_TOKEN' => '${{ github.token }}' },
                      { 'GH_TOKEN' => nil }, { 'TAP_GH_TOKEN' => nil }]
    wrong_bindings.each do |bindings|
      fixture = Marshal.load(Marshal.dump(@workflows))
      env = fixture.fetch('release.yml').fetch('jobs').fetch('cask').fetch('steps').last.fetch('env')
      bindings.each { |key, value| value.nil? ? env.delete(key) : env[key] = value }
      assert_raises(Minitest::Assertion) { assert_tap_token_scope(fixture) }
    end
  end

  def test_both_jobs_use_the_shared_tag_guard
    signer = @release.fetch('steps').find { |step| step['name'] == 'Sign, notarize, and publish' }
    assert_equal './script/release.sh --check-tag "$GITHUB_REF_NAME"', signer.fetch('run').lines.reject { |line| line.strip.empty? }[1].strip, 'tag check must precede secret setup'
    [signer, @cask.fetch('steps').last].each do |step|
      assert_match(/\.\/script\/release\.sh[^\n]*(?:\\\n\s*)?--expect-tag "\$GITHUB_REF_NAME"/, step.fetch('run'))
      refute_includes step.fetch('run'), 'expected_tag='
    end
  end

  def test_cask_gate_matches_shared_literal_publication_channels
    cases = JSON.parse(File.read(File.join(ROOT, 'PensieveTests/Fixtures/release-versions.json')))
    assert_operator cases.length, :>=, 18
    condition = WorkflowCondition.new(@cask.fetch('if'))
    cases.each do |version, (channel, _prerelease)|
      context = { 'repository' => 'jaredatch/pensieve', 'event_name' => 'push',
                  'ref_type' => 'tag', 'ref' => 'refs/tags/v' + version }
      assert_equal channel.empty?, condition.evaluate(context), "#{version}: literal publication channel #{channel.inspect}"
    end
  end

  def test_literal_publication_channels_agree_with_prerelease_flags
    cases = JSON.parse(File.read(File.join(ROOT, 'PensieveTests/Fixtures/release-versions.json')))
    cases.each do |version, (channel, prerelease)|
      assert_includes [true, false], prerelease, version
      assert_equal channel.empty?, !prerelease, "#{version}: fixture channel and prerelease disagree"
    end
  end

  def test_non_string_condition_operands_are_named_refusals
    ['contains(github.ref, true)', 'startsWith(false, github.ref)', true, nil].each do |condition|
      error = assert_raises(Minitest::Assertion) { assert_release_admission(condition, 'jaredatch/pensieve', 'typed gate') }
      assert_includes error.message, condition.inspect
      assert_includes error.message, 'cannot evaluate condition'
    end
  end

  def test_unexpected_probe_errors_are_not_contract_refusals
    stub :release_event_mismatches, ->(*) { raise NoMethodError, 'unexpected probe defect' } do
      assert_raises(NoMethodError) { assert_release_admission('true', 'owner/repo', 'broken probe') }
    end
  end

  def test_cask_prereleases_are_skipped_before_runner_start
    condition = WorkflowCondition.new(@cask.fetch('if'))
    %w[v1.0.0-alpha v1.0.0-beta.1 v1.0.0-rc.1 V1.0.0-BETA.1].each do |tag|
      context = { 'repository' => 'jaredatch/pensieve', 'event_name' => 'push',
                  'ref_type' => 'tag', 'ref' => 'refs/tags/' + tag }
      assert_equal false, condition.evaluate(context), 'prerelease must not provision the cask runner: ' + tag
    end
    assert_release_admission(@cask.fetch('if'), 'jaredatch/pensieve', 'cask stable/fork matrix', stable_only: true)
    workflow_source = File.read(File.join(ROOT, '.github/workflows/release.yml'))
    assert_equal 2, workflow_source.scan('# Canonical source repository; PLAN-45 updates this at the cutover.').length
  end

  def test_cask_job_rejects_extra_execution_secrets_and_checkout_files
    fixtures = {
      'build step' => ->(job) { job['steps'].insert(1, { 'name' => 'Build', 'run' => 'xcodebuild build' }) },
      'install step' => ->(job) { job['steps'].insert(1, { 'name' => 'Install', 'run' => 'brew install xcodegen' }) },
      'build in approved step' => ->(job) { job['steps'].last['run'] += "xcodebuild build\n" },
      'second secret' => ->(job) { job['steps'].last['env']['LEAK'] = '${{ secrets.SPARKLE_PRIVATE_KEY }}' },
      'persisted credentials' => ->(job) { job['steps'].first['with']['persist-credentials'] = true },
      'full checkout' => ->(job) { job['steps'].first['with'].delete('sparse-checkout') },
      'cone checkout' => ->(job) { job['steps'].first['with']['sparse-checkout-cone-mode'] = true },
      'extra checkout file' => ->(job) { job['steps'].first['with']['sparse-checkout'] += "/project.yml\n" },
      'filter overriding sparse checkout' => ->(job) { job['steps'].first['with']['filter'] = 'blob:none' },
      'foreign artifact run' => ->(job) { job['steps'][1]['with']['run-id'] = 1234 },
      'failure admission' => ->(job) { job['if'] = 'always()' },
      'no dependency' => ->(job) { job['needs'] = [] },
      'no environment' => ->(job) { job['environment'] = 'other' },
      'write permission' => ->(job) { job['permissions']['contents'] = 'write' }
    }
    fixtures.each do |label, mutate|
      workflows = Marshal.load(Marshal.dump(@workflows))
      mutate.call(workflows.fetch('release.yml').fetch('jobs').fetch('cask'))
      assert_raises(Minitest::Assertion, label) { assert_cask_job_shape(workflows) }
    end
  end

  def test_secret_context_abuse_is_rejected_in_other_scopes
    leaks = [{ 'env' => { 'LEAK' => '${{ secrets.SPARKLE_PRIVATE_KEY }}' } },
             { 'env' => { 'LEAK' => "${{ secrets['RELEASE_REPO_TOKEN'] }}" } },
             { 'secrets' => 'inherit' }, { 'env' => { 'LEAK' => '${{ toJSON(secrets) }}' } }]
    leaks.each do |leak|
      %w[workflow other_job release_job cask_job other_release_step other_cask_step].each do |scope|
        workflows = Marshal.load(Marshal.dump(@workflows))
        workflow = workflows.fetch('release.yml')
        jobs = workflow.fetch('jobs')
        case scope
        when 'workflow' then workflow.merge!(leak)
        when 'other_job' then jobs['unapproved'] = leak
        when 'release_job' then jobs.fetch('release').merge!(leak)
        when 'cask_job' then jobs.fetch('cask').merge!(leak)
        when 'other_release_step' then jobs.fetch('release')['steps'].first.merge!(leak)
        when 'other_cask_step' then jobs.fetch('cask')['steps'].first.merge!(leak)
        end
        assert_raises(Minitest::Assertion, scope + ': ' + leak.inspect) { assert_approved_secret_bindings(workflows) }
      end
    end
  end

  def assert_release_timeout_budgets(workflow)
    workflow.fetch('jobs').each do |job_name, job|
      budgets = job.fetch('steps').map { |step| step.fetch('timeout-minutes', 0) }
      budgets.each { |minutes| assert_operator minutes, :>, 0, job_name }
      assert_operator job.fetch('timeout-minutes') - budgets.sum, :>=, 10, job_name + ': timeout headroom'
    end
    signer = workflow.fetch('jobs').fetch('release').fetch('steps').find { |step| step['name'] == 'Sign, notarize, and publish' }
    assert_operator signer.fetch('timeout-minutes'), :>=, 60
  end

  def test_release_timeout_budgets_count_every_step
    workflow = @workflows.fetch('release.yml')
    assert_release_timeout_budgets(workflow)
    %w[release cask].each do |job_name|
      fixture = Marshal.load(Marshal.dump(workflow))
      job = fixture.fetch('jobs').fetch(job_name)
      job['timeout-minutes'] = job['steps'].sum { |step| step.fetch('timeout-minutes') } + 9
      assert_raises(Minitest::Assertion, job_name) { assert_release_timeout_budgets(fixture) }
      fixture = Marshal.load(Marshal.dump(workflow))
      fixture.fetch('jobs').fetch(job_name)['steps'].last.delete('timeout-minutes')
      assert_raises(Minitest::Assertion, job_name + ': missing timeout') { assert_release_timeout_budgets(fixture) }
    end
    fixture = Marshal.load(Marshal.dump(workflow))
    fixture.fetch('jobs').fetch('release')['steps'].find { |step| step['name'] == 'Sign, notarize, and publish' }['timeout-minutes'] = 59
    assert_raises(Minitest::Assertion, 'short notarization bound') { assert_release_timeout_budgets(fixture) }
  end

  def test_release_event_matrix
    condition = @release.fetch('if')
    # PLAN-45 changes this expectation and the workflow together at cutover.
    canonical = 'jaredatch/pensieve'
    assert_release_admission(condition, canonical, 'live workflow')
    assert_release_admission(@cask.fetch('if'), canonical, 'live cask workflow', stable_only: true)
    equality = "github.repository == '#{canonical}'"
    event_guard = "github.event_name == 'push' && github.ref_type == 'tag' && " \
                  "startsWith(github.ref, 'refs/tags/v')"
    passing = {
      'reversed operands' => "'#{canonical}' == github.repository",
      'mixed-case name' => "github.repository == '#{canonical.upcase}'",
      'parenthesized equality' => "(#{equality})",
      'negated inequality' => "(github.repository != '#{canonical}') == false",
      'redundant denylist' => "#{equality} && github.repository != 'mallory/x'"
    }
    failing = {
      'prefix disjunct' => "#{equality} || startsWith(github.repository, 'mallory/')",
      'second repository' => "#{equality} || github.repository == 'mallory/x'",
      'denylist' => "github.repository != 'evil/x' && github.repository != 'mallory/x'",
      'ref disjunct' => "#{equality} || github.ref == 'refs/tags/v9-x'",
      'typo' => "github.repository == '#{canonical.chop}'",
      'repository starts with canonical' => "startsWith(github.repository, '#{canonical}')",
      'canonical starts with repository' => "startsWith('#{canonical}', github.repository)"
    }
    passing.each do |label, clause|
      assert_release_admission("(#{clause}) && #{event_guard}", canonical, label)
    end
    assert_release_admission("#{equality} && github.event_name == 'push' && github.ref_type == 'tag' && startsWith(github.ref, 'REFS/TAGS/V')",
                             canonical, 'upper-case tag prefix')
    failing.each do |label, clause|
      assert_over_admission("(#{clause}) && #{event_guard}", canonical, label)
    end
    whole_name = /(?<![a-z0-9_.\/-])#{Regexp.escape(canonical)}(?![a-z0-9_.\/-])/i
    assert_equal 2, @paths.sum { |path| File.read(path).scan(whole_name).length }
  end

  def assert_release_admission(condition, canonical, label, stable_only: false)
    begin
      mismatch = release_event_mismatches(condition, canonical, stable_only: stable_only).first
    rescue WorkflowCondition::Error => error
      flunk "#{label}: cannot evaluate condition #{condition.inspect}: #{error.message}"
    end
    assert mismatch.nil?, -> { "#{label}: release matrix mismatch: #{mismatch.inspect}" }
  end

  def assert_over_admission(condition, canonical, label)
    mismatch = release_event_mismatches(condition, canonical).find do |context|
      context['expected'] == false && context['actual'] == true
    end
    assert mismatch, -> { "#{label}: failing fixture must produce an over-admission; example mismatch: " \
                          "#{release_event_mismatches(condition, canonical).first.inspect}" }
  end

  def repository_parts(canonical)
    WorkflowCondition.fold(canonical)
    unless canonical.match?(%r{\A[^/\s\x00-\x1f\x7f]+/[^/\s\x00-\x1f\x7f]+\z})
      raise ArgumentError, 'canonical repository requires owner/name without whitespace or controls'
    end
    canonical.split('/')
  end

  def repository_witnesses(strings)
    folded = strings.map { |string| WorkflowCondition.fold(string) }.uniq
    # All literal prefixes, plus one unseen outgoing ASCII edge per prefix,
    # witness equality and startsWith in either direction. Candidates exclude A-Z,
    # which fold onto lowercase branches. A node with every folded ASCII edge
    # needs no extra edge: its existing child prefixes already cover them all.
    prefixes = folded.flat_map { |string| (0..string.length).map { |length| string[0, length] } }.uniq
    fresh = prefixes.map do |prefix|
      following = folded.select { |string| string.start_with?(prefix) }.map { |string| string[prefix.length] }
      character = (0..127).reject { |code| (65..90).include?(code) }.map(&:chr).find { |candidate| !following.include?(candidate) }
      prefix + character if character
    end.compact
    (prefixes + fresh).uniq
  end

  def release_event_mismatches(condition, canonical, stable_only: false)
    parsed = WorkflowCondition.new(condition)
    literals = parsed.string_literals
    owner, name = repository_parts(canonical)
    repositories = [canonical, "octocat/#{name}", "#{owner}/fork", "#{canonical}-fork", '',
                    'jaredatch/pensieve', 'JaredAtch/Pensieve', 'alice/pensieve-app', 'evil/x', 'mallory/x']
    events = %w[push pull_request pull_request_target workflow_dispatch schedule release workflow_run]
    types = %w[tag branch]
    refs = ['refs/tags/v1.2.3', 'REFS/TAGS/V1.2.3', 'ReFs/TaGs/V1.2.3-beta.1',
            'refs/tags/v1.2.3-beta.1', 'refs/tags/v', 'refs/tags/other', 'REFS/TAGS/OTHER',
            'refs/heads/v1.2.3', 'refs/heads/master', 'refs/pull/1/merge', '']
    refs = (refs + literals.grep(%r{\Arefs/}i)).uniq
    witnesses = repository_witnesses(literals + events + types + refs + repositories)
    repositories = (witnesses + repositories).uniq
    Enumerator.new do |mismatches|
      repositories.product(events, types, refs) do |repo, event, type, ref|
        context = { 'repository' => repo, 'event_name' => event, 'ref_type' => type, 'ref' => ref }
        # casecmp is the independent ASCII-domain oracle; don't reuse the evaluator's fold.
        expected = repo.casecmp(canonical).zero? && event == 'push' && type == 'tag' &&
                   ref[0, 'refs/tags/v'.length].casecmp('refs/tags/v').zero?
        expected &&= !ref.include?('-') if stable_only
        actual = parsed.evaluate(context)
        mismatches << context.merge('expected' => expected, 'actual' => actual) unless expected == actual
      end
    end
  end

  def test_non_ascii_condition_literals_are_refused
    ["é", "İ", "K", "ß"].each do |literal|
      error = assert_raises(ArgumentError) { WorkflowCondition.new("github.repository == '#{literal}/repo'") }
      assert_includes error.message, 'ASCII'
    end
  end

  def test_ascii_comparisons_match_ignore_case
    values = ['AbC', 'aBc', 'ABC', '', 'x-Y_9', "O'NEIL"]
    values.product(values).each do |left, right|
      literal = right.gsub("'", "''")
      context = { 'ref' => left }
      assert_equal left.casecmp(right).zero?, WorkflowCondition.new("github.ref == '#{literal}'").evaluate(context)
      assert_equal !left.casecmp(right).zero?, WorkflowCondition.new("github.ref != '#{literal}'").evaluate(context)
      expected = left[0, right.length].casecmp(right).zero?
      assert_equal expected, WorkflowCondition.new("startsWith(github.ref, '#{literal}')").evaluate(context)
    end
  end

  def test_repository_samples_reject_whitespace_and_controls
    characters = (0..32).map(&:chr) + [127.chr]
    characters.each do |character|
      ["owner#{character}/repo", "owner/repo#{character}"].each do |repository|
        assert_raises(ArgumentError) { release_event_mismatches('true', repository).first }
      end
    end
    ['owner', '/repo', 'owner/', 'owner/repo/extra'].each do |repository|
      assert_raises(ArgumentError) { release_event_mismatches('true', repository).first }
    end
    assert_equal ['Owner', 'RePo'], repository_parts('Owner/RePo')
  end

  def test_admission_failure_reports_an_example
    error = assert_raises(Minitest::Assertion) { assert_release_admission('true', 'owner/repo', 'over-admits') }
    assert_includes error.message, 'release matrix mismatch:'
    # Hash#inspect spaces its arrows from Ruby 3.4 on; the runner and the mini differ.
    assert_match(/"expected" ?=> ?false/, error.message)
    assert_match(/"actual" ?=> ?true/, error.message)
    assert_match(/"ref" ?=>/, error.message)
  end

  def test_repository_witnesses_use_unseen_folded_edges
    strings = (0..64).map(&:chr) + ['a']
    witnesses = repository_witnesses(strings)
    assert witnesses.all? { |witness| WorkflowCondition.fold(witness) == witness }, 'fresh edges must already be folded'
    assert_includes witnesses, '[', 'the first unseen folded continuation must be present'
  end

  def test_ci_test_baseline_includes_wrapper_self_test
    assert_ci_test_baseline_includes_wrapper_self_test
    step = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test').fetch('steps').find { |entry| entry['id'] == 'tests' }
    Dir.mktmpdir('pensieve-ci-floor-') do |directory|
      Dir.mkdir(File.join(directory, 'script'))
      runner = File.join(directory, 'script/test.sh')
      File.write(runner, "#!/bin/sh\n[ \"${1:-}\" = --self-test ] || echo PENSIEVE_TEST_COUNT=2707\n")
      File.chmod(0755, runner)
      [['2707', true], ['002707', true], ["2707\n# metadata", true], ['2708', false],
       ['', false], ['x', false], ['1x', false], ['+2707', false], [' 2707', false],
       ['2707 ', false], ['2707.0', false], ["2707\r", false]].each do |floor, expected|
        File.write(File.join(directory, '.test-count'), floor + "\n")
        script = step.fetch('run').gsub('/tmp/ci-test.out', File.join(directory, 'test.out'))
        stdout, stderr, status = Open3.capture3('/bin/bash', '-c', script, chdir: directory)
        assert_equal expected, status.success?, "floor #{floor.inspect}: #{stdout}#{stderr}"
        assert_includes stdout + stderr, '::error::' unless expected
      end
    end
  end

  def assert_ci_test_baseline_includes_wrapper_self_test
    assert_operator CI_WORST_SECONDS.fetch('Test'), :>, 867, 'Test includes measured wrapper self-test work'
  end

  def test_ci_hygiene_baseline_includes_stability_probe
    assert_ci_hygiene_baseline_includes_stability_probe
  end

  def assert_ci_hygiene_baseline_includes_stability_probe
    assert_operator CI_WORST_SECONDS.fetch('Test public hygiene guard'), :>, 156, 'Hygiene includes measured stability work'
  end

  def test_ci_short_bound_fixtures_are_the_tight_boundary
    baseline = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test')
    observed = {}
    original = method(:assert_ci_timeout_budget)
    define_singleton_method(:assert_ci_timeout_budget) do |job|
      job.fetch('steps').zip(baseline.fetch('steps')).each do |step, live|
        if step.key?('timeout-minutes') && step['timeout-minutes'] != live['timeout-minutes']
          observed[step.fetch('name')] = step.fetch('timeout-minutes')
        end
      end
      original.call(job)
    end
    assert_ci_budget_rejects_missing_short_and_unsummed_bounds
    ci_worst_seconds(baseline).each do |name, worst|
      next if worst.zero?
      assert_equal((worst * 3 / 60.0).ceil - 1, observed.fetch(name), name + ': tight short-bound mutation')
    end
  ensure
    singleton_class.send(:remove_method, :assert_ci_timeout_budget)
  end

  def test_explicit_read_only_permissions
    @workflows.each do |name, workflow|
      [workflow, *workflow.fetch('jobs').values].each do |scope|
        expected = scope.equal?(@release) ? 'write' : 'read'
        assert_equal({ 'contents' => expected }, scope.fetch('permissions'), name)
      end
    end
  end

  def action_nodes(node)
    uses = if node.is_a?(Psych::Nodes::Mapping)
             node.children.each_slice(2).map do |key, value|
               value if key.is_a?(Psych::Nodes::Scalar) && key.value == 'uses'
             end.compact
           else
             []
           end
    uses + node.children.to_a.flat_map { |child| action_nodes(child) }
  end

  def test_action_pins_and_version_comments
    count = 0
    @paths.each do |path|
      lines = File.readlines(path)
      action_nodes(YAML.parse_file(path)).each do |action|
        location = "#{path}:#{action.start_line + 1}"
        assert_instance_of Psych::Nodes::Scalar, action, location
        assert_match(/\A[^\s@]+\/[^\s@]+@[0-9a-f]{40}\z/, action.value, location)
        assert_equal action.start_line, action.end_line, location
        comment = lines.fetch(action.end_line)[action.end_column..-1]
        assert_match(/\A\s+#\s+v[0-9][\w.+-]*(?:\s.*)?\s*\z/, comment, location)
        count += 1
      end
    end
    assert_operator count, :>, 0
  end

  # Worst seconds from Actions runs 37074075055 and 37063706683.
  # Apply 2x for a slower runner before adding it to each historical runner baseline.
  CI_RUNNER_FACTOR = 2
  # Largest per-commit averages among multi-commit runs 37143791867 (2),
  # 37192623397 (17), and 37218019371 (17): the last took 20 s and 28 s.
  CI_PER_COMMIT_SECONDS = {
    'Check public hygiene in pushed commits' => 20.0 / 17,
    'Replay commit guards' => 28.0 / 17
  }.freeze
  # Run 37063706683 replayed one commit: retain its entire step duration as
  # fixed overhead, then add the multi-commit average conservatively.
  CI_REPLAY_FIXED_SECONDS = {
    'Check public hygiene in pushed commits' => 22,
    'Replay commit guards' => 35
  }.freeze
  # Workflow/recovery: worst of three serial wall-time samples, rounded up to milliseconds.
  # Measured 2026-10-05 on Mac16,11 / Apple M4 Pro, macOS 26.6.2 (25G83).
  # Recovery 481.623 s and workflow 8.951 s; ceil(2x) gives runner estimates 964/18 s.
  CI_LOCAL_WORST_SECONDS = {
    'Wrapper self-test' => 9.826, 'Hygiene added checks' => 0.731,
    'Workflow suite' => 8.951,
    'Release recovery' => 481.623
  }.freeze
  CI_WORST_SECONDS = {
    'Checkout' => 2, 'Select Xcode 26' => 1, 'Install tools' => 3,
    'Generate Xcode project' => 1, 'Compute replay range' => 0,
    'Test public hygiene guard' => 156 + (CI_LOCAL_WORST_SECONDS.fetch('Hygiene added checks') * CI_RUNNER_FACTOR).ceil, 'Test workflow contracts' => [3, (CI_LOCAL_WORST_SECONDS.fetch('Workflow suite') * CI_RUNNER_FACTOR).ceil].max,
    'Test release recovery' => (CI_LOCAL_WORST_SECONDS.fetch('Release recovery') * CI_RUNNER_FACTOR).ceil, 'Test development build host selection' => 0,
    'Test' => 867 + (CI_LOCAL_WORST_SECONDS.fetch('Wrapper self-test') * CI_RUNNER_FACTOR).ceil, 'Upload failed test evidence' => 7, 'Headless smoke' => 14
  }.freeze

  def ci_worst_seconds(job)
    limit = Integer(job.fetch('env').fetch('CI_LARGEST_PUSH'))
    assert_operator limit, :>, 0, 'CI: positive replay count limit'
    CI_WORST_SECONDS.merge(CI_PER_COMMIT_SECONDS.to_h do |name, seconds|
      [name, CI_REPLAY_FIXED_SECONDS.fetch(name) + seconds * limit]
    end)
  end

  def assert_ci_timeout_budget(job)
    steps = job.fetch('steps')
    budgets = steps.map do |step|
      assert step.key?('timeout-minutes'), step.fetch('name') + ': missing timeout'
      minutes = step.fetch('timeout-minutes')
      assert_operator minutes * 60, :>=, ci_worst_seconds(job).fetch(step.fetch('name')) * 3,
                      step.fetch('name') + ': measured timeout floor'
      assert_operator minutes, :>, 0, step.fetch('name') + ': missing timeout'
      minutes
    end
    assert_equal budgets.sum + 10, job.fetch('timeout-minutes'), 'CI: timeout headroom'
  end

  def test_ci_budget_rejects_missing_short_and_unsummed_bounds
    assert_ci_budget_rejects_missing_short_and_unsummed_bounds
  end

  def assert_ci_budget_rejects_missing_short_and_unsummed_bounds
    assert_ci_replay_budget_requires_fixed_cost
    assert_ci_test_baseline_includes_wrapper_self_test
    assert_ci_hygiene_baseline_includes_stability_probe
    job = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test')
    job.fetch('steps').each_with_index do |step, index|
      fixture = Marshal.load(Marshal.dump(job))
      fixture['steps'][index].delete('timeout-minutes')
      error = assert_raises(Minitest::Assertion, step.fetch('name')) { assert_ci_timeout_budget(fixture) }
      assert_includes error.message, 'missing timeout'
      worst = ci_worst_seconds(job).fetch(step.fetch('name'))
      next if worst.zero?
      fixture = Marshal.load(Marshal.dump(job))
      short_minutes = (worst * 3 / 60.0).ceil - 1
      fixture['steps'][index]['timeout-minutes'] = short_minutes
      assert_operator short_minutes * 60, :<, worst * 3, 'short bound must fail its floor'
      assert_operator (short_minutes + 1) * 60, :>=, worst * 3, 'the next whole minute must satisfy the floor'
      error = assert_raises(Minitest::Assertion, step.fetch('name')) { assert_ci_timeout_budget(fixture) }
      assert_includes error.message, 'measured timeout floor'
    end
    fixture = Marshal.load(Marshal.dump(job))
    fixture['timeout-minutes'] = fixture['steps'].sum { |step| step.fetch('timeout-minutes') } + 9
    error = assert_raises(Minitest::Assertion) { assert_ci_timeout_budget(fixture) }
    assert_includes error.message, 'timeout headroom'
  end

  def test_ci_replay_budget_requires_fixed_cost
    assert_ci_replay_budget_requires_fixed_cost
  end

  def assert_ci_replay_budget_requires_fixed_cost
    job = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test')
    limit = Integer(job.fetch('env').fetch('CI_LARGEST_PUSH'))
    CI_PER_COMMIT_SECONDS.each do |name, seconds|
      fixture = Marshal.load(Marshal.dump(job))
      step = fixture.fetch('steps').find { |entry| entry.fetch('name') == name }
      step['timeout-minutes'] = (seconds * limit * 3 / 60.0).ceil
      fixture['timeout-minutes'] = fixture.fetch('steps').sum { |entry| entry.fetch('timeout-minutes') } + 10
      error = assert_raises(Minitest::Assertion, name + ': variable-only bound must fail') do
        assert_ci_timeout_budget(fixture)
      end
      assert_includes error.message, name + ': measured timeout floor'
    end
  end

  def test_ci_timeout_budget_preserves_failure_upload
    job = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test')
    steps = job.fetch('steps')
    test = steps.find { |step| step['id'] == 'tests' }
    upload = steps.find { |step| step.fetch('uses', '').start_with?('actions/upload-artifact@') }
    assert_ci_timeout_budget(job)
    expanded = Marshal.load(Marshal.dump(job))
    expanded.fetch('steps').find { |step| step.fetch('name') == 'Test release recovery' }['timeout-minutes'] += 1
    expanded['timeout-minutes'] += 1
    assert_ci_timeout_budget(expanded) # Extra step headroom is allowed; there is no job-cap limit.
    assert_ci_replay_count_limit
    # Runner StepsRunner.RunStepAsync maps a step timeout (not job cancellation) to Failed.
    # Thus failure() is true and steps.tests.outcome is 'failure'; no success() implicit guard.
    assert_equal "failure() && steps.tests.outcome == 'failure'", upload.fetch('if')
    refute test.fetch('continue-on-error', false)
    assert_operator steps.index(upload), :>, steps.index(test)
    %w[DerivedData/FailedRuns/ DerivedData/TestRuns/ DerivedData/TestDiagnostics/].each do |path|
      assert_includes upload.fetch('with').fetch('path').lines.map(&:strip), path
    end
  end

  def test_ci_replay_count_limit
    assert_ci_replay_count_limit
  end

  def assert_ci_replay_count_limit
    job = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test')
    step = job.fetch('steps').find { |entry| entry['id'] == 'replay-range' }
    limit = Integer(job.fetch('env').fetch('CI_LARGEST_PUSH'))
    Dir.mktmpdir('pensieve-ci-range-') do |directory|
      git = File.join(directory, 'git')
      File.write(git, <<~'SH')
        #!/bin/sh
        printf '%s\n' "$*" >> "$FIXTURE_GIT_CALLS"
        case "$1" in
          fetch) exit 0 ;;
          rev-list) printf '%s\n' "$FIXTURE_COMMIT_COUNT" ;;
          *) exit 92 ;;
        esac
      SH
      File.chmod(0755, git)
      [[limit, 'before'], [limit + 1, 'before'], [0, 'before'],
       [1, '0' * 40], [0, '0' * 40]].each do |count, before|
        script = step.fetch('run').gsub('${{ github.event_name }}', 'push')
                     .gsub('${{ github.event.before }}', before).gsub('${{ github.sha }}', 'after')
        output = File.join(directory, 'output')
        calls = File.join(directory, 'calls')
        File.write(output, '')
        File.write(calls, '')
        stdout, stderr, status = Open3.capture3({ 'PATH' => directory + ':/usr/bin:/bin',
          'GITHUB_OUTPUT' => output, 'CI_LARGEST_PUSH' => limit.to_s,
          'FIXTURE_GIT_CALLS' => calls,
          'FIXTURE_COMMIT_COUNT' => count.to_s }, '/bin/bash', '-c', script)
        range = before == '0' * 40 ? 'origin/master..after' : 'before..after'
        expected_calls = before == '0' * 40 ? ['fetch origin master:refs/remotes/origin/master'] : []
        assert_equal expected_calls + ["rev-list --count #{range}"], File.readlines(calls, chomp: true)
        if count > limit
          refute status.success?, 'oversized push must fail before replay'
          assert_includes stdout + stderr, "#{count} commits exceeds limit #{limit}"
          refute_includes File.read(output), 'range='
          refute_includes File.read(output), 'skip=false'
        elsif count.zero?
          assert status.success?, stderr
          assert_includes stdout, "No commits in #{range}"
          assert_includes File.read(output), "skip=true\n"
          refute_includes File.read(output), 'range='
          refute_includes File.read(output), 'skip=false'
        else
          assert status.success?, stderr
          assert_includes stdout, "Replaying #{count} commit(s)"
          assert_includes File.read(output), "range=#{range}\n"
          assert_includes File.read(output), "skip=false\n"
        end
      end
    end
  end

  def test_triggers_stay_unchanged
    assert_equal %w[ci.yml public-hygiene.yml release.yml], @workflows.keys.sort
    assert_equal({ 'push' => { 'branches' => ['master'],
                              'paths-ignore' => ['docs/**', '**.md', '.github/workflows/release.yml'] },
                   'workflow_dispatch' => nil }, triggers(@workflows.fetch('ci.yml')))
    assert_equal({ 'push' => { 'tags' => ['v*'] } }, triggers(@workflows.fetch('release.yml')))
    steps = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test').fetch('steps')
    checks = steps.select { |step| step.fetch('run', '').strip == 'ruby script/workflow_self_test.rb' }
    assert_equal 1, checks.length, 'CI must run the workflow tests once'
    refute checks.first.key?('if'), 'CI must run the workflow tests unconditionally'
    refute checks.first.fetch('continue-on-error', false), 'workflow failures must fail CI'
  end
end
