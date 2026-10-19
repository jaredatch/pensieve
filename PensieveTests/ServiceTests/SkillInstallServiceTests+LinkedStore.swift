import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testInstallIntoSameVolumeLinkedStore() throws {
        try NativeTestWork.run { [self] in
            let real = tempDir + "/real-store"
            let linked = tempDir + "/home/.pensieve"
            try fileService.createDirectory(at: real)
            try fileService.createSymlink(at: linked, pointingTo: real)
            try exerciseLinkedStore(root: linked)
        }
    }

    @MainActor
    func testPrivateAliasInstallImportAndCreate() throws {
        try NativeTestWork.run { [self] in
            // A real /var -> /private/var alias is needed; the usual DerivedData root has none.
            let root = TestTemporaryDirectory.systemPath + "LinkedStore-" + UUID().uuidString
            defer { try? fileService.deleteDirectory(at: root) }
            try fileService.createDirectory(at: root)
            let resolved = try fileService.resolveRealPath(at: root)
            XCTAssertTrue(resolved.hasPrefix("/private/"))
            XCTAssertEqual(fileService.realPath(at: String(resolved.dropFirst(8))), resolved)
            for spelling in [resolved, String(resolved.dropFirst(8))] {
                try exerciseLinkedStore(root: spelling)
                try fileService.deleteDirectory(at: spelling)
                try fileService.createDirectory(at: spelling)
                try fileService.deleteDirectory(at: tempDir + "/Vendor Fixture")
            }
        }
    }

    @MainActor
    func testOtherVolumeInstallImportUpdateSurviveLaunch() async throws {
        let probe = try StoreWriteCrashProbe(directory: tempDir)
        try await probe.withVolume { volume in
            let real = volume + "/store"
            let linked = tempDir + "/home/.pensieve"
            try fileService.createDirectory(at: real)
            try fileService.createSymlink(at: linked, pointingTo: real)
            XCTAssertNotEqual(fileService.fileIdentity(at: tempDir, followingLinks: true)?.device,
                              fileService.fileIdentity(at: real, followingLinks: true)?.device)
            try NativeTestWork.run { [self] in try exerciseLinkedStore(root: linked) }
            try await assertRuntimeRelaunch(root: linked)
            try assertVendorSweep(root: linked)
            for kind in ["vendor", "manifest-build", "machine-state"] {
                let location = try VendorTemporaryDirectory.namespace(storeRoot: linked, fileService: fileService, kind: kind)
                XCTAssertEqual(fileService.fileIdentity(at: location.parent, followingLinks: true)?.device,
                               fileService.fileIdentity(at: real, followingLinks: true)?.device)
                XCTAssertFalse(PathSyntax.hasPrefix(location.parent, fileService.realPath(at: real) + "/"))
                XCTAssertFalse(try fileService.listDirectory(at: location.parent).contains { $0.hasPrefix(location.prefix) })
            }
            XCTAssertEqual(try fileService.listDirectory(at: tempDir + "/home"), [".pensieve"])
            XCTAssertFalse(try fileService.listDirectory(at: volume).contains { $0.contains(".tmp") })
            XCTAssertEqual(Set(try fileService.listDirectory(at: real)), ["skills", "manifest", "machines"])
        }
    }

    @MainActor
    private func assertRuntimeRelaunch(root: String) async throws {
        let endpoint = try SocketTestDirectory()
        let paths = AppRuntimePaths(storeRoot: root, appSupportDir: endpoint.path)
        let defaults = try paths.makeDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set("off", forKey: UpdateCheckSchedule.frequencyKey)
        let machinePath = root + "/machines/5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002.yaml"
        let machineBytes = try fileService.readData(at: machinePath)
        let vendorBytes = try fileService.readData(at: root + "/skills/vendor/SKILL.md")
        let localBytes = try fileService.readData(at: root + "/skills/local/SKILL.md")
        let runtime = try AppRuntime(defaults: defaults, paths: paths)
        defer { runtime.commandServer?.stop(); runtime.library.stopWatching() }
        runtime.start()
        await TestWait.until(failureMessage: "Linked store launch did not finish") { runtime.commandsReady }
        await runtime.bootstrapTask.value
        let skills = try runtime.container.mainContext.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(Set(skills.map(\.directoryName)), ["vendor", "local", "created"])
        XCTAssertEqual(skills.first { $0.directoryName == "vendor" }?.name, "Updated Vendor")
        XCTAssertEqual(try fileService.readData(at: machinePath), machineBytes)
        XCTAssertEqual(try fileService.readData(at: root + "/skills/vendor/SKILL.md"), vendorBytes)
        XCTAssertEqual(try fileService.readData(at: root + "/skills/local/SKILL.md"), localBytes)
        XCTAssertTrue(Set(try ManifestService().read(fromRoot: root).skills.map(\.slug)).isSuperset(of: ["vendor", "local"]))
    }

    @MainActor
    func testPlainAndLinkedStoreRefuseUnsafeInstallDestinations() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeVendorFixture()
            let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(fetched.candidates.first)
            let real = tempDir + "/real-store", linked = tempDir + "/linked-store"
            let outside = tempDir + "/outside"
            try fileService.writeFile(at: outside + "/SKILL.md", content: "precious")
            try fileService.createSymlink(at: real + "/skills/vendor", pointingTo: outside)
            try fileService.createSymlink(at: linked, pointingTo: real)
            for root in [real, linked] {
                let context = try makeInstallContext()
                let installer = makeInstallService(root: root)
                XCTAssertEqual(try installer.install(candidate: candidate, from: fetched, context: context),
                    .collision(existing: SkillCollision(slug: "vendor", hasDirectory: true, hasSwiftDataRow: false)))
                for slug in ["..", ".", "", "foo/bar"] {
                    XCTAssertThrowsError(try installer.install(candidate: candidate, renamedTo: slug,
                                                               from: fetched, context: context)) { error in
                        XCTAssertEqual(error as? SkillInstallError, .invalidSlug(slug))
                    }
                }
                XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
                XCTAssertFalse(fileService.directoryExists(at: root + "/manifest"))
            }
            XCTAssertEqual(try fileService.readFile(at: outside + "/SKILL.md"), "precious")
        }
    }

    private func assertVendorSweep(root: String) throws {
        let wrapped = FaultyFileService(wrapped: fileService)
        let canonical = try fileService.resolveRealPath(at: root)
        let canonicalNamespace = try VendorTemporaryDirectory.namespace(storeRoot: canonical, fileService: fileService)
        let wrappedNamespace = try VendorTemporaryDirectory.namespace(storeRoot: root, fileService: wrapped)
        XCTAssertEqual(wrappedNamespace.parent, canonicalNamespace.parent)
        XCTAssertEqual(wrappedNamespace.prefix, canonicalNamespace.prefix)
        XCTAssertEqual(try wrapped.resolveRealPath(at: root), canonical)
        var stale: [String] = []
        for kind in ["vendor", "manifest-build", "machine-state"] {
            let path = try VendorTemporaryDirectory.makePath(storeRoot: root, fileService: fileService, kind: kind)
            try fileService.writeFile(at: kind == "machine-state" ? path : path + "/partial", content: "partial")
            stale.append(path)
        }
        let legacy = (root as NSString).deletingLastPathComponent + "/"
            + (root as NSString).lastPathComponent + ".vendor-" + UUID().uuidString + ".tmp"
        try fileService.writeFile(at: legacy + "/partial", content: "legacy")
        stale.append(legacy)
        let lockPath = tempDir + "/sync.lock"
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        SkillInstallService.cleanupVendorTemps(fileService: fileService, storeRoot: root, lockPath: lockPath)
        for path in stale { XCTAssertTrue(try fileService.entryExistsWithoutFollowingLinks(at: path), path) }
        lock.release()
        SkillInstallService.cleanupVendorTemps(fileService: fileService, storeRoot: root, lockPath: lockPath)
        for path in stale { XCTAssertFalse(try fileService.entryExistsWithoutFollowingLinks(at: path), path) }
    }

    @MainActor
    private func exerciseLinkedStore(root: String) throws {
        let repository = try makeVendorFixture()
        let installer = SkillInstallService(gitService: gitService, credentialStore: InMemoryCredentialStore(),
            fileService: fileService, scratchRoot: scratchRoot, storeRoot: root,
            lockPath: tempDir + "/sync.lock", remoteValidator: fixtureRemoteValidator)
        let fetched = try installer.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(fetched.candidates.first)
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        XCTAssertEqual(try installer.install(candidate: candidate, from: fetched, context: context), .installed(slug: "vendor"))
        XCTAssertEqual(try fileService.readData(at: root + "/skills/vendor/SKILL.md"),
                       try fileService.readData(at: repository + "/skills/vendor/SKILL.md"))
        try importIntoLinkedStore(root: root, context: context)
        let store = SkillStore(fileService: fileService, baseDir: root + "/skills", storeRoot: root)
        let created = try store.createSkill(name: "Created", description: "Created here", body: "created body")
        XCTAssertEqual(created, "created")
        XCTAssertTrue(try store.readBody(directoryName: created).contains("created body"))
        try writeSkill("skills/vendor", name: "Updated Vendor", description: "Updated", in: repository)
        try commit(repository, message: "update")
        let update = try installer.fetch(repo: repository, ref: nil, credential: nil)
        try installer.update(existingSlug: "vendor", candidate: XCTUnwrap(update.candidates.first),
                             from: update, context: context)
        XCTAssertEqual(try store.readBody(directoryName: "vendor"),
                       try fileService.readFile(at: repository + "/skills/vendor/SKILL.md"))
        let machines = try linkedMachineService()
        let state = try machines.compose(machineID: "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002", context: context,
                                         publishedAt: Date(timeIntervalSince1970: 100))
        try machines.write(state, toRoot: root)
        // Exercise replacement as well as first publication of both metadata publishers.
        try machines.write(state, toRoot: root)
        let manifest = ManifestService(fileService: fileService)
        XCTAssertEqual(Set(try manifest.read(fromRoot: root).skills.map(\.slug)), ["vendor", "local"])
        let rebuilt = StoreRebuildService(fileService: fileService, manifestService: manifest).rebuild(
            fromRoot: root, context: context)
        XCTAssertTrue(rebuilt.warnings.isEmpty, rebuilt.warnings.description)
        let fresh = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let launch = LaunchReconciler(migrationService: StoreMigrationService(skillStore: store), root: root,
                                     lockPath: tempDir + "/sync.lock", git: gitService)
        let outcome = launch.reconcileOnLaunch(context: fresh, alreadyMigrated: true)
        XCTAssertTrue(outcome.rebuild.warnings.isEmpty, outcome.rebuild.warnings.description)
        XCTAssertEqual(Set(try fresh.fetch(FetchDescriptor<Skill>()).map(\.directoryName)), ["vendor", "local", "created"])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "vendor" }?.name, "Updated Vendor")
        XCTAssertEqual(machines.readAll(fromRoot: root), [state])
        XCTAssertEqual(Set(try manifest.read(fromRoot: root).skills.map(\.slug)), ["vendor", "local"])
    }

    @MainActor
    private func importIntoLinkedStore(root: String, context: ModelContext) throws {
        let source = tempDir + "/local-source"
        try fileService.writeFile(at: source + "/SKILL.md",
            content: "---\nname: Local\ndescription: Local fixture\n---\nlocal body\n")
        let scanner = ImportScanner(fileService: fileService, claudeSkillsDir: source,
            grokSkillsDir: tempDir + "/grok", cursorRulesDir: tempDir + "/cursor", codexSkillsDir: tempDir + "/codex",
            storeRoot: root)
        let model = ImportViewModel(scanner: scanner,
            skillStore: SkillStore(fileService: fileService, baseDir: root + "/skills", storeRoot: root),
            lockPath: tempDir + "/sync.lock", manifestService: ManifestService(fileService: fileService), manifestRoot: root)
        XCTAssertEqual(model.scanFolder(source), .found(1))
        model.importSelected(context: context)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.importedSkillCount, 1)
        XCTAssertEqual(try fileService.readFile(at: root + "/skills/local/SKILL.md"),
                       try fileService.readFile(at: source + "/SKILL.md"))
    }

    private func linkedMachineService() throws -> MachineStateService {
        let suite = isolatedDefaultsSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return MachineStateService(fileService: fileService, agentDetection: DeployStubDetection(installed: []),
            defaults: defaults, deployState: { DeployState(schemaVersion: 1, records: []) },
            homeDirectory: tempDir + "/home", hostName: { "Fixture" }, appVersion: { "1" })
    }
}
