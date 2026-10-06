import Foundation
import SwiftData
@testable import Pensieve

@MainActor
final class UpdateReviewFixture {
    let root = TestTemporaryDirectory.path + "UpdateReview-\(UUID().uuidString)"
    let files = FileService()
    let container: ModelContainer
    let context: ModelContext
    let library: SkillLibraryViewModel

    init() throws {
        container = try ModelContainer(for: Skill.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: files, baseDir: root + "/skills"), fileService: files,
            fileWatchService: FileWatchService(rootDir: root + "/skills"), manifestRoot: root
        )
        try files.createDirectory(at: root)
    }

    func cleanup() throws { try files.deleteDirectory(at: root) }

    func skill(_ slug: String) throws -> Skill {
        let skill = Skill(name: slug.capitalized, directoryName: slug)
        skill.installedOrigin = InstalledOrigin(
            repo: "https://github.com/example/repository", path: "skills/" + slug, ref: "main",
            installedCommit: String(repeating: "1", count: 40), installedTree: "old-tree",
            contentHash: "old-hash", installedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        skill.updateAvailable = true
        skill.upstreamCommit = String(repeating: "2", count: 40)
        skill.upstreamTree = "new-tree"
        skill.upstreamCommitDate = Date(timeIntervalSince1970: 3 * 86_400)
        context.insert(skill)
        try files.writeFile(at: root + "/skills/" + slug + "/SKILL.md", content: "old body\n")
        try context.save()
        return skill
    }

    func operations(rows: [UpdatesRow], preview: PinnedSkillDiff = preview(),
                    diff: UpdateReviewOperations.DiffOperation? = nil,
                    recheck: UpdatesViewModel.RecheckOperation? = nil) -> UpdateReviewOperations {
        UpdateReviewOperations(diffOperation: { row, container in
            guard rows.contains(where: { $0.id == row.id }) else { throw SkillUpdateFlowError.missingPinnedUpdate }
            return try diff?(row, container) ?? preview
        }, recheckOperation: recheck ?? { _, _ in
            throw SkillUpdateFlowError.skillNotFound
        })
    }

    func sheet(rows: [UpdatesRow], apply: UpdatesViewModel.ApplyOperation? = nil) -> UpdatesViewModel {
        UpdatesViewModel(rowLoader: { _ in rows }, applyOperation: apply ?? { _, _, _, _, _, _ in
            throw SkillUpdateFlowError.repositoryChanged
        }, recheckOperation: { _, _ in
            throw SkillUpdateFlowError.skillNotFound
        })
    }

    func review(rows: [UpdatesRow], diff: UpdateReviewOperations.DiffOperation? = nil,
                apply: UpdatesViewModel.ApplyOperation? = nil) -> (UpdatesViewModel, ViewChangesViewModel) {
        (sheet(rows: rows, apply: apply),
         ViewChangesViewModel(library: library, operations: operations(rows: rows, diff: diff)))
    }

    nonisolated static func preview() -> PinnedSkillDiff { fixedPreview }

    // Shared immutable fixture is built once before operations start their cancellable workers.
    nonisolated private static let fixedPreview: PinnedSkillDiff = {
        do {
            return try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
                FileTreeChange(path: "SKILL.md", kind: .modified, content: .text(old: "old\n", new: "new\nextra\n")),
                FileTreeChange(path: "scripts/setup.sh", kind: .added, content: .text(old: "", new: "echo setup\n"))
            ], unreadFileCount: 3, bytesRead: 40))
        } catch { preconditionFailure("The fixed preview fixture must build: \(error)") }
    }()
}

/// Thread-safe recording for detached operation outcomes, without worker-thread XCTest assertions.
final class UpdateReviewRecorder<Value> {
    private let lock = NSLock()
    private var recorded: [Value] = []
    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
    }
}
