import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
struct HistoryLifetimeFixture {
    let model: UpstreamHistoryViewModel
    let skill: Skill
    let disk: UpstreamHistoryCache
    let gate: HistoryLifetimeGate
    let calls: HistorySequenceCalls
    let kind: UpstreamHistorySequenceHooks.Work
    let fails: Bool
    let kept: UpstreamHistoryResult
    let fresh: UpstreamHistoryResult

    func makeWindow(host: HistoryLifetimeHostState) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryLifetimeHost(skill: skill, history: model, host: host))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func assertOutcome(file: StaticString = #filePath, line: UInt = #line) throws {
        let expected: UpstreamHistoryResult? = kind == .localEdits ? kept.replacing(localEdits: .countsUnknown)
            : fails ? (kind == .probe ? kept : nil) : fresh
        XCTAssertEqual(model.held.values.first?.result, expected, "\(kind), fails=\(fails)", file: file, line: line)
        if fails {
            switch model.state {
            case let .failed(message): XCTAssertEqual(kind, .read, file: file, line: line)
                XCTAssertTrue(message.contains("lifetime offline"), file: file, line: line)
            case let .loadedWithFailure(result, message):
                XCTAssertEqual(result, kept, file: file, line: line)
                XCTAssertTrue(message.contains("lifetime offline"), file: file, line: line)
            default: XCTFail("The failed work lost its outcome", file: file, line: line)
            }
        } else if let expected {
            XCTAssertEqual(model.state, .loaded(expected), file: file, line: line)
        }
        let origin = try XCTUnwrap(skill.installedOrigin)
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)
        let persisted = disk.load(skillID: skill.id, origin: origin, minimumWindow: 1, generation: generation)
        XCTAssertEqual(persisted?.result, kind == .localEdits ? kept : expected, file: file, line: line)
    }

    func assertCalls(reopenedAfterFailure: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let readCount = kind == .localEdits || (kind == .probe && fails) ? 0 : reopenedAfterFailure ? 2 : 1
        XCTAssertEqual(calls.values.filter { $0 == "read" }.count, readCount, file: file, line: line)
        XCTAssertEqual(calls.values.filter { $0 == "probe" }.count, kind == .probe ? 1 : 0, file: file, line: line)
        XCTAssertEqual(calls.values.filter { $0 == "edits" }.count, kind == .localEdits ? 1 : 0, file: file, line: line)
    }
}
