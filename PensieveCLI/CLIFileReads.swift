import Foundation

/// Shares the retained daemon's disk readers and status summary, wrapping data in this CLI's envelope.
struct CLIFileReads {
    let appSupport: String
    let fileService: FileServiceProtocol

    func run(command: String, lines: Int = 20) -> CLIReply {
        var arguments = [command]
        if command == "log" { arguments += ["--lines", String(lines)] } else { arguments += ["--json"] }
        let outcome = DaemonCLI.execute(arguments, appSupport: appSupport,
            readFile: { try? fileService.readRegularFileData(at: $0, maximumBytes: CLIProtocol.replyLimit) },
            runCycle: { .skipped(.noRemote) }, now: Date.init)
        guard outcome.exitCode != 2 else {
            return .failure("state_unreadable", outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                hint: "Open Pensieve to record state, or check your home directory.", exit: 2)
        }
        let value: CLIValue
        if command == "log" {
            var logLines = outcome.stdout.components(separatedBy: "\n")
            if logLines.last == "" { logLines.removeLast() }
            value = .object(["lines": .array(logLines.map(CLIValue.string))])
        } else {
            guard let data = outcome.stdout.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(CLIValue.self, from: data) else {
                return .failure("state_unreadable", "Unreadable state", hint: "Open Pensieve.", exit: 2)
            }
            value = canonicalAgents(decoded)
        }
        if outcome.exitCode == 1 {
            var reply = CLIReply.failure("sync_failed", "The last sync failed.",
                hint: "Open Pensieve to review the sync error.", exit: 1)
            var envelope = reply.envelope
            envelope.data = value
            reply = CLIReply(envelope: envelope, exitCode: reply.exitCode)
            return reply
        }
        return .success(value)
    }

    func statusSummary(for reply: CLIReply) -> String? {
        guard let value = reply.envelope.data, let bytes = try? JSONEncoder().encode(value) else { return nil }
        return DaemonCLI.renderStatus(data: bytes, path: appSupport + "/daemon-status.json", json: false, now: Date()).output
    }

    private func canonicalAgents(_ value: CLIValue) -> CLIValue {
        switch value {
        case let .array(values): return .array(values.map(canonicalAgents))
        case let .object(fields):
            var result = fields.mapValues(canonicalAgents)
            if case let .string(name) = fields["platform"] {
                result["platform"] = .string(PlatformTarget.cliID(for: name))
            }
            return .object(result)
        default: return value
        }
    }
}
