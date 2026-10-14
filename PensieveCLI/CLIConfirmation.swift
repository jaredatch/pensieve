import Darwin
import Foundation

enum CLIConfirmation {
    static func send(_ request: CLIRequest, client: CLIClient, options: OutputOptions, arguments: [String]) -> CLIReply {
        let reply = client.send(request)
        guard reply.envelope.error?.code == "confirmation_required" else { return reply }
        let rerun = (["pensieve"] + confirmingArguments(arguments)).map(quote).joined(separator: " ")
        guard isatty(STDIN_FILENO) != 0, !options.noInput,
              ProcessInfo.processInfo.environment["PENSIEVE_NO_INPUT"] != "1" else {
            return confirmationReply(reply, command: rerun)
        }
        if let data = reply.envelope.data, let bytes = try? JSONEncoder().encode(data),
           let text = String(data: bytes, encoding: .utf8) {
            FileHandle.standardError.write(Data((DisplayTextSanitizer.singleLine(text) + "\n").utf8))
        }
        FileHandle.standardError.write(Data("Apply this plan? [y/N] ".utf8))
        guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
            return confirmationReply(reply, command: rerun)
        }
        var confirmed = request
        confirmed.library?.confirmed = true
        return client.send(confirmed)
    }

    private static func confirmationReply(_ reply: CLIReply, command: String) -> CLIReply {
        var envelope = reply.envelope
        envelope.error = CLIError(code: "confirmation_required", message: "Confirmation is required; nothing was changed.",
            hint: "After reviewing the plan, run: " + command, retryable: false)
        envelope.next = [command]
        return CLIReply(envelope: envelope, exitCode: 5)
    }

    private static func confirmingArguments(_ arguments: [String]) -> [String] {
        var result = arguments
        result.insert("--yes", at: result.firstIndex(of: "--") ?? result.endIndex)
        return result
    }

    private static func quote(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=./:")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
