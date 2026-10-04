import Darwin
import XCTest
@testable import Pensieve

extension FileTreeComparisonTests {
    func testFileCountStopsAtThousandWithExactUnreadCount() throws {
        for index in 0..<1_003 {
            try files.writeFile(at: new + String(format: "/file%04d", index), content: "line\n")
        }
        let preview = try compare()
        XCTAssertEqual(preview.changes.count, 1_000)
        XCTAssertEqual(preview.unreadFileCount, 3)
        XCTAssertEqual(preview.bytesRead, 5_000)
        XCTAssertTrue(preview.isIncomplete)
    }

    func testThirtyTwoMiBBudgetCountsBothSidesAndStopsBeforeUnreadFile() throws {
        let data = Data(repeating: 65, count: 1_024 * 1_024)
        for index in 0..<17 {
            for side in [old, new] {
                try files.writeData(at: side + String(format: "/file%02d", index), data: data)
            }
        }
        let preview = try compare()
        XCTAssertEqual(preview.bytesRead, 32 * 1_024 * 1_024)
        XCTAssertEqual(preview.unreadFileCount, 1)
        XCTAssertTrue(preview.isIncomplete)
        XCTAssertTrue(preview.changes.isEmpty)
    }

    func testOversizedEqualityStopsMidFileAtAggregateBound() throws {
        let data = Data(repeating: 65, count: 20 * 1_024 * 1_024)
        for side in [old, new] { try files.writeData(at: side + "/big", data: data) }
        let preview = try compare()
        XCTAssertEqual(preview.bytesRead, 32 * 1_024 * 1_024)
        XCTAssertEqual(preview.unreadFileCount, 1)
        XCTAssertTrue(preview.changes.isEmpty, "an unfinished comparison cannot claim a change")
    }

    func testBudgetReturnsAlreadyReadChangesAndCountsPartlyReadPairAsUnread() throws {
        try files.writeFile(at: new + "/a", content: "ok")
        for side in [old, new] { try files.writeFile(at: side + "/b", content: "four") }
        try files.writeFile(at: new + "/c", content: "later")
        let preview = try compare(limits: FileTreeComparisonLimits(maximumFileBytes: 10, maximumFiles: 10, maximumTotalBytes: 7))
        XCTAssertEqual(preview.changes.map(\.path), ["a"])
        XCTAssertEqual(preview.bytesRead, 7)
        XCTAssertEqual(preview.unreadFileCount, 2)
    }

    func testGrowthAfterOpeningIsTooLargeAndRetentionStaysBounded() throws {
        let path = new + "/grow"
        let cap = FileTreeComparisonLimits.updatePreview.maximumFileBytes
        try files.writeData(at: path, data: Data(repeating: 65, count: cap))
        var grew = false
        var retained = 0
        let preview = try compare { event in
            if case let .opened(opened) = event, opened == path {
                let writer = open(path, O_WRONLY)
                defer { close(writer) }
                XCTAssertGreaterThanOrEqual(writer, 0)
                XCTAssertEqual(ftruncate(writer, off_t(cap + 100)), 0)
                grew = true
            }
            if case let .read(_, _, count) = event { retained = max(retained, count) }
        }
        XCTAssertTrue(grew)
        XCTAssertEqual(files.regularFileMetadata(at: path)?.byteCount, cap + 100)
        XCTAssertEqual(preview.changes.first?.content, .tooLarge)
        XCTAssertLessThanOrEqual(retained, cap + 1)
        XCTAssertLessThanOrEqual(preview.bytesRead, cap + 1)
    }

    func testOversizedMutationDuringComparisonIsTooLarge() throws {
        for changeSize in [false, true] {
            let data = Data(repeating: 65, count: 2 * 1_024 * 1_024)
            for side in [old, new] { try files.writeData(at: side + "/big", data: data) }
            var mutated = false
            let path = old + "/big"
            let preview = try compare { event in
                if case let .read(readPath, _, _) = event, readPath == path, !mutated {
                    let writer = open(path, O_WRONLY)
                    defer { close(writer) }
                    XCTAssertGreaterThanOrEqual(writer, 0)
                    if changeSize { XCTAssertEqual(ftruncate(writer, off_t(data.count + 1)), 0) } else {
                        var byte: UInt8 = 66
                        XCTAssertEqual(pwrite(writer, &byte, 1, 0), 1)
                    }
                    mutated = true
                }
            }
            XCTAssertTrue(mutated)
            XCTAssertEqual(preview.changes.first?.content, .tooLarge)
        }
    }
}
