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

    func testDeletedAndEmptySidesHaveDistinctLabelsInRealConflicts() async throws {
        for other in [Data(), Data("nonempty text\n".utf8), Data([0, 255])] {
            for deletedSide in [ConflictSide.thisMachine, .otherMachine] {
                let fixture = try SyncConflictByteFixture(name: "delete.txt",
                    this: deletedSide == .thisMachine ? nil : other,
                    other: deletedSide == .otherMachine ? nil : other)
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                let strings = await renderedComparison(try fixture.inspect())
                XCTAssertEqual(strings.filter { $0 == "Deleted" }.count, 1)
                XCTAssertEqual(strings.filter { $0 == "Empty file" }.count, other.isEmpty ? 1 : 0)
            }
        }
    }

    func testBOMDifferenceAndBoundedFallbackPreviewInRealConflicts() async throws {
        let bom = try SyncConflictByteFixture(name: "bom.txt", this: Data([0xEF, 0xBB, 0xBF]) + Data("same".utf8),
                                             other: Data("same".utf8))
        defer { try? bom.files.deleteDirectory(at: bom.root) }
        let strings = await renderedComparison(try bom.inspect())
        XCTAssertTrue(strings.contains("\u{FEFF}same"), "The comparison must preserve the leading BOM")
        XCTAssertTrue(strings.contains("same"))
        for (count, trailingNewline) in [(405, false), (400, true), (401, true), (405, true)] {
            let text = (1...count).map { "preview line \($0)" }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
            let large = try SyncConflictByteFixture(name: "large.txt", this: Data(text.utf8), other: Data([0, 255]))
            defer { try? large.files.deleteDirectory(at: large.root) }
            let preview = await renderedComparison(try large.inspect())
            XCTAssertTrue(preview.contains { $0.contains("preview line 400") })
            XCTAssertFalse(preview.contains { $0.contains("preview line 401") }, "Fallback must cap the rendered text")
            let notice = preview.filter { $0.hasPrefix("Showing the first") || $0.hasPrefix("... preview truncated") }
            if count == 400 {
                XCTAssertTrue(notice.isEmpty, "A trailing newline is not a hidden line")
            } else {
                let expected = count == 401 ? "Showing the first 400 lines. 1 more isn’t shown."
                    : "Showing the first 400 lines. 5 more aren’t shown."
                XCTAssertEqual(notice, [expected])
            }
        }
    }

    func testLegacyGitlinkConflictReachesTheSheetAndKeepsTheOtherSideAvailable() async throws {
        for both in [false, true] {
            for side in [ConflictSide.thisMachine, .otherMachine] {
                let fixture = try SyncConflictByteFixture.gitlinkConflict(both: both)
                defer { try? fixture.files.deleteDirectory(at: fixture.root) }
                let model = ConflictResolutionModel(engine: fixture.engine, git: fixture.git,
                    credentials: InMemoryCredentialStore(), root: fixture.storeB)
                await model.loadAndReport(context: fixture.contextB)
                guard case let .ready(groups) = model.phase else { return XCTFail("A gitlink must reach the sheet") }
                let group = try XCTUnwrap(groups.first)
                let item = try XCTUnwrap(group.items.first)
                let strings = await renderedComparison(item)
                XCTAssertTrue(strings.contains("Nested repository"))
                XCTAssertTrue(strings.contains(
                    "Either choice stops syncing this path and keeps its folder on this Mac and other Macs."))
                XCTAssertEqual(strings.filter { $0 == "Deleted" }.count, both ? 0 : 1)
                model.choose(group.id, side)
                XCTAssertNil(model.selectionError)
                XCTAssertTrue(model.canApply, "Either side must allow index-only retirement, including two gitlinks")
                await model.applyAndReport(context: fixture.contextB)
                XCTAssertEqual(model.phase, .done)
                XCTAssertTrue(fixture.files.directoryExists(at: fixture.storeB + "/" + fixture.path))
                let tree = try fixture.git.runData(["--git-dir", fixture.remote, "ls-tree", "main", "--", item.path], in: nil)
                XCTAssertTrue(tree.stdout.isEmpty)
            }
        }
    }

    private func renderedComparison(_ item: ConflictItem) async -> [String] {
        let host = NSHostingView(rootView: AnyView(ConflictFileComparison(item: item).frame(width: 520)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The comparison must render both side labels") {
            let strings = self.comparisonStrings(in: host)
            return strings.contains("This Mac") && strings.contains("Other Mac")
        }
        return comparisonStrings(in: host)
    }

    private func comparisonStrings(in host: NSHostingView<AnyView>) -> [String] {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap { RenderedViewTestSupport.strings(in: $0) }
    }
}
