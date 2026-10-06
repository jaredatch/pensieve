import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillHistoryLayoutTests: XCTestCase {
    func testInstalledRowsKeep24PointGapsAtShortAndTallHeights() async throws {
        let tab = try installedTab(rowCount: 3)
        try await assertFixedGaps(tab, rowCount: 3, tails: [
            AnyView(Text("1 file changed · +2 −1").font(.caption)),
            AnyView(Text("1 file changed · +2 −1").font(.caption))
        ])
    }

    func testAuthoredRowsKeep24PointGapsAtShortAndTallHeights() async throws {
        let base = TestTemporaryDirectory.path + "SkillHistoryLayoutTests-\(UUID().uuidString)"
        let store = SkillStore(fileService: FileService(), baseDir: base)
        let git = SkillHistoryRecordingGit()
        git.commits = (0..<4).map { index in
            GitCommit(sha: "sha-\(index)", author: "Author", date: Date(), subject: subject(index))
        }
        let tab = SkillHistoryTab(
            skill: Skill(name: "Example", directoryName: "example"),
            currentBody: "# Current",
            library: SkillLibraryViewModel(skillStore: store),
            upstreamHistory: historyOwner(read: { _, _, _ in historyResult() }),
            localRevision: .initial,
            onOpenUpdates: {},
            onUpdateCheck: { _ in },
            git: git,
            store: store,
            workingDir: base
        )
        try await assertFixedGaps(AnyView(tab), rowCount: 4, tails: [
            AnyView(Text(subject(0)).font(.body)),
            AnyView(Button("View Diff", action: {}).controlSize(.large))
        ])
    }

    private func installedTab(rowCount: Int) throws -> AnyView {
        let skill = installedHistorySkill()
        let origin = try XCTUnwrap(skill.installedOrigin)
        let result = historyTimelineResult(rowCount: rowCount)
        let history = historyOwner(read: { _, _, _ in result })
        let tab = InstalledSkillHistoryView(
            skill: skill,
            currentBody: "# Current",
            origin: origin,
            updateAvailable: false,
            localRevision: .initial,
            onOpenUpdates: {},
            onUpdateCheck: { _ in },
            history: history
        )
        return AnyView(tab)
    }

    private func assertFixedGaps(
        _ tab: AnyView,
        rowCount: Int,
        tails: [AnyView],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        // Rasterized glyphs end before their Text's layout frame. Measure that inset with
        // independent, naturally sized footer hosts; no timeline spacing enters this calibration.
        let bottomInsets = try tails.map(bottomInkInset)
        var measured: [HistoryPixels.Positions] = []
        for height: CGFloat in [480, 1000] {
            let host = makeHost(tab, height: height)
            defer { host.window.close() }
            let positions = try await waitForRows(in: host.view, rowCount: rowCount)
            measured.append(positions)
            for index in 0..<2 {
                let contentBottom = positions.inkBottoms[index] + bottomInsets[index]
                let rowHeight = contentBottom - positions.rowTops[index]
                let pitch = positions.rowTops[index + 1] - positions.rowTops[index]
                XCTAssertEqual(pitch, rowHeight + 24, accuracy: 1,
                               "row \(index) pitch must equal content height + 24 at height \(height)",
                               file: file, line: line)
            }
        }
        for index in 0..<2 {
            let shortPitch = measured[0].rowTops[index + 1] - measured[0].rowTops[index]
            let tallPitch = measured[1].rowTops[index + 1] - measured[1].rowTops[index]
            XCTAssertEqual(shortPitch, tallPitch, accuracy: 1,
                           "row \(index) pitch must survive resizing", file: file, line: line)
        }
    }

    private func bottomInkInset(_ tail: AnyView) throws -> CGFloat {
        let view = NSHostingView(rootView: tail.background(Color(nsColor: .windowBackgroundColor)))
        let size = view.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let pixels = try XCTUnwrap(HistoryPixels.capture(in: view))
        let inkBottom = try XCTUnwrap(pixels.inkBottom(from: 0, to: size.height, left: 0))
        return size.height - inkBottom
    }

    private func makeHost(_ tab: AnyView, height: CGFloat) -> (view: NSView, window: NSWindow) {
        let layout = SkillDetailScrollLayout(skillID: UUID(), contentOwnsScroller: false) {
            EmptyView()
        } tabContent: {
            tab
        }
        let view = NSHostingView(rootView: AnyView(layout.frame(width: 640, height: height)
            .background(Color(nsColor: .windowBackgroundColor))))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.title = "History layout " + UUID().uuidString
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func waitForRows(in view: NSView, rowCount: Int) async throws -> HistoryPixels.Positions {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var previous: HistoryPixels.Positions?
        var last: HistoryPixels?
        repeat {
            view.layoutSubtreeIfNeeded()
            last = HistoryPixels.capture(in: view)
            let positions = last?.positions
            if let positions, positions.rowTops.count == rowCount,
               positions.inkBottoms.count == rowCount - 1, positions == previous { return positions }
            previous = positions
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        if let image = last?.bitmap.cgImage {
            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: view.bounds.size))
            attachment.name = "History render at \(view.bounds.height) points"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTFail("History markers did not load within 3 s: \(last?.positions.rowTops ?? [])")
        throw LayoutFailure.rowsUnavailable
    }

    private enum LayoutFailure: Error { case rowsUnavailable }

    private func subject(_ index: Int) -> String {
        index == 1 ? "Version 11\nA second subject line" : "Version \(12 - index)"
    }
}

/// Reads rendered marker and content pixels in bitmap coordinates (Y increases downward).
@MainActor
private struct HistoryPixels {
    struct Positions: Equatable {
        let rowTops: [CGFloat]
        let inkBottoms: [CGFloat]
    }

    let bitmap: NSBitmapImageRep
    let scaleX: CGFloat
    let scaleY: CGFloat
    let bytes: [UInt8]
    let backgroundOffset: Int

    static func capture(in view: NSView) -> HistoryPixels? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                             count: image.width * image.height * 4))
        let corners = [0, (image.width - 1) * 4,
                       (image.height - 1) * image.width * 4, bytes.count - 4]
        guard let background = corners.first(where: { bytes[$0 + 3] == 255 }) else { return nil }
        return HistoryPixels(bitmap: bitmap, scaleX: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                             scaleY: CGFloat(bitmap.pixelsHigh) / view.bounds.height,
                             bytes: bytes, backgroundOffset: background)
    }

    var positions: Positions {
        // Three points off center intersects the ten-point dots, avoiding the one-point connector.
        let x = Int((Spacing.lg + 6 + 3) * scaleX)
        var runs: [ClosedRange<Int>] = []
        for y in 0..<bitmap.pixelsHigh where isInk(x: x, y: y) {
            if let last = runs.last, last.upperBound == y - 1 {
                runs[runs.count - 1] = last.lowerBound...y
            } else {
                runs.append(y...y)
            }
        }
        let tops = runs.filter { (6...10).contains(CGFloat($0.count) / scaleY) }.map {
            // The marker's center is four points of top connector plus its five-point radius.
            CGFloat($0.lowerBound + $0.upperBound + 1) / (2 * scaleY) - 9
        }
        let bottoms = zip(tops, tops.dropFirst()).compactMap { top, next in
            inkBottom(from: top, to: next, left: Spacing.lg + 12 + Spacing.lg)
        }
        return Positions(rowTops: tops, inkBottoms: bottoms)
    }

    func inkBottom(from top: CGFloat, to bottom: CGFloat, left: CGFloat) -> CGFloat? {
        let firstX = Int(left * scaleX)
        for y in stride(from: min(Int(bottom * scaleY), bitmap.pixelsHigh) - 1,
                        through: max(Int(top * scaleY), 0), by: -1) {
            for x in firstX..<bitmap.pixelsWide where isInk(x: x, y: y) {
                return CGFloat(y + 1) / scaleY
            }
        }
        return nil
    }

    private func isInk(x: Int, y: Int) -> Bool {
        let offset = (y * bitmap.pixelsWide + x) * 4
        guard bytes[offset + 3] > 127 else { return false }
        // The opaque host's margin is the background reference for both light and dark pixels.
        return max(abs(Int(bytes[offset]) - Int(bytes[backgroundOffset])),
                   abs(Int(bytes[offset + 1]) - Int(bytes[backgroundOffset + 1])),
                   abs(Int(bytes[offset + 2]) - Int(bytes[backgroundOffset + 2]))) > 7
    }
}
