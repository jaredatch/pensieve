import Foundation
@testable import Pensieve

/// Exercises Git's real credential fill/approve/reject machinery without a network connection.
/// The wrapper authenticates network commands before delegating to a file:// bare repository.
/// It forwards the runner's global options unchanged and supplies hostile config only in its child,
/// so it tests credential precedence without changing the host's HOME, config or Keychain.
struct GitCredentialFixture {
    let base = TestTemporaryDirectory.path + "PensieveCredentials-" + UUID().uuidString
    let files = FileService()
    let token = "pensieve-fixture-token"
    let transport: GitTransport
    var remote: String { transport == .https ? "https://fixture.test/store.git" : "ssh://fixture.test" + bare }
    var config: String { base + "/gitconfig" }
    var helper: String { base + "/foreign-helper" }
    var askpass: String { base + "/foreign-askpass" }
    var foreignTrace: String { base + "/foreign-calls" }
    var networkTrace: String { base + "/network-calls" }
    var argvTrace: String { base + "/argv" }
    var bare: String { base + "/remote.git" }
    var acceptedToken: String { base + "/accepted-token" }
    var credential: GitCredential { .httpsToken(username: "pensieve", token: token) }
    var git: GitService {
        GitService(askpassHelperPath: base + "/askpass", executablePath: base + "/git")
    }

    init(transport: GitTransport = .https) throws {
        self.transport = transport
        try files.createDirectory(at: base)
        try files.writeFile(at: acceptedToken, content: token)
        try files.writeExecutableFile(at: helper, content: """
            #!/bin/sh
            printf 'helper %s\\n' "$1" >> '\(foreignTrace)'
            cat >/dev/null
            if [ "$1" = get ]; then printf 'username=foreign\\npassword=wrong-token\\n'; fi
            """ + "\n")
        try files.writeExecutableFile(at: askpass, content: """
            #!/bin/sh
            printf 'askpass\\n' >> '\(foreignTrace)'
            printf 'wrong-token\\n'
            """ + "\n")
        try files.writeFile(at: config, content: """
            [user]
                name = Test
                email = test@pensieve.local
            [credential]
                helper = \(helper)
            [core]
                askPass = \(askpass)
            """ + "\n")
        try files.writeExecutableFile(at: base + "/git", content: wrapper + "\n")
        _ = try raw(["init", "--bare", "--initial-branch=main", bare])
    }

    func remove() throws { try files.deleteDirectory(at: base) }

    /// A plain Git lookup proves the hostile programs can answer; production must prevent it.
    func lookup(_ options: [String] = [], environment: [String: String] = [:]) throws -> String {
        try raw(options + ["credential", "fill"], input: "protocol=https\nhost=fixture.test\n\n",
                environment: environment)
    }

    func clearTraces() throws {
        for path in [foreignTrace, networkTrace, argvTrace] { try files.writeFile(at: path, content: "") }
    }

    @discardableResult
    func raw(_ args: [String], input: String = "", environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = config
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env.removeValue(forKey: "GIT_ASKPASS")
        env.merge(environment) { _, new in new }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(args: args, exitCode: process.terminationStatus,
                                         stderr: String(bytes: error, encoding: .utf8) ?? "")
        }
        return String(bytes: output, encoding: .utf8) ?? ""
    }

    private var authentication: String {
        """
            auth=$(printf 'protocol=https\\nhost=fixture.test\\n\\n' |
              /usr/bin/git "${options[@]}" credential fill) || {
                printf 'fatal: Authentication failed\\n' >&2; exit 128;
              }
            expected=$(cat '\(acceptedToken)')
            if ! /usr/bin/grep -qx "password=$expected" <<< "$auth"; then
              printf '%s\\n\\n' "$auth" | /usr/bin/git "${options[@]}" credential reject
              printf 'fatal: Authentication failed\\n' >&2
              exit 128
            fi
            printf '%s\\n\\n' "$auth" | /usr/bin/git "${options[@]}" credential approve
        """
    }

    private var wrapper: String {
        """
        #!/bin/bash
        export GIT_CONFIG_GLOBAL='\(config)'
        export GIT_CONFIG_NOSYSTEM=1
        printf '%s\\n' "$*" >> '\(argvTrace)'
        original=("$@")
        options=()
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -c|-C) options+=("$1" "$2"); shift 2 ;;
            *) break ;;
          esac
        done
        case "$1" in
          clone|fetch|push|ls-remote)
            if [ "$1" = push ] && [ -f '\(base)/rotate-at-push' ]; then
              mv '\(base)/rotate-at-push' '\(acceptedToken)'
            fi
            \(transport == .https ? authentication : "")
            printf '%s\\n' "$1" >> '\(networkTrace)'
            \(transport == .https ? "exec /usr/bin/git -c 'url.file://\(bare).insteadOf=\(remote)' \"${original[@]}\"" : "")
            ;;
        esac
        exec /usr/bin/git "${original[@]}"
        """
    }
}
