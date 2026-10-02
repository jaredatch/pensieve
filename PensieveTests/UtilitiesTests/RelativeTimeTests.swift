import XCTest
@testable import Pensieve

final class RelativeTimeTests: XCTestCase {
    func testUnderAMinuteIsJustNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(RelativeTime.string(for: now, relativeTo: now), "Just now")
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(-30), relativeTo: now), "Just now")
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(5), relativeTo: now), "Just now")
    }

    func testOverAMinuteUsesFormatter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = now.addingTimeInterval(-120)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        XCTAssertEqual(
            RelativeTime.string(for: date, relativeTo: now),
            formatter.localizedString(for: date, relativeTo: now)
        )
    }

    func testCompactThirtySecondsIsJustNow() {
        XCTAssertEqual(compact(secondsAgo: 30), "Just now")
    }

    func testCompactTwelveMinutesUsesMinutes() {
        XCTAssertEqual(compact(secondsAgo: 12 * 60), "12m ago")
    }

    func testCompactFiftyNineMinutesFiftyNineSecondsFloorsToMinutes() {
        XCTAssertEqual(compact(secondsAgo: 59 * 60 + 59), "59m ago")
    }

    func testCompactSixtyMinutesUsesHours() {
        XCTAssertEqual(compact(secondsAgo: 60 * 60), "1h ago")
    }

    func testCompactTwentyThreeHoursFiftyNineMinutesFloorsToHours() {
        XCTAssertEqual(compact(secondsAgo: 23 * 60 * 60 + 59 * 60), "23h ago")
    }

    func testCompactTwentyFourHoursUsesDays() {
        XCTAssertEqual(compact(secondsAgo: 24 * 60 * 60), "1d ago")
    }

    func testCompactSixDaysTwentyThreeHoursFloorsToDays() {
        XCTAssertEqual(compact(secondsAgo: 6 * 24 * 60 * 60 + 23 * 60 * 60), "6d ago")
    }

    func testCompactSevenDaysUsesWeeks() {
        XCTAssertEqual(compact(secondsAgo: 7 * 24 * 60 * 60), "1w ago")
    }

    func testCompactFiftyFiveDaysFloorsToSevenWeeks() {
        XCTAssertEqual(compact(secondsAgo: 55 * 24 * 60 * 60), "7w ago")
    }

    func testCompactFiftySixDaysUsesShortDate() {
        let date = now.addingTimeInterval(-56 * 24 * 60 * 60)
        let expected = date.formatted(.dateTime.month(.abbreviated).day())

        XCTAssertEqual(RelativeTime.compact(for: date, relativeTo: now), expected)
    }

    func testCompactFutureDateIsJustNow() {
        XCTAssertEqual(compact(secondsAgo: -5 * 60), "Just now")
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func compact(secondsAgo: TimeInterval) -> String {
        RelativeTime.compact(for: now.addingTimeInterval(-secondsAgo), relativeTo: now)
    }
}
