import Foundation

/// The elevation boundary: production shows one system prompt; fixtures run its command unelevated.
protocol AdministratorPromptRunning {
    func run(shellCommand: String) throws
}

struct AppleScriptAdministratorPrompt: AdministratorPromptRunning {
    func run(shellCommand shell: String) throws {
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let script = NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges")
        _ = script?.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "Pensieve.AdministratorPrompt", code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                          userInfo: [NSLocalizedDescriptionKey:
                            error[NSAppleScript.errorMessage] as? String ?? "The link wasn't changed."])
        }
        guard script != nil else { throw CommandLinkError(message: "The administrator prompt couldn't be opened.") }
    }
}
