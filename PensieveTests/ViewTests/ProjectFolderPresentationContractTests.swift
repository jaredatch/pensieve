import XCTest
@testable import Pensieve

final class ProjectFolderPresentationContractTests: XCTestCase {
    func testIdentityStatusPreservesSecondaryAndTertiaryStyles() throws {
        let source = try readSource("Pensieve/Views/ProjectViews/AddProjectSheet.swift")
        XCTAssertFalse(source.contains("model.hasIdentityError ? .primary"), "Refusal uses the existing status style")
        XCTAssertTrue(source.contains(".tertiary"), "The marker preview keeps its tertiary style")
        XCTAssertTrue(source.contains(".secondary"), "Existing identities keep their secondary style")
    }

    func testPlatformFileServiceRemainsPrivate() throws {
        let source = try readSource("Pensieve/ViewModels/PlatformViewModel.swift")
        XCTAssertTrue(source.contains("private let fileService: FileServiceProtocol"))
    }

    private func readSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try FileService().readFile(at: root.appendingPathComponent(relative).path)
    }
}
