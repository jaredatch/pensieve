import Foundation

/// The elevation boundary: production shows one system prompt; fixtures run its command unelevated.
protocol AdministratorPromptRunning {
    func run(shellCommand: String, action: CommandLinkAction) throws
}

struct AppleScriptAdministratorPrompt: AdministratorPromptRunning {
    // Fixtures omit only the elevation words, retaining the actual wrapper and environment policy.
    var requiresAdministratorPrivileges = true
    static let errorDomain = "Pensieve.AdministratorPrompt"

    func run(shellCommand shell: String, action: CommandLinkAction = .install) throws {
        let process = makeProcess(shellCommand: shell, action: action)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain while the child runs, so a diagnostic cannot fill the pipe and stall its exit.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        let message = process.terminationReason == .exit ? (String(data: data, encoding: .utf8) ?? "") : ""
        throw Self.failure(status: process.terminationStatus, message: message)
    }

    func makeProcess(shellCommand shell: String, action: CommandLinkAction) -> Process {
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let privileges = requiresAdministratorPrivileges ? " with administrator privileges" : ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\"\(privileges) with prompt \"\(action.prompt)\""]
        // Sanitize before osascript starts: its outer shell can execute inherited code before
        // the privileged program's first instruction. Never merge with the app's environment.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        return process
    }

    static func failure(status: Int32, message: String) -> NSError {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = trimmed.range(of: #"\(-128\)$"#, options: .regularExpression) != nil
        let sentence = trimmed.replacingOccurrences(of: #"^\d+:\d+: [^:\n]+: "#,
            with: "", options: .regularExpression)
            .replacingOccurrences(of: #" \(-?\d+\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(domain: errorDomain, code: cancelled ? -128 : Int(status),
                       userInfo: [NSLocalizedDescriptionKey: sentence.isEmpty ? "The administrator command failed." : sentence])
    }
}

extension CommandLinkAction {
    var prompt: String {
        switch self {
        case .install: return "Pensieve wants to install the pensieve command."
        case .uninstall: return "Pensieve wants to uninstall the pensieve command."
        case .repair: return "Pensieve wants to repair the pensieve command."
        }
    }
}
