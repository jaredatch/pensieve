import AppKit
import UniformTypeIdentifiers

/// The configuration and presentation surface used by skill export; AppKit supplies the real panel.
@MainActor
protocol SkillExportSavePanel: AnyObject {
    var nameFieldStringValue: String { get set }
    var allowedContentTypes: [UTType] { get set }
    var canCreateDirectories: Bool { get set }
    var url: URL? { get }

    func setExportMessage(_ message: String)
    func beginSheetModal(for window: NSWindow,
                         completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void)
    func runModal() -> NSApplication.ModalResponse
}

extension NSSavePanel: SkillExportSavePanel {
    // AppKit's null-resettable message property has different getter and setter types.
    func setExportMessage(_ message: String) {
        self.message = message
    }
}

/// NSSavePanel supplies the standard filename, folder creation, and replacement confirmation controls.
/// Export belongs to Pensieve's single main window, even when a context-menu click hasn't made it key.
@MainActor
enum SkillExportPanel {
    static func present(skill: Skill, library: SkillLibraryViewModel) {
        present(model: SkillExportModel(skill: skill, library: library),
                on: WindowPolicy.mainWindow(among: NSApp.windows))
    }

    static func present(model: SkillExportModel, on window: NSWindow?,
                        panel: any SkillExportSavePanel = NSSavePanel(),
                        makeAlert: @escaping () -> NSAlert = { NSAlert() }) {
        panel.nameFieldStringValue = model.suggestedFileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.setExportMessage(model.message)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try model.export(to: destination.path)
            } catch {
                let alert = makeAlert()
                alert.messageText = "Export failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                if let window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window) { response in
                // AppKit calls back before detaching the save sheet. Let it leave before showing an error.
                DispatchQueue.main.async { finish(response) }
            }
        } else {
            finish(panel.runModal())
        }
    }
}
