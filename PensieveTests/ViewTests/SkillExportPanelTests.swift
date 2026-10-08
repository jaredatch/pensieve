import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Pensieve

@MainActor
final class SkillExportPanelTests: XCTestCase {
    private final class RecordingSavePanel: SkillExportSavePanel {
        var nameFieldStringValue = ""
        var allowedContentTypes: [UTType] = []
        var canCreateDirectories = false
        var message: String?
        var chosenURL: URL?
        var host: NSWindow?
        var completion: ((NSApplication.ModalResponse) -> Void)?
        var modalCalls = 0
        var modalResponse: NSApplication.ModalResponse = .cancel

        var url: URL? { chosenURL }

        func setExportMessage(_ message: String) {
            self.message = message
        }

        func beginSheetModal(for window: NSWindow,
                             completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
            host = window
            completion = handler
        }

        func runModal() -> NSApplication.ModalResponse {
            modalCalls += 1
            return modalResponse
        }

        func complete(_ response: NSApplication.ModalResponse) {
            let callback = completion
            completion = nil
            callback?(response)
        }
    }

    private final class RecordingAlert: NSAlert {
        var host: NSWindow?
        var modalCalls = 0

        override func beginSheetModal(for window: NSWindow,
                                      completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            host = window
        }

        override func runModal() -> NSApplication.ModalResponse {
            modalCalls += 1
            return .alertFirstButtonReturn
        }
    }

    private let fileService = FileService()
    private var root = ""
    private var source: String { root + "/skills/export-skill/SKILL.md" }
    private var destination: String { root + "/export.md" }

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "SkillExportPanelTests-" + UUID().uuidString
        try fileService.writeFile(at: source, content: "Stored bytes")
    }

    override func tearDownWithError() throws {
        try fileService.deleteDirectory(at: root)
    }

    func testSavePanelUsesTheGivenWindowAndCancelWritesNothing() {
        let panel = RecordingSavePanel()
        let window = NSWindow()
        var alerted = false
        SkillExportPanel.present(model: makeModel(), on: window, panel: panel) {
            alerted = true
            return RecordingAlert()
        }
        XCTAssertTrue(panel.host === window)
        XCTAssertEqual(panel.modalCalls, 0)
        XCTAssertEqual(panel.nameFieldStringValue, "export-skill.md")
        XCTAssertEqual(panel.allowedContentTypes, [UTType(filenameExtension: "md") ?? .plainText])
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertEqual(panel.message, makeModel().message)
        panel.chosenURL = URL(fileURLWithPath: destination)
        panel.complete(.cancel)
        finishDismissal()
        XCTAssertFalse(fileService.fileExists(at: destination))
        XCTAssertFalse(alerted)
    }

    func testConfirmingTheSheetExportsAfterItDismisses() throws {
        let panel = RecordingSavePanel()
        panel.chosenURL = URL(fileURLWithPath: destination)
        SkillExportPanel.present(model: makeModel(), on: NSWindow(), panel: panel)
        panel.complete(.OK)
        XCTAssertFalse(fileService.fileExists(at: destination), "Let the sheet detach before exporting")
        finishDismissal()
        XCTAssertEqual(try fileService.readData(at: destination), try fileService.readData(at: source))
        XCTAssertEqual(panel.modalCalls, 0)
    }

    func testReadErrorUsesTheSameWindowAfterTheSaveSheetDismisses() throws {
        try fileService.deleteFile(at: source)
        let panel = RecordingSavePanel()
        panel.chosenURL = URL(fileURLWithPath: destination)
        let alert = RecordingAlert()
        let window = NSWindow()
        SkillExportPanel.present(model: makeModel(), on: window, panel: panel, makeAlert: { alert })
        panel.complete(.OK)
        XCTAssertNil(alert.host)
        finishDismissal()
        XCTAssertTrue(alert.host === window)
        XCTAssertEqual(alert.modalCalls, 0)
        XCTAssertEqual(alert.messageText, "Export failed")
        XCTAssertFalse(alert.informativeText.isEmpty)
        XCTAssertFalse(fileService.fileExists(at: destination))
    }

    func testWithoutAWindowBothPresentationsFallBackToModal() throws {
        try fileService.deleteFile(at: source)
        let panel = RecordingSavePanel()
        panel.chosenURL = URL(fileURLWithPath: destination)
        panel.modalResponse = .OK
        let alert = RecordingAlert()
        SkillExportPanel.present(model: makeModel(), on: nil, panel: panel, makeAlert: { alert })
        XCTAssertEqual(panel.modalCalls, 1)
        XCTAssertEqual(alert.modalCalls, 1)
        XCTAssertNil(panel.host)
        XCTAssertNil(alert.host)
    }

    private func makeModel() -> SkillExportModel {
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService, baseDir: root + "/skills"),
            fileService: fileService, manifestRoot: root
        )
        return SkillExportModel(skill: Skill(name: "Export", directoryName: "export-skill"), library: library)
    }

    private func finishDismissal() {
        let finished = expectation(description: "Sheet completion handled on the next main turn")
        DispatchQueue.main.async { finished.fulfill() }
        wait(for: [finished], timeout: TestWait.hostedActionTimeoutSeconds)
    }
}
