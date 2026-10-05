import Foundation
import SwiftData
@testable import Pensieve

@MainActor
final class UpdateReviewFixture {
    let root = NSTemporaryDirectory() + "UpdateReview-\(UUID().uuidString)"
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
                    diff: UpdatesViewModel.DiffOperation? = nil,
                    apply: UpdatesViewModel.ApplyOperation? = nil,
                    recheck: UpdatesViewModel.RecheckOperation? = nil) -> UpdateReviewOperations {
        UpdateReviewOperations(rowLoader: { _ in rows }, previewRowLoader: { id, _ in rows.first { $0.id == id } },
                               applyOperation: apply ?? { _, _, _, _, _, _ in
            throw SkillUpdateFlowError.repositoryChanged
        }, diffOperation: diff ?? { _, _, _, _ in preview }, recheckOperation: recheck ?? { _, _ in
            throw SkillUpdateFlowError.skillNotFound
        })
    }

    func sheet(rows: [UpdatesRow], diff: UpdatesViewModel.DiffOperation? = nil,
               apply: UpdatesViewModel.ApplyOperation? = nil) -> UpdatesViewModel {
        sheet(operations: operations(rows: rows, diff: diff, apply: apply), coordinator: SkillUpdateApplyCoordinator())
    }

    func review(rows: [UpdatesRow], diff: UpdatesViewModel.DiffOperation? = nil,
                apply: UpdatesViewModel.ApplyOperation? = nil) -> (UpdatesViewModel, ViewChangesViewModel) {
        let operations = operations(rows: rows, diff: diff, apply: apply)
        let coordinator = SkillUpdateApplyCoordinator()
        return (sheet(operations: operations, coordinator: coordinator),
                ViewChangesViewModel(library: library, operations: operations, applyCoordinator: coordinator))
    }

    private func sheet(operations: UpdateReviewOperations, coordinator: SkillUpdateApplyCoordinator) -> UpdatesViewModel {
        UpdatesViewModel(rowLoader: operations.rowLoader, applyOperation: operations.applyOperation,
                         diffOperation: operations.diffOperation, recheckOperation: operations.recheckOperation,
                         applyCoordinator: coordinator)
    }

    nonisolated static func preview() -> PinnedSkillDiff {
        PinnedSkillDiff(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "SKILL.md", kind: .modified, content: .text(old: "old\n", new: "new\nextra\n")),
            FileTreeChange(path: "scripts/setup.sh", kind: .added, content: .text(old: "", new: "echo setup\n"))
        ], unreadFileCount: 3, bytesRead: 40))
    }
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
