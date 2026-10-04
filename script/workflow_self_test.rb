#!/usr/bin/env ruby
# Local workflow contract tests. Uses macOS's bundled Ruby and YAML parser.
require 'yaml'
require 'minitest/autorun'
require 'strscan'

# Evaluate only the boolean/string subset used by the release job condition.
# Unknown syntax fails closed. This is a local policy probe, not a runner:
# actionlint validates GitHub syntax; the post-merge release proves execution.
class WorkflowCondition
  attr_reader :tree

  def initialize(expression)
    @input = StringScanner.new(expression.strip.sub(/\A\$\{\{\s*/, '').sub(/\s*\}\}\z/, ''))
    @tree = disjunction
    raise 'unparsed condition' unless @input.rest.strip.empty?
  end

  def evaluate(context)
    value = evaluate_node(tree, context)
    raise 'condition is not boolean' unless [true, false].include?(value)
    value
  end

  def string_literals(node = tree)
    return node[1].is_a?(String) ? [node[1]] : [] if node.first == :literal
    node.drop(1).select { |child| child.is_a?(Array) }.flat_map { |child| string_literals(child) }
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
    when :starts_with then left.downcase.start_with?(right.downcase)
    when :==, :!=
      equal = left.is_a?(String) && right.is_a?(String) ? left.casecmp(right).zero? : left == right
      kind == :== ? equal : !equal
    else raise 'unsupported node: ' + kind.inspect
    end
  end

  def take(pattern)
    @input.skip(/\s*/)
    @input.scan(pattern)
  end

  def expect(pattern)
    take(pattern) || raise('expected ' + pattern.inspect + ': ' + @input.rest)
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
    elsif take(/startsWith\(/i)
      value = atom
      expect(/,/)
      prefix = atom
      expect(/\)/)
      [:starts_with, value, prefix]
    elsif (string = take(/'(?:[^']|'')*'/))
      [:literal, string[1...-1].gsub("''", "'")]
    elsif (property = take(/github\.[a-z_]+/))
      [:property, property]
    elsif (boolean = take(/true\b|false\b/))
      [:literal, boolean == 'true']
    else
      raise 'unsupported condition: ' + @input.rest
    end
  end
end

class WorkflowTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CASK_INPUTS = %w[/VERSION /Pensieve/Info.plist /release/homebrew/pensieve.rb
                   /script/release.sh /script/release_recovery.sh /script/release_state.py
                   /script/verify_update.swift].freeze
  CASK_RUN = <<~'SH'.freeze
    set -euo pipefail
    expected_tag="v$(tr -d '[:space:]' < VERSION)"
    if [ "$GITHUB_REF_NAME" != "$expected_tag" ]; then
      echo "::error::Release tag does not match VERSION"
      exit 1
    fi
    ./script/release.sh --publish-cask-only
  SH

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
              key = secret == 'RELEASE_REPO_TOKEN' ? 'GH_TOKEN' : secret
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
    assert_equal({ 'GH_TOKEN' => '${{ secrets.RELEASE_REPO_TOKEN }}' }, holders.first.fetch('env'))
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
    jobs = workflows.fetch('release.yml').fetch('jobs')
    assert_equal %w[cask release], jobs.keys.sort
    cask = jobs.fetch('cask')
    assert_equal %w[environment if name needs permissions runs-on steps timeout-minutes], cask.keys.sort
    assert_equal 'release', cask.fetch('needs')
    assert_equal jobs.fetch('release').fetch('if'), cask.fetch('if')
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
    assert_equal({ 'GH_TOKEN' => '${{ secrets.RELEASE_REPO_TOKEN }}' }, steps.last.fetch('env'))

    release_steps = jobs.fetch('release').fetch('steps')
    uploads = release_steps.select { |step| step.fetch('uses', '').start_with?('actions/upload-artifact@') }
    assert_equal 1, uploads.length
    upload = uploads.first
    assert_equal 'always()', upload.fetch('if')
    assert_equal({ 'name' => 'dmg', 'path' => 'build/dist/*.dmg',
                   'if-no-files-found' => 'ignore', 'retention-days' => 14 }, upload.fetch('with'))
    signer = release_steps.find { |step| step['name'] == 'Sign, notarize, and publish' }
    assert_operator release_steps.index(upload), :>, release_steps.index(signer)
  end

  def test_cask_job_is_isolated_and_consumes_release_artifact
    assert_cask_job_shape(@workflows)
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
    assert_match(%r{\A[^/]+/[^/]+\z}, canonical, 'canonical repository must have non-empty owner/name parts')
    assert_release_admission(condition, canonical, 'live workflow')
    assert_release_admission(@cask.fetch('if'), canonical, 'live cask workflow')
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
    assert_release_admission("#{equality} && #{event_guard.sub('refs/tags/v', 'REFS/TAGS/V')}",
                             canonical, 'upper-case tag prefix')
    failing.each do |label, clause|
      mismatches = release_event_mismatches("(#{clause}) && #{event_guard}", canonical)
      assert mismatches.any? { |context| context['expected'] == false && context['actual'] == true },
             "#{label}: failing fixture must produce an over-admission (expected false, actual true)"
    end
    whole_name = /(?<![a-z0-9_.\/-])#{Regexp.escape(canonical)}(?![a-z0-9_.\/-])/i
    assert_equal 2, @paths.sum { |path| File.read(path).scan(whole_name).length }
  end

  def assert_release_admission(condition, canonical, label)
    mismatches = release_event_mismatches(condition, canonical)
    assert mismatches.empty?, "#{label}: release matrix mismatch: #{mismatches.first.inspect} " \
                              "(#{mismatches.length} mismatched contexts)"
  end

  def repository_witnesses(strings)
    folded = strings.map(&:downcase).uniq
    fresh_codepoint = 33
    fresh_codepoint += 1 while folded.any? { |string| string.include?(fresh_codepoint.chr(Encoding::UTF_8).downcase) }
    fresh = fresh_codepoint.chr(Encoding::UTF_8).downcase
    assert_equal 1, fresh.length
    refute folded.any? { |string| string.include?(fresh) }, 'witness character must be absent from every string'
    # Equality and startsWith (in either direction) depend only on the shared
    # prefix. Every unseen continuation has the relations of prefix + fresh.
    prefixes = folded.flat_map { |string| (0..string.length).map { |length| string[0, length] } }.uniq
    (prefixes + prefixes.map { |prefix| prefix + fresh }).uniq
  end

  def release_event_mismatches(condition, canonical)
    parsed = WorkflowCondition.new(condition)
    literals = parsed.string_literals
    owner, name = canonical.split('/')
    repositories = [canonical, "octocat/#{name}", "#{owner}/fork", "#{canonical}-fork", '',
                    'jaredatch/pensieve', 'JaredAtch/Pensieve', 'alice/pensieve-app', 'evil/x', 'mallory/x']
    events = %w[push pull_request pull_request_target workflow_dispatch schedule release workflow_run]
    types = %w[tag branch]
    refs = ['refs/tags/v1.2.3', 'refs/tags/v1.2.3-beta.1', 'refs/tags/v',
            'refs/tags/other', 'refs/heads/v1.2.3', 'refs/heads/master', 'refs/pull/1/merge', '']
    # Exercise ref disjuncts even when their literal was absent from the samples.
    refs = (refs + literals.grep(%r{\Arefs/}i)).uniq
    witnesses = repository_witnesses(literals + events + types + refs + repositories)
    repositories = (witnesses + repositories).uniq # Retain the mixed-case sample.
    mismatches = []
    repositories.product(events, types, refs) do |repo, event, type, ref|
      context = { 'repository' => repo, 'event_name' => event, 'ref_type' => type, 'ref' => ref }
      expected = repo.casecmp(canonical).zero? && event == 'push' && type == 'tag' && ref.downcase.start_with?('refs/tags/v')
      actual = parsed.evaluate(context)
      mismatches << context.merge('expected' => expected, 'actual' => actual) unless expected == actual
    end
    mismatches
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

  def test_ci_timeout_budget_preserves_failure_upload
    job = @workflows.fetch('ci.yml').fetch('jobs').fetch('build-test')
    steps = job.fetch('steps')
    test = steps.find { |step| step['id'] == 'tests' }
    upload = steps.find { |step| step.fetch('uses', '').start_with?('actions/upload-artifact@') }
    assert_operator test.fetch('timeout-minutes'), :>, 10
    assert_operator job.fetch('timeout-minutes'), :>=,
                    test.fetch('timeout-minutes') + upload.fetch('timeout-minutes') + 10
    # Runner StepsRunner.RunStepAsync maps a step timeout (not job cancellation) to Failed.
    # Thus failure() is true and steps.tests.outcome is 'failure'; no success() implicit guard.
    assert_equal "failure() && steps.tests.outcome == 'failure'", upload.fetch('if')
    refute test.fetch('continue-on-error', false)
    assert_operator steps.index(upload), :>, steps.index(test)
    %w[DerivedData/FailedRuns/ DerivedData/TestRuns/ DerivedData/TestDiagnostics/].each do |path|
      assert_includes upload.fetch('with').fetch('path').lines.map(&:strip), path
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
