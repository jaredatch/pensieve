import SwiftData
import XCTest
@testable import Pensieve

extension BundledSkillModelTests {
    func testAddRefusesFolderArrivingDuringScanWithOriginalMessage() async throws {
        let fixture = try CLILibraryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let library = fixture.runtime.library
        let own = "---\nname: pensieve\ndescription: Arrived from sync\n---\nKeep these instructions.\n"
        let path = fixture.paths.skillsDir + "/pensieve/SKILL.md"
        let scanner = BundledArrivalScanner(base: fixture.paths.makeImportScanner()) {
            do { try fixture.files.writeFile(at: path, content: own) } catch { XCTFail("Sync arrival: \(error)") }
            StoreIngestState.shared(for: fixture.context.container).invalidate()
        }
        let importer = ImportViewModel(scanner: scanner, skillStore: library.skillStore,
            lockPath: fixture.paths.syncLockPath, manifestService: ManifestService(fileService: fixture.files),
            manifestRoot: fixture.paths.storeRoot)
        let receipt = fixture.paths.appSupportDir + "/arrival-receipt.json"
        let model = BundledSkillModel(files: fixture.files,
            bundledDirectory: Bundle.main.bundlePath + "/Contents/Resources/pensieve", receiptPath: receipt,
            lockPath: fixture.paths.syncLockPath, library: library, importer: importer)
        await model.add(context: fixture.context)
        XCTAssertEqual(model.error,
            "The pensieve folder is taken by another skill. Rename or remove that skill, then try again.")
        XCTAssertEqual(model.state, .absent)
        XCTAssertEqual(importer.importedSkillCount, 0)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["pensieve"])
        XCTAssertEqual(try fixture.files.listDirectory(at: fixture.paths.skillsDir), ["pensieve"])
        XCTAssertEqual(try fixture.files.readFile(at: path), own)
        XCTAssertFalse(fixture.files.fileExists(at: receipt))
    }

    func assertManifestFailureStillRecordsTheAddedSkill() async throws {
        let fixture = try CLILibraryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let library = fixture.runtime.library
        let importer = ImportViewModel(scanner: fixture.paths.makeImportScanner(), skillStore: library.skillStore,
            lockPath: fixture.paths.syncLockPath, manifestService: BundledManifestFailure(),
            manifestRoot: fixture.paths.storeRoot)
        let source = Bundle.main.bundlePath + "/Contents/Resources/pensieve"
        let receipt = fixture.paths.appSupportDir + "/manifest-failure-receipt.json"
        let model = BundledSkillModel(files: fixture.files, bundledDirectory: source, receiptPath: receipt,
            lockPath: fixture.paths.syncLockPath, library: library, importer: importer)
        await model.add(context: fixture.context)
        XCTAssertEqual(importer.importedSkillCount, 1)
        XCTAssertTrue(importer.error?.contains("manifest failed") == true)
        XCTAssertEqual(model.error, importer.error, "Keep the manifest warning while recording the successful addition")
        XCTAssertEqual(model.state, .installed)
        XCTAssertTrue(fixture.files.fileExists(at: receipt),
                      "A successful import must write its receipt even with a manifest warning")
        await model.add(context: fixture.context)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Skill>()), 1)
        let observed = SettingsReadFiles(base: fixture.files)
        let refreshing = BundledSkillModel(files: observed, bundledDirectory: source, receiptPath: receipt,
            lockPath: fixture.paths.syncLockPath, library: library, importer: importer)
        await refreshing.refresh(context: fixture.context)
        XCTAssertNil(refreshing.error)
        XCTAssertEqual(refreshing.state, .installed)
        XCTAssertGreaterThan(observed.readChecks, 0)
    }
}

/// Only manifest publication fails; the real importer still scans, writes the skill and saves its row.
private struct BundledManifestFailure: ManifestSnapshotting {
    func read(fromRoot root: String) throws -> ManifestSnapshot { try ManifestService().read(fromRoot: root) }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot { try ManifestService().snapshot(from: context) }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func repair(_ snapshot: ManifestSnapshot, root: String, replacing damage: ManifestDamage) throws -> Bool {
        throw CocoaError(.featureUnsupported)
    }
}

/// Keeps the existing real-file forwarding double, adding only the Settings refresh scheduling assertion.
final class SettingsReadFiles: FileServiceProtocol {
    let base: FileService
    init(base: FileService) { self.base = base }
    func writeData(at path: String, data: Data) throws { try base.writeData(at: path, data: data) }
    func readFile(at path: String) throws -> String { try base.readFile(at: path) }
    func writeFile(at path: String, content: String) throws { try base.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try base.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { base.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try base.deleteDirectory(at: path) }
    func createSymlink(at path: String, pointingTo target: String) throws { try base.createSymlink(at: path, pointingTo: target) }
    func symlinkTarget(at path: String) throws -> String { try base.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { base.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try base.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try base.contentsHash(at: path) }
    var readChecks = 0
    var pauseNextRead: TestWait.Gate?
    func isRegularFile(at path: String) -> Bool {
        readChecks += 1
        XCTAssertFalse(Thread.isMainThread, "Focus refresh must read bundled skill files off the main actor")
        if path.hasSuffix("/SKILL.md"), let gate = pauseNextRead {
            pauseNextRead = nil
            do { try gate.wait() } catch { XCTFail("Held refresh failed: \(error)") }
        }
        return base.isRegularFile(at: path)
    }
}

/// Runs the real folder scan, then introduces a sync arrival before the importer acquires its lock.
private struct BundledArrivalScanner: ImportScannerProtocol {
    let base: ImportScannerProtocol
    let arrive: () -> Void
    func isInsideStore(_ path: String) -> Bool { base.isInsideStore(path) }
    func scan() -> [DiscoveredSkill] { base.scan() }
    func scanFolder(_ path: String) -> [DiscoveredSkill] { scanFolderWithReport(path).skills }
    func scanFolderWithReport(_ path: String) -> ImportScanReport {
        let report = base.scanFolderWithReport(path)
        arrive()
        return report
    }
}
