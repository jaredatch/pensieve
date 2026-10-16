import SwiftData
import XCTest
@testable import Pensieve

extension BundledSkillModelTests {
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
        model.add(context: fixture.context)
        XCTAssertEqual(importer.importedSkillCount, 1)
        XCTAssertTrue(importer.error?.contains("manifest failed") == true)
        XCTAssertEqual(model.error, importer.error, "Keep the manifest warning while recording the successful addition")
        XCTAssertEqual(model.state, .installed)
        XCTAssertTrue(fixture.files.fileExists(at: receipt),
                      "A successful import must write its receipt even with a manifest warning")
        model.add(context: fixture.context)
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
}

/// Keeps the existing real-file forwarding double, adding only the Settings refresh scheduling assertion.
private final class SettingsReadFiles: CountingHistoryFileService {
    var readChecks = 0
    override func isRegularFile(at path: String) -> Bool {
        readChecks += 1
        XCTAssertFalse(Thread.isMainThread, "Focus refresh must read bundled skill files off the main actor")
        return super.isRegularFile(at: path)
    }
}
