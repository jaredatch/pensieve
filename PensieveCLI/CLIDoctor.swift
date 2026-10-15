import ArgumentParser
import Darwin
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor",
        abstract: "Check this app, its socket, PATH, git and agent folders.")
    @OptionGroup var output: OutputOptions
}

struct CLIDoctor {
    let files: FileServiceProtocol
    let app: String
    let socket: String
    let home: String
    let searchPath: String

    func run() -> CLIReply {
        var checks: [CLIValue] = []
        func record(_ name: String, _ ok: Bool, _ detail: String, _ hint: String) {
            checks.append(.object(["check": .string(name), "ok": .bool(ok),
                                   "message": .string(detail), "hint": .string(hint)]))
        }
        do {
            let entry = try files.commandLinkEntry(at: socket)
            record("socket", entry?.kind == .socket, socket, "Open this Pensieve copy to create its socket.")
        } catch { record("socket", false, error.localizedDescription, "Check access to the App Support folder.") }
        do {
            let descriptor = try SocketTransport.connect(to: socket, timeout: 1)
            defer { close(descriptor) }
            let data = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.requestLimit, timeout: 1)
            let handshake = try JSONDecoder().decode(CLIHandshake.self, from: data)
            let matches = files.realPath(at: handshake.bundlePath) == files.realPath(at: app)
                && handshake.protocolVersion == CLIProtocol.version
            record("app", matches, handshake.bundlePath,
                   matches ? "This app is reachable." : "Quit the other copy and open \(app).")
        } catch { record("app", false, error.localizedDescription, "Open \(app), then run doctor again.") }
        let directories = searchPath.components(separatedBy: ":").filter { PathSyntax.isAbsolute($0) }
        var found = false
        for directory in directories {
            let path = directory + "/pensieve"
            do {
                guard try files.entryExistsWithoutFollowingLinks(at: path) else { continue }
                found = true
                let target = try files.commandLinkEntry(at: path)?.target
                let matches = files.isExecutableFile(at: path)
                    && files.realPath(at: path) == files.realPath(at: app + "/Contents/Helpers/pensieve")
                let broken = try target.map { try CommandLinkOwnership.isMissingApp($0, files: files) } ?? false
                record("path", matches, path + (broken ? ": broken link" : ""),
                       "Use Settings > General > Command Line to install or repair this app's command.")
            } catch { record("path", false, path + ": " + error.localizedDescription, "Check this PATH entry.") }
        }
        if !found { record("path", false, "pensieve is not on PATH.", "Install the command in Settings > General.") }
        let git = directories.map { $0 + "/git" }.first { files.isExecutableFile(at: $0) }
        record("git", git != nil, git ?? "git is not on PATH.", "Install the Xcode Command Line Tools and add git to PATH.")
        checkAgents(record: record)
        let ok = checks.allSatisfy { if case .object(let row) = $0 { return row["ok"] == .bool(true) }; return false }
        let data = CLIValue.object(["checks": .array(checks)])
        if ok { return .success(data) }
        return CLIReply(envelope: CLIEnvelope(ok: false, changed: false, data: data,
            error: CLIError(code: "doctor_failed", message: "Some setup checks failed.",
                            hint: "Follow the hint for each failed check.", retryable: false)), exitCode: 1)
    }
    private func checkAgents(record: (String, Bool, String, String) -> Void) {
        let probe = SystemEnvironmentProbe(fileService: files,
            pathEntries: searchPath.components(separatedBy: ":").filter { PathSyntax.isAbsolute($0) })
        let detection = AgentDetectionService(probe: probe, homeDirectory: home)
        for platform in PlatformTarget.allCases {
            let agent = platform.cliID
            guard detection.isInstalled(platform) else {
                record("agent:" + agent, true, "Not installed", "Install \(platform.displayName) if you want to use it.")
                continue
            }
            let relative = "." + agent + (platform == .cursor ? "/rules" : "/skills")
            let path = home + "/" + relative
            do {
                let accessible = try files.directoryExistsFollowingLinks(at: path)
                if accessible { _ = try files.listDirectory(at: path) }
                record("agent:" + agent, accessible, path, "Install \(agent) and check access to its skills folder.")
            } catch { record("agent:" + agent, false, error.localizedDescription, "Check access to \(path).") }
        }
    }

}
