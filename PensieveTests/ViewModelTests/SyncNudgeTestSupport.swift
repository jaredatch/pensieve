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

final class Counter {
    private(set) var value = 0
    lazy var notify: SyncStateNotifying = { [weak self] in self?.value += 1 }
    func reset() { value = 0 }
}

final class MemorySkillStore: SkillStoreProtocol {
    let baseDir = TestPaths.skillsDir
    var bodies: [String: String] = [:]

    func createSkill(name: String, description: String, body: String) throws -> String {
        let slug = SkillStore.slugify(name)
        bodies[slug] = SkillSerializer.serialize(name: name, description: description, body: body)
        return slug
    }

    func readBody(directoryName: String) throws -> String { bodies[directoryName] ?? "" }

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
