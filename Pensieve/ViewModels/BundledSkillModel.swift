import CryptoKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class BundledSkillModel {
    enum State { case absent, installed, update, edited }
    private(set) var state: State = .absent
    var error: String?
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
        let container = context.container
        let store = library.skillStore
        let files = files
        let directory = bundledDirectory
        do {
            state = try await BlockingWork.run {
                try Self.readState(context: ModelContext(container), store: store, files: files, directory: directory)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func refreshAfterAction(context: ModelContext) throws {
        state = try Self.readState(context: context, store: library.skillStore, files: files, directory: bundledDirectory)
    }

    nonisolated private static func readState(context: ModelContext, store: SkillStoreProtocol,
                                              files: FileServiceProtocol, directory: String) throws -> State {
        guard let skill = try findSkill(context, store: store) else { return .absent }
        let current = try store.readData(directoryName: skill.directoryName)
        let bundled = try files.readData(at: directory + "/SKILL.md")
        if current == bundled || BundledSkillContent.version(current) == BundledSkillContent.version(bundled) {
            return .installed
        }
        return BundledSkillContent.isUnedited(current) ? .update : .edited
    }

    func add(context: ModelContext) {
        do {
            guard !library.addsFenced else {
                throw CommandLinkError(message: library.addFenceReason ?? "The library is unavailable.")
            }
            guard try findSkill(context) == nil else { try refreshAfterAction(context: context); return }
            guard case .found = importer.scanFolder(bundledDirectory) else {
                throw CommandLinkError(message: "The bundled pensieve skill couldn't be read.")
            }
            _ = importer.importSelected(context: context)
            guard importer.importedSkillCount > 0, let skill = try findSkill(context) else {
                throw CommandLinkError(message: importer.error ?? "The skill wasn't added.")
            }
            try saveReceipt(skill)
            try refreshAfterAction(context: context)
            error = importer.error
        } catch { self.error = error.localizedDescription }
    }

    func update(context: ModelContext, replaceEdits: Bool = false) {
        do {
            guard !library.addsFenced else {
                throw CommandLinkError(message: library.addFenceReason ?? "The library is unavailable.")
            }
            guard let lock = try SyncLock.tryAcquireReportingErrors(at: lockPath) else {
                throw CommandLinkError(message: "Sync is running. Try again when it finishes.")
            }
            defer { lock.release() }
            guard let skill = try findSkill(context) else { return }
            guard !library.hasUnsavedChanges(for: skill) else {
                throw CommandLinkError(message: "Save or discard this skill's draft before updating it.")
            }
            let current = try library.skillStore.readData(directoryName: skill.directoryName)
            guard replaceEdits || BundledSkillContent.isUnedited(current) else {
                throw CommandLinkError(message: "Your copy has edits. Choose Replace to discard them.")
            }
            guard let original = String(data: current, encoding: .utf8) else {
                throw CommandLinkError(message: "The library copy is not readable UTF-8.")
            }
            let bundled = try files.readFile(at: bundledDirectory + "/SKILL.md")
            guard library.updateDocument(skill, document: bundled,
                original: original).succeeded else {
                throw CommandLinkError(message: library.error ?? "The skill couldn't be updated.")
            }
            try context.save()
            try saveReceipt(skill)
            library.notifySyncedStateMutation()
            error = nil
            try refreshAfterAction(context: context)
        } catch { self.error = error.localizedDescription }
    }

    private func findSkill(_ context: ModelContext) throws -> Skill? {
        try Self.findSkill(context, store: library.skillStore)
    }

    nonisolated private static func findSkill(_ context: ModelContext, store: SkillStoreProtocol) throws -> Skill? {
        for skill in try context.fetch(FetchDescriptor<Skill>()) {
            guard let bytes = try? store.readData(directoryName: skill.directoryName) else { continue }
            if BundledSkillContent.version(bytes) != nil { return skill }
        }
        return nil
    }

    private func saveReceipt(_ skill: Skill) throws {
        let data = try library.skillStore.readData(directoryName: skill.directoryName)
        try files.writeData(at: receiptPath, data: JSONEncoder().encode(Receipt(skillID: skill.id, digest: digest(data))))
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
