import Foundation
@testable import Pensieve

/// A real, disposable ssh-agent holds a generated key. An offline SSH transport checks that the
/// inherited socket exposes exactly that key before serving upload-pack/receive-pack locally.
/// This tests agent passthrough and git operations, not an SSH server or host-key verification.
struct GitAgentFixture {
    let fixture: GitCredentialFixture
    let socketDirectory: String
    let agentPID: String
    var socket: String { socketDirectory + "/s" }

    init() throws {
        fixture = try GitCredentialFixture(transport: .ssh)
        // Unix sockets have a short path limit; the suite's nested TestRuns root can exceed it.
        socketDirectory = TestTemporaryDirectory.systemPath + "pa-" + UUID().uuidString
        try fixture.files.createDirectory(at: socketDirectory)
        var pid: String?
        do {
            let response = try Self.tool("ssh-agent", ["-s", "-a", socketDirectory + "/s"])
            pid = response.components(separatedBy: .newlines).first(where: { $0.hasPrefix("SSH_AGENT_PID=") })?
                .dropFirst("SSH_AGENT_PID=".count).prefix(while: { $0.isNumber }).description
            guard let pid else { throw AgentFailure.noPID }
            agentPID = pid
            _ = try Self.tool("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", fixture.base + "/key"])
            _ = try Self.tool("ssh-add", [fixture.base + "/key"], environment: ["SSH_AUTH_SOCK": socketDirectory + "/s"])
            let transport = fixture.base + "/ssh"
            try fixture.files.writeExecutableFile(at: transport, content: """
                #!/bin/sh
                if ! /usr/bin/ssh-add -L | /usr/bin/cmp -s - '\(fixture.base)/key.pub'; then
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
            if let pid { _ = try? Self.tool("ssh-agent", ["-k"], environment: ["SSH_AGENT_PID": pid]) }
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
        _ = try Self.tool("ssh-agent", ["-k"], environment: ["SSH_AGENT_PID": agentPID])
    }

    @discardableResult
    private static func tool(_ name: String, _ args: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/" + name)
        process.arguments = args
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

private enum AgentFailure: Error { case noPID }
