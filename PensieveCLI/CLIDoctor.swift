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
    let applicationsDirectory: String
    let developerDirectory: String?

    func run() -> CLIReply {
        var checks: [CLIValue] = []
        func record(_ name: String, _ ok: Bool, _ detail: String, _ hint: String) {
            checks.append(.object(["check": .string(name), "ok": .bool(ok),
                                   "message": .string(detail), "hint": .string(hint)]))
        }
        do {
            let entry = try files.commandLinkEntry(at: socket)
            record("socket", entry?.kind == .socket && entry?.owner == getuid(), socket,
                   "Open this Pensieve copy to create its socket.")
        } catch { record("socket", false, error.localizedDescription, "Check access to the App Support folder.") }
        do {
            let descriptor = try SocketTransport.connect(to: socket, timeout: 1)
            defer { close(descriptor) }
            let client = CLIClient(appPath: files.realPath(at: app), socketPath: socket, fileService: files,
                                   launcher: CLIAppLauncher(fileService: files), bundleID: "")
            let handshake = try checkedHandshake(client, descriptor: descriptor)
            record("app", true, handshake.bundlePath, "This app is reachable.")
        } catch let refusal as LaunchRefusal {
            let error = refusal.reply.envelope.error
            record("app", false, error?.message ?? "The app refused the connection.", error?.hint ?? "Open \(app).")
        } catch { record("app", false, error.localizedDescription, "Open \(app), then run doctor again.") }
        let directories = searchPath.components(separatedBy: ":").filter { PathSyntax.isAbsolute($0) }
        checkPath(directories: directories, record: record)
        let git = directories.map { $0 + "/git" }.first { files.isExecutableFile(at: $0) }
        let gitWorks = git.map { files.realPath(at: $0) != "/usr/bin/git" || developerToolsAvailable() } ?? false
        record("git", gitWorks, gitWorks ? (git ?? "") : "git or its developer tools are missing.",
               "Install the Xcode Command Line Tools and add git to PATH.")
        checkAgents(directories: directories, record: record)
        let ok = checks.allSatisfy { if case .object(let row) = $0 { return row["ok"] == .bool(true) }; return false }
        let data = CLIValue.object(["checks": .array(checks)])
        if ok { return .success(data) }
        return CLIReply(envelope: CLIEnvelope(ok: false, changed: false, data: data,
            error: CLIError(code: "doctor_failed", message: "Some setup checks failed.",
                            hint: "Follow the hint for each failed check.", retryable: false)), exitCode: 1)
    }
    private func checkPath(directories: [String], record: (String, Bool, String, String) -> Void) {
        var found = false
        for directory in directories {
            let path = directory + "/pensieve"
            do {
                guard let entry = try files.commandLinkEntry(at: path) else { continue }
                found = true
                let executable = app + "/Contents/Helpers/pensieve"
                let status = try CommandLinkOwnership.status(entry: entry, path: path, executable: executable,
                                                             files: files, resolveExecutable: true)
                let target = entry.target.map {
                    PathSyntax.isAbsolute($0) ? $0 : directory + "/" + $0
                }
                let resolved = target.map { files.realPath(at: $0) }
                let other = resolved != files.realPath(at: executable)
                let note = status == .broken ? ": broken link" : ""
                let message = status.hasProblem ? status.message + note
                    : path + (other ? ": another Pensieve copy at " + (resolved ?? "") : "")
                record("path", !status.hasProblem, message,
                       other && !status.hasProblem ? "This command runs that Pensieve copy."
                       : "Use Settings > General > Command Line to install or repair this app's command.")
            } catch { record("path", false, path + ": " + error.localizedDescription, "Check this PATH entry.") }
        }
        if !found { record("path", false, "pensieve is not on PATH.", "Install the command in Settings > General.") }
    }

    private func checkedHandshake(_ client: CLIClient, descriptor: Int32) throws -> CLIHandshake {
        try client.validatePeer(descriptor)
        let data = try SocketTransport.readFrame(descriptor, limit: CLIProtocol.requestLimit, timeout: 1)
        return try client.validatedHandshake(data, isWrite: false)
    }

    private func checkAgents(directories: [String], record: (String, Bool, String, String) -> Void) {
        let probe = SystemEnvironmentProbe(fileService: files,
            pathEntries: directories)
        let detection = AgentDetectionService(probe: probe, homeDirectory: home, applicationsDirectory: applicationsDirectory)
        for platform in PlatformTarget.allCases {
            let agent = platform.cliID
            guard detection.isInstalled(platform) else {
                record("agent:" + agent, true, "Not installed", "Install \(platform.displayName) if you want to use it.")
                continue
            }
            let path = PathConstants.agentSkillsDirectory(platform, home: home)
            do {
                guard try files.entryExistsWithoutFollowingLinks(at: path) else {
                    record("agent:" + agent, true, "Installed; its skills folder appears on the first sync.",
                           "Sync your skills to create \(path).")
                    continue
                }
                let accessible = try files.directoryExistsFollowingLinks(at: path)
                if accessible { _ = try files.listDirectory(at: path) }
                record("agent:" + agent, accessible, path, "Check access to its skills folder.")
            } catch { record("agent:" + agent, false, error.localizedDescription, "Check access to \(path).") }
        }
    }

    private func developerToolsAvailable() -> Bool {
        if let developerDirectory { return files.isExecutableFile(at: developerDirectory + "/usr/bin/git") }
        // xcode-select reports the selected tools without invoking git's installer-launching stub.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--print-path"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let path = String(data: data, encoding: .utf8) else { return false }
            return files.isExecutableFile(at: path.trimmingCharacters(in: .whitespacesAndNewlines) + "/usr/bin/git")
        } catch { return false }
    }

}
