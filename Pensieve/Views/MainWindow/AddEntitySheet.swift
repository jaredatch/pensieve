import SwiftData
import SwiftUI

/// Which add sheet the detail toolbar's + control opens for a non-skill section (PLAN-29). Skills use
/// `library.showCreateSheet`, the import wizard, and the GitHub sheet, which `ContentView` owns.
enum AddSheet: String, Identifiable {
    case project
    case category

    var id: String { rawValue }
}

/// The two add sheets that lived in their list views until PLAN-29, presented by `ContentView` so
/// the detail toolbar's + control can open them from any column. Each creates through the same store
/// call its list view used.
struct AddEntitySheet: View {
    let kind: AddSheet
    let notifier: SyncStateNotifying
    let intentReconciler: @MainActor (ModelContext) -> BatchResult
    let onCreated: (EntitySelection) -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        switch kind {
        case .project:
            AddProjectSheet(
                notifier: notifier,
                intentReconciler: intentReconciler,
                onCreated: { onCreated(.project($0.id)) }
            )
        case .category:
            EntityNameSheet(title: "Add Category", fieldLabel: "Category Name", actionTitle: "Add") { name in
                let created = CategoryStore(manifestService: ManifestService(), notifier: notifier)
                    .create(name: name, context: context)
                if let created { onCreated(.category(created.id)) }
            }
        }
    }
}
