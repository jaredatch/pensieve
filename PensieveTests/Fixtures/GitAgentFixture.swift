import Foundation
@testable import Pensieve

/// A real, disposable ssh-agent holds a generated key. An offline SSH transport checks that the
/// inherited socket exposes exactly that key before serving upload-pack/receive-pack locally.
/// This tests agent passthrough and git operations, not an SSH server or host-key verification.
final class GitAgentFixture {
    let fixture: GitCredentialFixture
    let socketDirectory: String
    private let agent = Process()
    var agentPID: String { get throws { try fixture.files.readFile(at: socketDirectory + "/pid") } }
    var socket: String { socketDirectory + "/s" }

    init() throws {
        fixture = try GitCredentialFixture(transport: .ssh)
        socketDirectory = TestTemporaryDirectory.path + "pa-" + UUID().uuidString.prefix(8)
        do {
            try fixture.files.createDirectory(at: socketDirectory)
            try startAgent()
            _ = try Self.tool("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", fixture.base + "/key"])
            _ = try Self.tool("ssh-add", [fixture.base + "/key"], environment: ["SSH_AUTH_SOCK": "s"],
                              workingDirectory: socketDirectory)
            let transport = fixture.base + "/ssh"
            try fixture.files.writeExecutableFile(at: transport, content: """
                #!/bin/sh
                if [ "$SSH_AUTH_SOCK" != '\(socket)' ] ||
                   ! (cd '\(socketDirectory)' && SSH_AUTH_SOCK=s /usr/bin/ssh-add -L) |
                     /usr/bin/cmp -s - '\(fixture.base)/key.pub'; then
                  printf 'Permission denied (publickey).\\n' >&2
                  exit 255
                fi
                printf 'agent\\n' >> '\(fixture.base)/agent-calls'
                for argument in "$@"; do command="$argument"; done
                exec /bin/sh -c "$command"
                """ + "\n")
            let config = try fixture.files.readFile(at: fixture.config)
            try fixture.files.writeFile(at: fixture.config, content: config + "\n[core]\n    sshCommand = \(transport)\n")
        } catch {
            stopAgent()
            try? fixture.remove()
            try? fixture.files.deleteDirectory(at: socketDirectory)
            throw error
        }
    }

    func remove() throws {
        defer {
            try? fixture.remove()
            try? fixture.files.deleteDirectory(at: socketDirectory)
        }
        stopAgent()
    }

    private func startAgent() throws {
        // Bind and connect with a relative name: even a deeply nested TestRuns root fits AF_UNIX.
        // The driver owns a foreground agent without parsing ssh-agent's output. Its deadline
        // also stops the agent if the test host crashes before fixture cleanup can run.
        let driver = fixture.base + "/agent-driver"
        try fixture.files.writeExecutableFile(at: driver, content: """
            #!/bin/sh
            /usr/bin/ssh-agent -D -a s &
            child=$!
            printf '%s' "$child" > pid
            /bin/sleep 90 &
            timer=$!
            trap 'kill "$child" "$timer" 2>/dev/null; wait "$child" "$timer" 2>/dev/null' EXIT
            trap 'exit 0' HUP INT TERM
            wait "$timer"
            """ + "\n")
        agent.executableURL = URL(fileURLWithPath: driver)
        agent.currentDirectoryURL = URL(fileURLWithPath: socketDirectory)
        agent.standardInput = FileHandle.nullDevice
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        let deadline = Date().addingTimeInterval(TestWait.timeoutSeconds)
        while !fixture.files.fileExists(at: socket) {
            guard agent.isRunning, Date() < deadline else { throw AgentFailure.noSocket }
            usleep(10_000)
        }
    }

    private func stopAgent() {
        guard agent.isRunning else { return }
        agent.terminate()
        agent.waitUntilExit()
    }

    deinit { try? remove() }

    @discardableResult
    private static func tool(_ name: String, _ args: [String], environment: [String: String] = [:],
                             workingDirectory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/" + name)
        process.arguments = args
        process.currentDirectoryURL = workingDirectory.map { URL(fileURLWithPath: $0) }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(args: [name] + args, exitCode: process.terminationStatus,
                                         stderr: String(bytes: error, encoding: .utf8) ?? "")
        }
        return String(bytes: output, encoding: .utf8) ?? ""
    }
}

private enum AgentFailure: Error { case noSocket }
