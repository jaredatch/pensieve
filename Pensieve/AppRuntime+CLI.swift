import Foundation

extension AppRuntime {
    /// Starts process work independently of scene presentation. Repeated starts join the one launch.
    func start() {
        Task { await performLaunchWorkIfNeeded(context: container.mainContext) }
    }

    var commandsReady: Bool {
        launchWorkCompleted && coordinator != nil && scheduler.isLaunchIngestReady
    }

    func waitForCommandReadiness(timeout: TimeInterval = CLIProtocol.readyTimeout) async -> CLIReply? {
        let deadline = SocketTransport.deadline(after: timeout)
        while !commandsReady {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return .failure("app_starting", library.addFenceReason ?? "Pensieve is still starting.",
                    hint: "Wait a moment, then run this command again.", exit: 3, retryable: true)
            }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch {
                return .failure("app_unavailable", "The command was interrupted while Pensieve was starting.",
                    hint: "Run this command again.", exit: 3, retryable: true)
            }
        }
        return nil
    }

    func startCommandServer() {
        let files = FileService()
        let handler = CLIReadHandler(store: SkillStore(fileService: files, baseDir: paths.skillsDir, storeRoot: paths.storeRoot),
            installedAgents: platformVM.installedPlatforms,
            machines: machineObservability.stateService, storeRoot: paths.storeRoot)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jaredatch.Pensieve"
        let path = CLIProtocol.socketPath(appSupport: paths.appSupportDir, bundleID: bundleID)
        do {
            commandServer = try AppSocketServer(path: path,
                handshake: CLIHandshake(bundlePath: files.realPath(at: Bundle.main.bundlePath),
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                fileService: files, readiness: { [weak self] in
                    guard let self else {
                        return .failure("app_unavailable", "Pensieve is unavailable", hint: "Open Pensieve.", exit: 3)
                    }
                    if let refusal = await self.waitForCommandReadiness() { return refusal }
                    return nil
                }, handler: { [weak self] request in
                    guard let self else {
                        return .failure("app_unavailable", "Pensieve is unavailable", hint: "Open Pensieve.", exit: 3)
                    }
                    return handler.handle(request, context: self.container.mainContext)
                })
        } catch {
            commandServerError = "\(path): \(error.localizedDescription)"
            NSLog("Pensieve command server: %@", commandServerError ?? "unavailable")
        }
    }
}
