import Foundation
import SwiftData

/// Dependencies shared by the sheet and window; these values own no presentation or apply state.
struct UpdateReviewOperations {
    typealias PreviewRowLoader = (UUID, ModelContainer) throws -> UpdatesRow?
    let rowLoader: UpdatesViewModel.RowLoader
    let previewRowLoader: PreviewRowLoader
    let applyOperation: UpdatesViewModel.ApplyOperation
    let diffOperation: UpdatesViewModel.DiffOperation
    let recheckOperation: UpdatesViewModel.RecheckOperation
    let notifier: SyncStateNotifying
    let echoRegistrar: SyncWriteEchoRegistering
    let bodyWriteRegistration: SyncBodyWriteRegistration

    init(rowLoader: @escaping UpdatesViewModel.RowLoader,
         previewRowLoader: @escaping PreviewRowLoader,
         applyOperation: @escaping UpdatesViewModel.ApplyOperation,
         diffOperation: @escaping UpdatesViewModel.DiffOperation,
         recheckOperation: @escaping UpdatesViewModel.RecheckOperation,
         notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
         echoRegistrar: @escaping SyncWriteEchoRegistering = SyncWriteEchoRegistrar.suppressed,
         bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed) {
        self.rowLoader = rowLoader
        self.previewRowLoader = previewRowLoader
        self.applyOperation = applyOperation
        self.diffOperation = diffOperation
        self.recheckOperation = recheckOperation
        self.notifier = notifier
        self.echoRegistrar = echoRegistrar
        self.bodyWriteRegistration = bodyWriteRegistration
    }
}
