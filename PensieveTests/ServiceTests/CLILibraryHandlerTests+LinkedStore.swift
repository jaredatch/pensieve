import SwiftData
import XCTest
@testable import Pensieve

extension CLILibraryHandlerTests {
    func testInstallThroughLinkedStorePublishesBeforeReply() async throws {
        let f = try CLILibraryFixture()
        defer { f.stop() }
        let real = f.root + "/real-store"
        try f.files.publishDirectory(at: f.paths.storeRoot, to: real)
        try f.files.createSymlink(at: f.paths.storeRoot, pointingTo: real)
        try await f.start()
        let reply = await CLILibraryHandler(runtime: f.runtime, files: f.files).handle(CLIRequest(command: "install",
            arguments: [f.sourceURL], library: CLILibraryOptions(confirmed: true)))
        XCTAssertTrue(reply.envelope.ok, String(describing: reply.envelope.error))
        XCTAssertEqual(try f.files.readFile(at: real + "/skills/foo/SKILL.md"), CLILibraryFixture.document("original"))
        XCTAssertEqual(try f.skill().directoryName, "foo")
        XCTAssertEqual(try ManifestService().read(fromRoot: real).skills.map(\.slug), ["foo"])
    }

}
