import Foundation

struct CategorySaveNotice {
    enum Outcome { case undone, saved, removed }
    let messages: [String]
    var title: String { "Category changes couldn't be saved" }
    var message: String { messages.joined(separator: "\n\n") }

    static func message(edit: CategorySaveEdit, error: Error, outcome: Outcome) -> String {
        let result: String
        switch outcome {
        case .undone: result = "Couldn't save the change to “\(edit.name)”, so it was undone."
        case .saved: result = "The change to “\(edit.name)” is already saved and was kept. Its save couldn't be confirmed."
        case .removed: result = "The category “\(edit.name)” is gone, so this change was dropped."
        }
        let reason: String
        if case ManifestError.unsupportedSchema = error {
            reason = "Another Mac synced with a newer version of Pensieve. Update Pensieve on this Mac to change categories."
        } else { reason = error.localizedDescription }
        return "\(result) \(reason)"
    }
}
