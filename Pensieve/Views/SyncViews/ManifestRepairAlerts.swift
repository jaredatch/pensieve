import SwiftUI

struct ManifestRepairAlerts: ViewModifier {
    @Environment(\.modelContext) private var context
    var saves: ManifestSaveModel?

    func body(content: Content) -> some View {
        content
            .alert(ManifestSaveModel.damageTitle, isPresented: Binding(
                get: { saves?.showsDamageAlert == true },
                set: { shown in
                    saves?.showsDamageAlert = shown
                    if !shown, saves?.repairError == ManifestSaveModel.changedRepairMessage { saves?.repairError = nil }
                }
            )) {
                Button("OK", role: .cancel) {}.keyboardShortcut(.defaultAction)
                Button(ManifestSaveModel.repairAction) { saves?.requestRepair() }
            } message: {
                Text(saves?.damageAlertMessage ?? ManifestSaveModel.damageMessage)
            }
            .alert(ManifestSaveModel.repairTitle, isPresented: Binding(
                get: { saves?.showsRepairConfirmation == true },
                set: { saves?.showsRepairConfirmation = $0 }
            )) {
                Button("Replace", role: .destructive) {
                    Task { await saves?.replaceWithThisMac(context: context) }
                }
                Button("Cancel", role: .cancel) { saves?.cancelRepair() }
            } message: {
                Text(ManifestSaveModel.repairMessage)
            }
            .alert("Couldn't repair the library file", isPresented: Binding(
                get: { saves?.repairError != nil && saves?.repairError != ManifestSaveModel.changedRepairMessage },
                set: { if !$0 { saves?.repairError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saves?.repairError ?? "")
            }
    }
}
