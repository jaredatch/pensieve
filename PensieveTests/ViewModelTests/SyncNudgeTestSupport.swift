import Foundation
import SwiftData
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
