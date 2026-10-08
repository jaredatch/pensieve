import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func testBinaryAndUTF16ConflictsRenderUnavailableTextAndKeepSelections() async throws {
        for payload in SyncConflictByteFixture.payloads {
            let fixture = try SyncConflictByteFixture(name: payload.name, this: payload.this, other: payload.other)
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let model = ConflictResolutionModel(engine: fixture.engine, git: fixture.git,
                credentials: InMemoryCredentialStore(), root: fixture.storeB)
            await model.loadAndReport(context: fixture.contextB)
            guard case let .ready(groups) = model.phase else { return XCTFail("A real conflict must load the sheet") }
            let group = try XCTUnwrap(groups.first)
            let item = try XCTUnwrap(group.items.first)
            XCTAssertEqual(item.path, fixture.path)
            let host = NSHostingView(rootView: AnyView(ConflictFileComparison(item: item).frame(width: 520)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                 failureMessage: "The sheet comparison must actually render both side labels") {
                let strings = self.comparisonStrings(in: host)
                return strings.contains("This Mac") && strings.contains("Other Mac")
            }
            let strings = comparisonStrings(in: host)
            XCTAssertGreaterThanOrEqual(strings.filter { $0 == "This file can’t be shown as text." }.count, 2,
                                        "Each non-text side must explain why no text preview is shown")
            XCTAssertFalse(strings.contains("Empty file"), "Binary and UTF-16 sides are not empty files")
            XCTAssertFalse(try XCTUnwrap(item.thisMachine).isEmpty)
            XCTAssertFalse(try XCTUnwrap(item.otherMachine).isEmpty)
            XCTAssertFalse(model.canApply)
            model.choose(group.id, .otherMachine)
            XCTAssertTrue(model.canApply, "An unavailable text preview must not block choosing exact bytes")
        }
    }

    private func comparisonStrings(in host: NSHostingView<AnyView>) -> [String] {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap { RenderedViewTestSupport.strings(in: $0) }
    }
}
