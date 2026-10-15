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

    func refresh(context: ModelContext) {
        do {
            guard let skill = try findSkill(context) else { state = .absent; return }
            let current = try library.skillStore.readData(directoryName: skill.directoryName)
            let bundled = try files.readData(at: bundledDirectory + "/SKILL.md")
            if current == bundled { state = .installed; return }
            let receipt = try readReceipt()
            if receipt?.skillID == skill.id && receipt?.digest == digest(bundled) { state = .installed; return }
            state = receipt?.skillID == skill.id && receipt?.digest == digest(current) ? .update : .edited
        } catch { self.error = error.localizedDescription }
    }

    func add(context: ModelContext) {
        do {
            guard !library.addsFenced else {
                throw CommandLinkError(message: library.addFenceReason ?? "The library is unavailable.")
            }
            guard try findSkill(context) == nil else { refresh(context: context); return }
            guard case .found = importer.scanFolder(bundledDirectory) else {
                throw CommandLinkError(message: "The bundled pensieve skill couldn't be read.")
            }
            _ = importer.importSelected(context: context)
            if let failure = importer.error { throw CommandLinkError(message: failure) }
            guard let skill = try findSkill(context) else { throw CommandLinkError(message: "The skill wasn't added.") }
            try saveReceipt(skill)
            error = nil
            refresh(context: context)
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
            let receipt = try readReceipt()
            guard replaceEdits || (receipt?.skillID == skill.id && receipt?.digest == digest(current)) else {
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
            refresh(context: context)
        } catch { self.error = error.localizedDescription }
    }

    private func findSkill(_ context: ModelContext) throws -> Skill? {
        try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.directoryName == "pensieve" })).first
    }

    private func readReceipt() throws -> Receipt? {
        guard try files.entryExistsWithoutFollowingLinks(at: receiptPath) else { return nil }
        return try JSONDecoder().decode(Receipt.self, from: files.readData(at: receiptPath))
    }

    private func saveReceipt(_ skill: Skill) throws {
        let data = try library.skillStore.readData(directoryName: skill.directoryName)
        try files.writeData(at: receiptPath, data: JSONEncoder().encode(Receipt(skillID: skill.id, digest: digest(data))))
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
