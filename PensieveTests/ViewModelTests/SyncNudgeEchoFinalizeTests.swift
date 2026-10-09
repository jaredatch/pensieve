import SwiftData
import XCTest
@testable import Pensieve

extension SyncNudgeTests {
    func testExternalRewriteBetweenWriteAndFinalizeStaysExternal() async throws {
        var nudgeCount = 0
        let store = InstallEchoSkillStore()
        let watcher = InstallEchoWatcher()
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: watcher, manifestRoot: TestPaths.storeRoot,
            notifier: { nudgeCount += 1 }
        )
        library.startWatching()
        let slug = "race-slug"
        let appBody = "App-written body"

        library.beginAppAuthoredBodyWrite(directoryName: slug, expectedBody: appBody)
        store.bodies[slug] = SkillSerializer.serialize(
            name: slug, description: "Description", body: appBody
        )
        // An external editor rewrites the same file before the finalizer runs.
        store.bodies[slug] = SkillSerializer.serialize(
            name: slug, description: "Description", body: "External rewrite"
        )
        library.finishAppAuthoredBodyWrite(directoryName: slug)

        // The delayed watcher event for the external content must classify external
        // and nudge exactly once — not be swallowed as the app's own echo.
        watcher.emit(slug)
        XCTAssertTrue(library.externallyModified.contains(slug))
        XCTAssertEqual(nudgeCount, 1)
        // Re-delivery of the same content stays quiet.
        watcher.emit(slug)
        XCTAssertEqual(nudgeCount, 1)
    }

    func testFailedReplacementFinalizeAdoptsNoFingerprint() async throws {
        var nudgeCount = 0
        let store = InstallEchoSkillStore()
        let watcher = InstallEchoWatcher()
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: watcher, manifestRoot: TestPaths.storeRoot,
            notifier: { nudgeCount += 1 }
        )
        library.startWatching()
        let slug = "failed-write"
        let oldBody = "Old body"
        store.bodies[slug] = SkillSerializer.serialize(
            name: slug, description: "Description", body: oldBody
        )
        library.noteAppAuthoredBody(
            Skill(name: slug, skillDescription: "Description", directoryName: slug), body: oldBody
        )

        // The replacement throws after begin: disk keeps the old body.
        library.beginAppAuthoredBodyWrite(directoryName: slug, expectedBody: "Never landed")
        library.finishAppAuthoredBodyWrite(directoryName: slug, succeeded: false)

        // The old on-disk body must still read as the app's own — no spurious external.
        watcher.emit(slug)
        XCTAssertFalse(library.externallyModified.contains(slug))
        XCTAssertEqual(nudgeCount, 0)

        // An external rewrite racing the failed replacement must still classify external.
        store.bodies[slug] = SkillSerializer.serialize(
            name: slug, description: "Description", body: "External after failure"
        )
        watcher.emit(slug)
        XCTAssertTrue(library.externallyModified.contains(slug))
        XCTAssertEqual(nudgeCount, 1)
    }
}
