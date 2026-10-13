import Foundation

/// Shares the retained daemon's readers, preserving its CLI behavior while wrapping this CLI's result.
struct CLIFileReads {
    let appSupport: String
    let fileService: FileServiceProtocol

    func run(command: String, lines: Int = 20) -> (reply: CLIReply, human: String) {
        var arguments = [command]
        if command == "log" { arguments += ["--lines", String(lines)] } else { arguments += ["--json"] }
        let outcome = DaemonCLI.execute(arguments, appSupport: appSupport,
            readFile: { try? fileService.readRegularFileData(at: $0, maximumBytes: CLIProtocol.replyLimit) },
            runCycle: { .skipped(.noRemote) }, now: Date.init)
        guard outcome.exitCode != 2 else {
            return (.failure("state_unreadable", outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                hint: "Open Pensieve to record state, or check your home directory.", exit: 2), "")
        }
        let value: CLIValue
        if command == "log" {
            value = .object(["lines": .array(outcome.stdout.split(separator: "\n").map { .string(String($0)) })])
        } else {
            guard let data = outcome.stdout.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(CLIValue.self, from: data) else {
                return (.failure("state_unreadable", "Unreadable state", hint: "Open Pensieve.", exit: 2), "")
            }
            value = canonicalAgents(decoded)
        }
        if outcome.exitCode == 1 {
            var reply = CLIReply.failure("sync_failed", "The last sync failed.",
                hint: "Open Pensieve to review the sync error.", exit: 1)
            var envelope = reply.envelope
            envelope.data = value
            reply = CLIReply(envelope: envelope, exitCode: reply.exitCode)
            return (reply, "")
        }
        let human = DaemonCLI.execute(command == "log" ? arguments : [command], appSupport: appSupport,
            readFile: { try? fileService.readRegularFileData(at: $0, maximumBytes: CLIProtocol.replyLimit) },
            runCycle: { .skipped(.noRemote) }, now: Date.init).stdout
        return (.success(value), human)
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
