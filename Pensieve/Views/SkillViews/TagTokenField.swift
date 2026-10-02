import AppKit
import SwiftUI

/// Finder's Get Info Tags field and Mail's To field: an `NSTokenField` (SwiftUI has no token
/// control). Tokens are the skill's tags; completions are the tags in use across the library. A
/// commit fires when editing ends (Return, or focus leaving the field) and only when the normalized
/// token list differs from what the view was given. (PLAN-30 / 30.1)
struct TagTokenField: NSViewRepresentable {
    let tokens: [String]
    let tagsInUse: [String]
    let onCommit: ([String]) -> Void

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.completionDelay = 0.1
        field.placeholderString = "Add tags"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.objectValue = tokens
        context.coordinator.baseline = tokens
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // Never clobber an edit in progress: a value pushed while the field is first responder
        // would discard what the user is typing. The coordinator re-syncs after editing ends.
        guard field.currentEditor() == nil else { return }
        let shown = (field.objectValue as? [String]) ?? []
        if shown != tokens { field.objectValue = tokens }
        // What the field shows when it is not editing is the baseline the next edit starts from.
        // AppKit sends no notification when the field merely gains focus (the field editor appears
        // silently; `controlTextDidBeginEditing` arrives with the first keystroke), so the baseline
        // must be seeded here, not in a delegate callback — probed at Stage 30.1's Layer-1.
        context.coordinator.baseline = tokens
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TagTokenField
        /// The tokens the field showed before editing began (seeded by the representable whenever
        /// the field is not editing); an edit that ends with the same tokens never writes (a sync
        /// pull that landed meanwhile must not be overwritten by a mere focus-and-blur).
        var baseline: [String] = []

        init(parent: TagTokenField) { self.parent = parent }

        func tokenField(_ tokenField: NSTokenField,
                        completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let present = (tokenField.objectValue as? [String]) ?? []
            return TagTokens.completions(for: substring, inUse: parent.tagsInUse, excluding: present)
        }

        /// Return tokenizes the pending text but does not end editing on an `NSTokenField` (probed
        /// live before freeze); ending editing here is what fires the commit below. Mail's To field
        /// behaves the same way: Return is "done". With a completion showing, Return accepts it first
        /// and then lands here (probed: "be" → beta → committed).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let shown = (field.objectValue as? [String]) ?? []
            switch TagTokens.commitDecision(baseline: baseline, edited: shown, stored: parent.tokens) {
            case .nothing:
                let tidy = TagTokens.normalize(shown)
                if tidy != shown { field.objectValue = tidy }   // the same tags, tidier
            case .adoptStored:
                field.objectValue = TagTokens.normalize(parent.tokens)
            case .commit(let tags):
                parent.onCommit(tags)
            }
            // Whatever the field shows now is the next session's baseline. SwiftUI calls `updateNSView`
            // only when an input changes, so after `.adoptStored` (no input changed) the baseline
            // would otherwise stay stale and a later deletion of the adopted tag would read as
            // untouched (Stage 30.1's resumed Layer-1).
            baseline = (field.objectValue as? [String]) ?? []
        }
    }
}
