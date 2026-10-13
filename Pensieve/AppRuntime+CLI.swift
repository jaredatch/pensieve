import Foundation

extension AppRuntime {
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
                fileService: files) { [weak self] request in
                    guard let self else {
                        return .failure("app_unavailable", "Pensieve is unavailable", hint: "Open Pensieve.", exit: 3)
                    }
                    return handler.handle(request, context: self.container.mainContext)
                }
        } catch {
            commandServerError = "\(path): \(error.localizedDescription)"
            NSLog("Pensieve command server: %@", commandServerError ?? "unavailable")
        }
    }
}
