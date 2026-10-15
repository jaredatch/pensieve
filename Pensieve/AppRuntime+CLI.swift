import Foundation

extension AppRuntime {
    func checkForSkillUpdatesAndReport() async -> String? {
        startUpdateCheck(showsFailureAlert: false)
        await updateCheckTask?.value
        return updateCheckError
    }

    /// Starts process work independently of scene presentation. Repeated starts join the one launch.
    func start() {
        Task { await commandLineSettings.repairAtLaunch() }
        Task { await performLaunchWorkIfNeeded(context: container.mainContext) }
    }

    var commandsReady: Bool {
        launchWorkCompleted && coordinator != nil && scheduler.isLaunchIngestReady
    }

    func waitForCommandReadiness(timeout: TimeInterval = CLIProtocol.readyTimeout) async -> CLIReply? {
        let deadline = SocketTransport.deadline(after: timeout)
        if isQuitting { return quittingCommandReply }
        while !commandsReady {
            if isQuitting { return quittingCommandReply }
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

    var quittingCommandReply: CLIReply {
        .failure("app_quitting", "Pensieve is quitting.", hint: "Wait for it to quit, then retry.", exit: 3, retryable: true)
    }

    func makeDeployMutations() -> DeployMutationServicing {
        let reconciler = Self.makeLaunchIntentReconciler(platformVM: platformVM, paths: paths)
        return DeployMutationService(platformVM: platformVM, dependencies: .live(
            identity: machineObservability.identity, stateService: machineObservability.stateService,
            root: paths.storeRoot, lockPath: paths.syncLockPath,
            notifier: { [weak scheduler] in scheduler?.nudge() }, reconcile: reconcileIntent,
            reconcileSelection: { reconciler.reconcileSelection($0, context: $1) }))
    }

    func startCommandServer() {
        let files = FileService()
        let handler = CLIReadHandler(store: SkillStore(fileService: files, baseDir: paths.skillsDir, storeRoot: paths.storeRoot),
            deployments: deployMutations)
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
                }, admit: { [weak self] request in
                    guard let self else { return .init(refusal: .failure("app_unavailable", "Pensieve is unavailable",
                        hint: "Open Pensieve.", exit: 3)) }
                    guard !self.isQuitting else { return .init(refusal: self.quittingCommandReply) }
                    guard request.isWrite else { return .init() }
                    let steps = self.paths.syncSteps
                    let work = steps.begin()
                    return .init(finish: { steps.finish(work) })
                }, handler: { [weak self] request in
                    guard let self else {
                        return .failure("app_unavailable", "Pensieve is unavailable", hint: "Open Pensieve.", exit: 3)
                    }
                    if ["deploy", "undeploy"].contains(request.command) {
                        return CLIDeployHandler(service: self.deployMutations, files: files)
                            .handle(request, context: self.container.mainContext)
                    }
                    if request.command == "sync" { return await CLISyncHandler(model: self.syncModel).handle() }
                    if ["install", "skill outdated", "skill update", "skill delete", "project add", "project remove"]
                        .contains(request.command) {
                        return await CLILibraryHandler(runtime: self, files: files).handle(request)
                    }
                    return handler.handle(request, context: self.container.mainContext)
                })
        } catch {
            commandServerError = "\(path): \(error.localizedDescription)"
            NSLog("Pensieve command server: %@", commandServerError ?? "unavailable")
        }
    }
}
