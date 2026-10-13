import Foundation
import SwiftData
import XCTest
@testable import Pensieve

struct LibraryFixture {
    let library: SkillLibraryViewModel
    let store: MemorySkillStore
    let watcher: RecordingWatcher
    let context: ModelContext
    let counter: Counter
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    var notify: SyncStateNotifying { { [weak self] in _ = self?.increment() } }
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
    func reset() { lock.withLock { count = 0 } }
}

final class MemorySkillStore: SkillStoreProtocol {
    let baseDir = TestPaths.skillsDir
    var bodies: [String: String] = [:]
    var savedData: [String: Data] = [:]

    func createSkill(name: String, description: String, body: String) throws -> String {
        try createSkill(name: name, description: description, body: body, avoiding: [])
    }

    func createSkill(name: String, description: String, body: String, avoiding: Set<String>) throws -> String {
        try createSkill(name: name, content: SkillSerializer.serialize(name: name, description: description, body: body),
                        avoiding: avoiding)
    }

    func createSkill(name: String, content: String, avoiding: Set<String>) throws -> String {
        let candidate = SkillStore.availableDirectoryName(for: name, occupied: Set(bodies.keys).union(avoiding))
        bodies[candidate] = content
        return candidate
    }

    func readBody(directoryName: String) throws -> String { bodies[directoryName] ?? "" }
    func readData(directoryName: String) throws -> Data {
        savedData[directoryName] ?? Data((bodies[directoryName] ?? "").utf8)
    }

    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        bodies[directoryName] = SkillSerializer.rewrite(
            body: body,
            preserving: parsed,
            fallbackName: fallbackName,
            fallbackDescription: fallbackDescription
        ).content
        return SkillRewriteResult(content: bodies[directoryName] ?? body, didChange: true)
    }

    func writeBody(directoryName: String, body: String) throws { bodies[directoryName] = body }
    func deleteSkill(directoryName: String) throws { bodies[directoryName] = nil }
    func listSkills() throws -> [String] { Array(bodies.keys) }
}

final class RecordingWatcher: FileWatchServiceProtocol {
    var onChange: (String) -> Void = { _ in }
    func start() -> Bool { true }
    func stop() {}
    func emit(_ slug: String) { onChange(slug) }
}

enum IdentityRefreshMode { case window, draft, failure }

extension SyncNudgeTests {
    func testFinalIdentityDuringRecheckReachesWindowRow() async throws {
        try await assertFinalIdentityDuringRecheck(refresh: .window)
    }

    func testFinalIdentityDuringRecheckReachesRetainedDraft() async throws {
        try await assertFinalIdentityDuringRecheck(refresh: .draft)
    }

    func testFinalIdentityDuringRecheckPreservesPassiveFailureMessage() async throws {
        try await assertFinalIdentityDuringRecheck(refresh: .failure)
    }

    func assertFinalIdentityDuringRecheck(refresh: IdentityRefreshMode) async throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        let before = "---\nname: Test\ndescription: Before\n---\nBody"
        let intermediate = before.replacingOccurrences(of: "Before", with: "Intermediate")
        let final = "---\nname: Final name\ndescription: Final\n---\nBody"
        try fixture.write(before)
        _ = fixture.library.editorBody(for: fixture.skill)
        if refresh == .draft {
            fixture.library.onSkillDocumentObserved = nil
            fixture.library.noteEditorChanged(fixture.skill, body: before + " draft")
        }
        fixture.library.beginCoordinatorChanges()
        let sampledSequence = fixture.library.coordinatorWatcherEventSequence
        try fixture.write(intermediate)
        fixture.watcher.emit("test")
        XCTAssertEqual(fixture.skill.skillDescription, "Intermediate")
        if refresh == .failure {
            fixture.library.onSkillDocumentObserved = { _, _ in throw CocoaError(.fileReadUnknown) }
        }
        fixture.library.error = "An earlier refused Save"
        let checks = Counter()
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: true,
            sampledWatcherEventSequence: sampledSequence, recheckHasUnsyncedChanges: {
                checks.increment()
                do { try fixture.write(final) } catch { XCTFail("Final write failed: \(error)") }
                return true
            })
        XCTAssertEqual(checks.value, 1)
        XCTAssertFalse(fixture.library.isApplyingCoordinatorChanges)
        XCTAssertEqual(fixture.skill.skillDescription, refresh == .failure ? "Intermediate" : "Final")
        XCTAssertEqual(fixture.skill.name, refresh == .failure ? "Test" : "Final name")
        XCTAssertEqual(fixture.library.error, "An earlier refused Save")
        XCTAssertTrue(fixture.library.wasLastWrittenByApp(directoryName: "test", currentBody: final))
        let token = fixture.library.reloadToken
        fixture.watcher.emit("test") // Delivered only after completion adopts the final file.
        XCTAssertEqual(fixture.library.reloadToken, token)
        XCTAssertEqual(fixture.skill.skillDescription, refresh == .failure ? "Intermediate" : "Final")
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertTrue(fixture.library.externallyModified.contains("test"))
        XCTAssertEqual(fixture.library.hasUnsavedChanges, refresh == .draft)
        XCTAssertEqual(fixture.library.pendingUnsavedChanges?.reason, refresh == .draft ? .externalChange : nil)
    }
}
