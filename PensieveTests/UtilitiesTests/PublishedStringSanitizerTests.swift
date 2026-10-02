import XCTest
@testable import Pensieve

final class PublishedStringSanitizerTests: XCTestCase {
    func testControlsAndBidirectionalControlsAreRemovedAndCapsCountCharacters() {
        let hostile = "A\n\u{001B}\0\u{202E}\u{2066}B" + String(repeating: "é", count: 100)
        let name = PublishedStringSanitizer.name(hostile, fallback: "Mac")
        let path = PublishedStringSanitizer.path(String(repeating: "🧑🏽‍💻", count: 300))

        XCTAssertEqual(name.prefix(2), "AB")
        XCTAssertEqual(name.count, 80)
        XCTAssertTrue(name.hasSuffix("…"))
        XCTAssertFalse(name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertEqual(path.count, 256)
        XCTAssertTrue(path.hasSuffix("…"))
    }

    func testEmptyNamesUseSanitizedFallbacks() {
        XCTAssertEqual(PublishedStringSanitizer.name("\n\u{202E}", fallback: "Mac"), "Mac")
        XCTAssertEqual(
            PublishedStringSanitizer.projectName("\0", identityKey: "github.com/example/pro\u{202E}ject"),
            "project"
        )
        XCTAssertEqual(PublishedStringSanitizer.projectName("\0", identityKey: ""), "Project")
    }

    func testJoinersAndTagCharactersSurviveWhileRightToLeftMarkIsRemoved() {
        let values = [
            "Jared's 👨‍👩‍👧 Mac",
            "می\u{200C}خواهم",
            "🏴󠁧󠁢󠁳󠁣󠁴󠁿"
        ]

        for value in values {
            XCTAssertEqual(PublishedStringSanitizer.name(value, fallback: "Mac"), value)
            let scalars = Array(value.unicodeScalars)
            let midpoint = scalars.count / 2
            let hostile = String(String.UnicodeScalarView(
                Array(scalars[..<midpoint]) + [UnicodeScalar(0x200F)!] + Array(scalars[midpoint...])
            ))
            XCTAssertEqual(PublishedStringSanitizer.name(hostile, fallback: "Mac"), value)
        }
    }

    func testInvisibleOnlyNamesAndFallbackComponentsUseFallbacks() {
        let tag = String(UnicodeScalar(0xE0061)!)
        let invisibleValues = [
            "\u{200D}\u{200C}", String(repeating: tag, count: 4),
            " \t\u{00A0} ", String(repeating: " ", count: 100),
            "\u{FE0F}\u{FE0F}", "\u{3164}", "\u{115F}", "\u{034F}", "\u{2800}", "\u{0301}",
            String(UnicodeScalar(0xFFFF)!), String(UnicodeScalar(0x10FFFF)!), String(UnicodeScalar(0xFDD0)!)
        ]

        for value in invisibleValues {
            XCTAssertEqual(PublishedStringSanitizer.name(value, fallback: "Mac"), "Mac")
        }
        XCTAssertEqual(
            PublishedStringSanitizer.projectName("\u{3164}", identityKey: "github.com/example/fallback"),
            "fallback"
        )
        XCTAssertEqual(
            PublishedStringSanitizer.projectName("", identityKey: "github.com/example/\u{3164}"),
            "Project"
        )
        XCTAssertEqual(PublishedStringSanitizer.name("\u{1D159}", fallback: "Mac"), "\u{1D159}")
    }

    func testOversizedClustersAndTagsOutsideSubdivisionFlagsAreDropped() {
        let tagA = String(UnicodeScalar(0xE0061)!)
        let tagB = String(UnicodeScalar(0xE0062)!)
        XCTAssertEqual(
            PublishedStringSanitizer.name("Studio" + String(repeating: tagA, count: 20_000), fallback: "Mac"),
            "Studio"
        )
        XCTAssertEqual(
            PublishedStringSanitizer.name("a" + String(repeating: "\u{0301}", count: 10_000), fallback: "Mac"),
            "Mac"
        )
        XCTAssertEqual(
            PublishedStringSanitizer.name("A" + tagA + tagB, fallback: "Mac"),
            "A"
        )
    }

    func testFilteringRepeatsUntilRemovedClustersCannotMergePastTheScalarCap() {
        let oversized = "a" + String(repeating: "\u{0301}", count: 16)
        let joinedEmoji = String(repeating: "👨\u{200D}" + oversized, count: 5_000) + "👨"
        let jamoRun = String(repeating: "\u{1100}", count: 16)
        let mergedJamo = String(repeating: jamoRun + oversized, count: 1_000)

        for value in [joinedEmoji, mergedJamo] {
            let result = PublishedStringSanitizer.name(value, fallback: "Mac")
            XCTAssertLessThanOrEqual(result.count, PublishedStringSanitizer.nameLimit)
            XCTAssertTrue(result.allSatisfy { $0.unicodeScalars.count <= 16 })
        }
    }

    func testTagCharactersRequireBlackFlagAsTheCharactersFirstScalarAndEdgesAreTrimmed() {
        let tags = String(repeating: String(UnicodeScalar(0xE0061)!), count: 13)

        XCTAssertEqual(
            PublishedStringSanitizer.name("😀\u{200D}🏴" + tags, fallback: "Mac"),
            "😀\u{200D}🏴"
        )
        XCTAssertEqual(
            PublishedStringSanitizer.name(String(repeating: " ", count: 80) + "Studio", fallback: "Mac"),
            "Studio"
        )
    }

    func testGeneratedInputsReachABoundedIdempotentFixedPoint() {
        let alphabet = [
            0x200D, 0x200C, 0xE0061, 0xE007F, 0x1F3F4, 0x1F468,
            0x61, 0x0301, 0x1100, 0xFE0F, 0x3164, 0x20
        ].compactMap(UnicodeScalar.init)
        var generator = SanitizerGenerator(seed: 0x36_5_C3)
        var adjacentPairs: Set<[UInt32]> = []

        for iteration in 0..<400 {
            let scalars: [UnicodeScalar]
            if iteration == 0 {
                scalars = mergeHeavyScalars(using: &generator)
            } else {
                let count = generator.nextInt(upperBound: 500)
                scalars = (0..<count).map { _ in alphabet[generator.nextInt(upperBound: alphabet.count)] }
                for (first, second) in zip(scalars, scalars.dropFirst()) {
                    adjacentPairs.insert([first.value, second.value])
                }
            }
            let input = String(String.UnicodeScalarView(scalars))
            let name = PublishedStringSanitizer.name(input, fallback: "Mac")
            let path = PublishedStringSanitizer.path(input)

            XCTAssertLessThanOrEqual(name.count, PublishedStringSanitizer.nameLimit)
            XCTAssertLessThanOrEqual(path.count, PublishedStringSanitizer.pathLimit)
            XCTAssertTrue(name.allSatisfy { $0.unicodeScalars.count <= 16 })
            XCTAssertTrue(path.allSatisfy { $0.unicodeScalars.count <= 16 })
            XCTAssertEqual(PublishedStringSanitizer.name(name, fallback: "Mac"), name)
            XCTAssertEqual(PublishedStringSanitizer.path(path), path)
        }
        XCTAssertTrue(adjacentPairs.contains([0x1100, 0x1100]))
        XCTAssertTrue(adjacentPairs.contains([0x0301, 0x0301]))
        XCTAssertTrue(adjacentPairs.contains([0x1F468, 0x200D]))
    }

    func testNestedInputInsideRawLimitReachesTheLoopWithinTheCostBound() {
        let rawScalarLimit = PublishedStringSanitizer.pathScalarLimit
        let nested = nestedInput(levels: 230)

        XCTAssertGreaterThan(nested.value.unicodeScalars.count, 4_000)
        XCTAssertLessThanOrEqual(nested.value.unicodeScalars.count, rawScalarLimit)
        XCTAssertLessThan(nested.centerStart, rawScalarLimit)
        XCTAssertLessThanOrEqual(nested.centerEnd, rawScalarLimit)

        let name = PublishedStringSanitizer.name(nested.value, fallback: "Mac")
        XCTAssertEqual(name, "Mac")
        assertSanitized(name, limit: PublishedStringSanitizer.nameLimit)
        XCTAssertEqual(PublishedStringSanitizer.name(name, fallback: "Mac"), name)

        let clock = ContinuousClock()
        var path = ""
        let elapsed = clock.measure {
            for _ in 0..<20 {
                path = PublishedStringSanitizer.path(nested.value)
            }
        }
        XCTAssertLessThan(elapsed, .seconds(6))
        XCTAssertEqual(path, "")
        assertSanitized(path, limit: PublishedStringSanitizer.pathLimit)
        XCTAssertEqual(PublishedStringSanitizer.path(path), path)
    }

    func testRawScalarLimitCountsContentRemovedLater() {
        let spaces = String(repeating: " ", count: PublishedStringSanitizer.nameScalarLimit) + "Studio"
        let zeroWidthSpaces = String(
            repeating: "\u{200B}",
            count: PublishedStringSanitizer.pathScalarLimit
        ) + "Studio"

        XCTAssertEqual(PublishedStringSanitizer.name(spaces, fallback: "Mac"), "Mac")
        XCTAssertEqual(PublishedStringSanitizer.name(zeroWidthSpaces, fallback: "Mac"), "Mac")
        XCTAssertEqual(PublishedStringSanitizer.path(spaces), "")
        XCTAssertEqual(PublishedStringSanitizer.path(zeroWidthSpaces), "")
    }

    func testRawScalarCutBoundsLargeNestedPathCost() {
        let nested = nestedInput(levels: 480)
        XCTAssertEqual(nested.value.unicodeScalars.count, 8_417)
        XCTAssertLessThan(nested.centerStart, PublishedStringSanitizer.pathScalarLimit)
        XCTAssertGreaterThan(nested.centerEnd, PublishedStringSanitizer.pathScalarLimit)

        let clock = ContinuousClock()
        var path = ""
        let elapsed = clock.measure {
            for _ in 0..<20 {
                path = PublishedStringSanitizer.path(nested.value)
            }
        }
        XCTAssertLessThan(elapsed, .seconds(2))
        assertSanitized(path, limit: PublishedStringSanitizer.pathLimit)
    }

    private func assertSanitized(_ value: String, limit: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(value.count, limit, file: file, line: line)
        XCTAssertTrue(value.allSatisfy { $0.unicodeScalars.count <= 16 }, file: file, line: line)
    }
}

private func mergeHeavyScalars(using generator: inout SanitizerGenerator) -> [UnicodeScalar] {
    let jamo = UnicodeScalar(0x1100)!
    let base = UnicodeScalar(0x61)!
    let combiningMark = UnicodeScalar(0x0301)!
    let runs = 2 + generator.nextInt(upperBound: 40)
    var scalars: [UnicodeScalar] = []
    scalars.reserveCapacity(runs * 33)
    for _ in 0..<runs {
        scalars.append(contentsOf: repeatElement(jamo, count: 16))
        scalars.append(base)
        scalars.append(contentsOf: repeatElement(combiningMark, count: 16))
    }
    return scalars
}

private struct NestedSanitizerInput {
    let value: String
    let centerStart: Int
    let centerEnd: Int
}

private func nestedInput(levels: Int) -> NestedSanitizerInput {
    let oversized = "a" + String(repeating: "\u{0301}", count: 16)
    let jamo = String(repeating: "\u{1100}", count: 9)
    let emojiLeft = String(repeating: "👨\u{200D}", count: 4)
    let emojiRight = "👨" + String(repeating: "\u{200D}👨", count: 4)
    var left: [String] = []
    var right: [String] = []
    left.reserveCapacity(levels)
    right.reserveCapacity(levels)
    for level in 0..<levels {
        if level.isMultiple(of: 2) {
            left.append(jamo)
            right.append(jamo)
        } else {
            left.append(emojiLeft)
            right.append(emojiRight)
        }
    }
    let leftValue = left.joined()
    let centerStart = leftValue.unicodeScalars.count
    return NestedSanitizerInput(
        value: leftValue + oversized + right.reversed().joined(),
        centerStart: centerStart,
        centerEnd: centerStart + oversized.unicodeScalars.count
    )
}

private struct SanitizerGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return Int(mixed % UInt64(upperBound))
    }
}
