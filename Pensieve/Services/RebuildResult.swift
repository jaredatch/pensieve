import Foundation

/// Disk + manifest reconciliation effects. Warnings include missing skill frontmatter or files,
/// unreadable manifests and failed category fetches. An idempotent second pass has zero effects.
struct RebuildResult: Equatable {
    var skillsInserted: Int = 0
    var skillsUpdated: Int = 0
    var skillsRemoved: Int = 0
    var categoriesInserted: Int = 0
    var categoriesUpdated: Int = 0
    var categoriesRemoved: Int = 0
    var deployIntentsInserted: Int = 0
    var deployIntentsUpdated: Int = 0
    var deployIntentsRemoved: Int = 0
    var warnings: [String] = []
    /// True when the rebuild BAILED because the manifest was unreadable (a newer/unsupported schema) —
    /// nothing was ingested. Distinct from per-item `warnings`. `SyncEngine` refuses to push over a store
    /// it couldn't read (a downgrade) and surfaces "update Pensieve" instead. (PLAN-08 / 08.4 review)
    var storeUnreadable: Bool = false
    /// The rebuild computed changes but its save failed. Unrelated caller edits do not set this flag.
    var saveFailed: Bool = false
    /// The authoritative category reconcile was skipped because its local fetch threw.
    /// A non-authoritative manifest does not attempt that fetch and leaves this false.
    var categoryReadFailed: Bool = false

    var skillReadFailed: Bool = false
    var deployIntentReadFailed: Bool = false
    var skillListFailed: Bool = false

    var ingestIncomplete: Bool {
        saveFailed || categoryReadFailed || skillReadFailed || deployIntentReadFailed || skillListFailed
    }
    /// A successful category fetch, ordered against local edits. Only the disk-reading entry point
    /// announces this receipt, after the rebuild saves. Previews and acceptance never announce.
    @Receipt var categoryRead: CategorySaveWindow.ReadReceipt?

    /// Receipts order observations but contribute no reconcile effects. The enclosing result's
    /// synthesized equality still includes every effect field, including future additions.
    @propertyWrapper
    struct Receipt: Equatable {
        var wrappedValue: CategorySaveWindow.ReadReceipt?
        static func == (lhs: Self, rhs: Self) -> Bool { true }
    }
}
