import Foundation

/// The elevation boundary: production shows one system prompt; fixtures run its command unelevated.
protocol AdministratorPromptRunning {
    func run(shellCommand: String) throws
}

struct AppleScriptAdministratorPrompt: AdministratorPromptRunning {
    // Fixtures omit only the elevation words, retaining the actual wrapper and environment policy.
    var requiresAdministratorPrivileges = true
    static let errorDomain = "Pensieve.AdministratorPrompt"

    func run(shellCommand shell: String) throws {
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let privileges = requiresAdministratorPrivileges ? " with administrator privileges" : ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\"\(privileges)"]
        // Sanitize before osascript starts: its outer shell can execute inherited code before
        // the privileged program's first instruction. Never merge with the app's environment.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain while the child runs, so a diagnostic cannot fill the pipe and stall its exit.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        let message = String(data: data, encoding: .utf8) ?? "The administrator command failed."
        throw Self.failure(status: process.terminationStatus, message: message)
    }

    static func failure(status: Int32, message: String) -> NSError {
        let cancelled = message.range(of: #"^\d+:\d+: execution error: User canceled\. \(-128\)\s*$"#,
                                      options: .regularExpression) != nil
        return NSError(domain: errorDomain, code: cancelled ? -128 : Int(status),
                       userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
}
