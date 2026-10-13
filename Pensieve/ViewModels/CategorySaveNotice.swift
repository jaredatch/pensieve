import Foundation

struct CategorySaveNotice {
    enum Outcome {
        case undone, saved, removed, restored
        init(restoration: CategorySaveEdit.Restoration) {
            switch restoration {
            case .undone: self = .undone
            case .restored: self = .restored
            case .removed: self = .removed
            }
        }
    }
    struct Entry {
        let text: String
        let wasKept: Bool
    }
    let entries: [Entry]
    var messages: [String] { entries.map(\.text) }
    var title: String {
        !entries.isEmpty && entries.allSatisfy(\.wasKept)
            ? "Category changes were already saved" : "Category changes couldn't be saved"
    }
    var message: String { messages.joined(separator: "\n\n") }

    static func entry(edit: CategorySaveEdit, error: Error, outcome: Outcome) -> Entry {
        let result: String
        switch outcome {
        case .undone: result = "Couldn't save the change to “\(edit.name)”, so it was undone."
        case .restored: result = "Couldn't save the change to “\(edit.name)”. It now shows what's saved."
        case .saved: result = "The change to “\(edit.name)” is already saved and was kept. Its save couldn't be confirmed."
        case .removed: result = "The category “\(edit.name)” is gone, so this change was dropped."
        }
        return Entry(text: "\(result) \(error.localizedDescription)", wasKept: outcome == .saved)
    }
}
