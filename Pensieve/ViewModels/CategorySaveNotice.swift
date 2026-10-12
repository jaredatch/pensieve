import Foundation

struct CategorySaveNotice {
    let messages: [String]
    var title: String { "Category changes couldn't be saved" }
    var message: String { messages.joined(separator: "\n\n") }

    static func message(edit: CategorySaveEdit, error: Error, undone: Bool) -> String {
        let outcome = undone ? "Couldn't save the change to “\(edit.name)”, so it was undone."
            : "The change to “\(edit.name)” is already saved and was kept. Its save couldn't be confirmed."
        let reason: String
        if case ManifestError.unsupportedSchema = error {
            reason = "Another Mac synced with a newer version of Pensieve. Update Pensieve on this Mac to change categories."
        } else { reason = error.localizedDescription }
        return "\(outcome) \(reason)"
    }
}
