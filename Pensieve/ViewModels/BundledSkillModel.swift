import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class BundledSkillModel {
    enum State { case absent, installed, update, edited }
    private(set) var state: State = .absent
    var error: String?
    private(set) var isWorking = false
    private var generation = 0
    private let files: FileServiceProtocol
    private let bundledDirectory: String
    private let receiptPath: String
    private let lockPath: String
    private let library: SkillLibraryViewModel
    private let importer: ImportViewModel

    private struct Receipt: Codable {
        let skillID: UUID
        let digest: String
    }

    init(files: FileServiceProtocol, bundledDirectory: String, receiptPath: String, lockPath: String,
         library: SkillLibraryViewModel, importer: ImportViewModel) {
        self.files = files
        self.bundledDirectory = bundledDirectory
        self.receiptPath = receiptPath
        self.lockPath = lockPath
        self.library = library
        self.importer = importer
    }

    var message: String {
        switch state {
        case .absent: return "Not in your library"
        case .installed: return "In your library"
        case .update: return "A newer version comes with this app"
        case .edited: return "A newer version comes with this app, and yours has edits"
        }
    }

    func refresh(context: ModelContext) async {
        guard !isWorking else { return }
        generation += 1
        let ticket = generation
        do {
            let snapshot = try await readState(context: context)
            guard ticket == generation else { return }
            if state != snapshot.state { error = nil }
            state = snapshot.state
        } catch {
            guard ticket == generation else { return }
            self.error = error.localizedDescription
        }
    }

    private struct Snapshot {
        var state: State = .absent
        var skillID: UUID?
        var current = Data()
        var bundled = Data()
    }

    private func readState(context: ModelContext) async throws -> Snapshot {
        let container = context.container
        let store = library.skillStore
        let files = files
        let directory = bundledDirectory
        return try await BlockingWork.run {
            let context = ModelContext(container)
            guard let skill = try Self.findSkill(context, store: store) else { return Snapshot() }
            let current = try store.readData(directoryName: skill.directoryName)
            let bundled = try files.readData(at: directory + "/SKILL.md")
            let state: State = current == bundled || BundledSkillContent.version(current) == BundledSkillContent.version(bundled)
                ? .installed : (BundledSkillContent.isUnedited(current) ? .update : .edited)
            return Snapshot(state: state, skillID: skill.id, current: current, bundled: bundled)
        }
    }

    private func beginAction() -> Bool {
        guard !isWorking else { return false }
        generation += 1
        isWorking = true
        error = nil
        return true
    }

    func add(context: ModelContext) async {
        guard beginAction() else { return }
        defer { isWorking = false }
        do {
            try requireAddsAllowed()
            let snapshot = try await readState(context: context)
            state = snapshot.state
            try requireAddsAllowed()
            guard snapshot.skillID == nil else { return }
            _ = try takenSlugsForAdd(context)
            guard case .found = importer.scanFolder(bundledDirectory) else {
                throw CommandLinkError(message: "The bundled pensieve skill couldn't be read.")
            }
            _ = importer.importSelected(context: context, takenSlugs: takenSlugsForAdd)
            guard importer.importedSkillCount > 0, let skill = try Self.findSkill(context, store: library.skillStore) else {
                throw CommandLinkError(message: importer.error ?? "The skill wasn't added.")
            }
            try await saveReceipt(skill)
            state = try await readState(context: context).state
            error = importer.error
        } catch { self.error = error.localizedDescription }
    }

    func update(context: ModelContext, replaceEdits: Bool = false) async {
        guard beginAction() else { return }
        defer { isWorking = false }
        do {
            try requireAddsAllowed()
            let lockPath = lockPath
            let acquired = try await BlockingWork.run { try SyncLock.tryAcquireReportingErrors(at: lockPath) }
            guard let lock = acquired else {
                throw CommandLinkError(message: "Sync is running. Try again when it finishes.")
            }
            defer { lock.release() }
            let snapshot = try await readState(context: context)
            state = snapshot.state
            try requireAddsAllowed()
            guard let id = snapshot.skillID,
                  let skill = try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id })).first else {
                return
            }
            guard !library.hasUnsavedChanges(for: skill) else {
                throw CommandLinkError(message: "Save or discard this skill's draft before updating it.")
            }
            let current = snapshot.current
            guard replaceEdits || BundledSkillContent.isUnedited(current) else {
                throw CommandLinkError(message: "Your copy has edits. Choose Replace to discard them.")
            }
            guard let original = String(data: current, encoding: .utf8) else {
                throw CommandLinkError(message: "The library copy is not readable UTF-8.")
            }
            guard let bundled = String(data: snapshot.bundled, encoding: .utf8) else {
                throw CommandLinkError(message: "The bundled skill is not readable UTF-8.")
            }
            guard library.updateDocument(skill, document: bundled,
                original: original).succeeded else {
                throw CommandLinkError(message: library.error ?? "The skill couldn't be updated.")
            }
            try context.save()
            try await saveReceipt(skill)
            library.notifySyncedStateMutation()
            error = nil
            state = try await readState(context: context).state
        } catch { self.error = error.localizedDescription }
    }

    nonisolated private static func findSkill(_ context: ModelContext, store: SkillStoreProtocol) throws -> Skill? {
        // Folder and marker sync together. Copies keep the marker, so it alone cannot identify the bundled skill.
        let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.directoryName == "pensieve" })
        for skill in try context.fetch(descriptor) {
            guard let bytes = try? store.readData(directoryName: skill.directoryName) else { continue }
            if BundledSkillContent.version(bytes) != nil { return skill }
        }
        return nil
    }

    private func takenSlugsForAdd(_ context: ModelContext) throws -> Set<String> {
        let taken = Set(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName))
        // Check before scanning and again under the import lock, after any pending sync ingestion.
        guard !taken.contains("pensieve"), try !library.skillStore.slugEntryExists("pensieve") else {
            throw CommandLinkError(message:
                "The pensieve folder is taken by another skill. Rename or remove that skill, then try again.")
        }
        return taken
    }

    private func requireAddsAllowed() throws {
        guard !library.addsFenced else {
            throw CommandLinkError(message: library.addFenceReason ?? "The library is unavailable.")
        }
    }

    private func saveReceipt(_ skill: Skill) async throws {
        let store = library.skillStore
        let directory = skill.directoryName
        let id = skill.id
        let files = files
        let receipt = receiptPath
        try await BlockingWork.run {
            let data = try store.readData(directoryName: directory)
            try files.writeData(at: receipt, data: JSONEncoder().encode(
                Receipt(skillID: id, digest: BundledSkillContent.digest(data))))
        }
    }
}
