import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

final class DesignTokensTests: XCTestCase {
    func testHeaderTypographyMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.detailTitleSize, 22)
        XCTAssertEqual(DesignTokens.detailTitleWeight, .bold)
        XCTAssertEqual(DesignTokens.provenanceSize, 12)
        XCTAssertEqual(DesignTokens.provenanceWeight, .regular)
        XCTAssertEqual(DesignTokens.provenanceMonoSize, 11)
        XCTAssertEqual(DesignTokens.provenanceMonoWeight, .regular)
        XCTAssertEqual(DesignTokens.provenanceMonoDesign, .monospaced)
        XCTAssertEqual(DesignTokens.provenanceDotSize, 10)
        XCTAssertEqual(DesignTokens.provenanceDotWeight, .regular)
    }

    func testHeaderRhythmMatchesTheFrames() {
        XCTAssertEqual(DesignTokens.provenanceLineHeight, 16)
        XCTAssertEqual(DesignTokens.headerBottomInset, 16)
    }

    func testTabTypographyMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.tabLabelSize, 13)
        XCTAssertEqual(DesignTokens.tabLabelWeight, .regular)
        XCTAssertEqual(DesignTokens.tabLabelActiveSize, 13)
        XCTAssertEqual(DesignTokens.tabLabelActiveWeight, .medium)
    }

    func testStatTypographyMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.statLabelSize, 12)
        XCTAssertEqual(DesignTokens.statLabelWeight, .regular)
        XCTAssertEqual(DesignTokens.statValueSize, 20)
        XCTAssertEqual(DesignTokens.statValueWeight, .semibold)
        XCTAssertEqual(DesignTokens.statSubSize, 10)
        XCTAssertEqual(DesignTokens.statSubWeight, .regular)
    }

    func testEmptyStateTokensMatchTheFrames() {
        XCTAssertEqual(DesignTokens.emptyStateTitleSize, 24)
        XCTAssertEqual(DesignTokens.emptyStateTitleWeight, .light)
        XCTAssertEqual(DesignTokens.emptyStateDescriptionSize, 13)
        XCTAssertEqual(DesignTokens.emptyStateDescriptionWeight, .regular)
        XCTAssertEqual(DesignTokens.emptyStateGap, 10)
        XCTAssertEqual(DesignTokens.emptyStateSidePadding, 16)
    }

    func testCardTokensMatchMeasuredValues() {
        XCTAssertEqual(DesignTokens.cardFillOpacity, 0.03)
        XCTAssertEqual(DesignTokens.cardCornerRadius, 10)
        XCTAssertEqual(DesignTokens.cardPadding, 10)
        XCTAssertEqual(DesignTokens.cardContentGap, 2)
    }

    func testOverviewTypographyAndColumnsMatchMeasuredTokens() {
        XCTAssertEqual(DesignTokens.sectionHeadingSize, 16)
        XCTAssertEqual(DesignTokens.sectionHeadingWeight, .semibold)
        XCTAssertEqual(DesignTokens.kvLabelSize, 12)
        XCTAssertEqual(DesignTokens.kvLabelWeight, .regular)
        XCTAssertEqual(DesignTokens.kvValueColumnStart, 108)
        XCTAssertEqual(DesignTokens.kvSeparatorOpacity, 0.05)
        XCTAssertEqual(DesignTokens.kvGlyphSize, 12)
        XCTAssertEqual(DesignTokens.kvGlyphWidth, 16)
    }

    func testContentsBarMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.barTrackOpacity, 0.03)
        XCTAssertEqual(DesignTokens.barHeight, 4)
        XCTAssertEqual(DesignTokens.barCornerRadius, 2)
        XCTAssertEqual(DesignTokens.barFillOpacity, 0.10)
    }

    func testBannerMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.bannerFillOpacity, 0.03)
        XCTAssertEqual(DesignTokens.bannerCornerRadius, 20)
        XCTAssertEqual(DesignTokens.bannerHeight, 40)
        XCTAssertEqual(DesignTokens.bannerPadding, 6)
        XCTAssertEqual(DesignTokens.bannerToStrip, 20)
        XCTAssertEqual(DesignTokens.bannerTitleSize, 13)
        XCTAssertEqual(DesignTokens.bannerTitleWeight, .semibold)
    }

    func testDeploymentGroupTypographyMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.groupTitleSize, 13)
        XCTAssertEqual(DesignTokens.groupTitleWeight, .semibold)
        XCTAssertEqual(DesignTokens.groupDescriptionSize, 13)
        XCTAssertEqual(DesignTokens.groupDescriptionWeight, .regular)
        XCTAssertEqual(DesignTokens.groupDescriptionOpacity, 0.60)
        XCTAssertEqual(DesignTokens.groupEmptySize, 13)
        XCTAssertEqual(DesignTokens.groupEmptyWeight, .regular)
        XCTAssertEqual(DesignTokens.groupEmptyOpacity, 0.35)
    }

    func testDeploymentGroupGeometryMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.groupFillOpacity, 0.03)
        XCTAssertEqual(DesignTokens.groupCornerRadius, 10)
        XCTAssertEqual(DesignTokens.groupTitleLineHeight, 20)
        XCTAssertEqual(DesignTokens.groupTitleToBoxTop, 27)
        XCTAssertEqual(DesignTokens.groupSectionSpacing, 32)
        XCTAssertEqual(DesignTokens.groupRowHeight, 40)
        XCTAssertEqual(DesignTokens.groupRowVerticalPadding, 12)
        XCTAssertEqual(DesignTokens.groupLeadingInset, 8)
        XCTAssertEqual(DesignTokens.groupTrailingInset, 10)
        XCTAssertEqual(DesignTokens.groupPlatformTileSize, 20)
        XCTAssertEqual(DesignTokens.groupPlatformNameStart, 40)
        XCTAssertEqual(DesignTokens.groupNestedInset, 32)
        XCTAssertEqual(DesignTokens.groupProjectChevronWidth, 12)
        XCTAssertEqual(DesignTokens.groupProjectFolderStart, 24)
        XCTAssertEqual(DesignTokens.groupProjectFolderWidth, 20)
        XCTAssertEqual(DesignTokens.groupProjectNameStart, 56)
        XCTAssertEqual(DesignTokens.groupProjectPathStart, 240)
        XCTAssertEqual(DesignTokens.groupSeparatorOpacity, 0.05)
        XCTAssertEqual(DesignTokens.groupSeparatorHeight, 1)
    }

    func testDeploymentFooterMatchesMeasuredTokens() {
        XCTAssertEqual(DesignTokens.footerFillOpacity, 0.03)
        XCTAssertEqual(DesignTokens.footerHeight, 24)
        XCTAssertEqual(DesignTokens.footerLabelSize, 10)
        XCTAssertEqual(DesignTokens.footerLabelWeight, .regular)
        XCTAssertEqual(DesignTokens.footerLabelOpacity, 0.35)
        XCTAssertEqual(DesignTokens.footerGlyphOpacity, 0.55)
        XCTAssertEqual(DesignTokens.footerGlyphSize, 10)
        XCTAssertEqual(DesignTokens.footerGlyphStroke, 2)
        XCTAssertEqual(DesignTokens.footerGlyphLeading, 7)
        XCTAssertEqual(DesignTokens.footerDividerLeading, 24)
        XCTAssertEqual(DesignTokens.footerDividerHeight, 14)
        XCTAssertEqual(DesignTokens.footerLabelLeading, 32)
    }

    func testTabContentAndHistoryRuleMatchMeasuredTokens() {
        XCTAssertEqual(DesignTokens.stripHairlineToContentTop, 20)
        XCTAssertEqual(DesignTokens.contentRowTop, 16)
        XCTAssertEqual(DesignTokens.historyContentTop, 20)
        XCTAssertEqual(DesignTokens.timelineRuleOpacity, 0.10)
    }

    func testDarkOpacitiesAreChosenFrom20260922FixtureBecauseNoDarkFrameExists() {
        XCTAssertEqual(DesignTokens.cardFillDarkOpacity, 0.08)
        XCTAssertEqual(DesignTokens.barTrackDarkOpacity, 0.08)
        XCTAssertEqual(DesignTokens.barFillDarkOpacity, 0.20)
        XCTAssertEqual(DesignTokens.bannerFillDarkOpacity, 0.08)
        XCTAssertEqual(DesignTokens.groupFillDarkOpacity, 0.08)
        XCTAssertEqual(DesignTokens.groupDescriptionDarkOpacity, 0.60)
        XCTAssertEqual(DesignTokens.groupEmptyDarkOpacity, 0.40)
        XCTAssertEqual(DesignTokens.groupSeparatorDarkOpacity, 0.12)
        XCTAssertEqual(DesignTokens.kvSeparatorDarkOpacity, 0.12)
        XCTAssertEqual(DesignTokens.footerFillDarkOpacity, 0.08)
        XCTAssertEqual(DesignTokens.footerLabelDarkOpacity, 0.40)
        XCTAssertEqual(DesignTokens.footerGlyphDarkOpacity, 0.55)
        XCTAssertEqual(DesignTokens.timelineRuleDarkOpacity, 0.20)
        assertDynamicColor(DesignTokens.timelineRule, lightAlpha: 0.10, darkAlpha: 0.20)
        assertDynamicColor(DesignTokens.kvSeparator, lightAlpha: 0.05, darkAlpha: 0.12)
    }

    func testCardFillResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.cardFill, lightAlpha: 0.03, darkAlpha: 0.08)
    }

    func testBannerFillResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.bannerFill, lightAlpha: 0.03, darkAlpha: 0.08)
    }

    func testGroupFillResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.groupFill, lightAlpha: 0.03, darkAlpha: 0.08)
    }

    func testBarTrackResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.barTrack, lightAlpha: 0.03, darkAlpha: 0.08)
    }

    func testGroupSeparatorResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.groupSeparator, lightAlpha: 0.05, darkAlpha: 0.12)
    }

    func testFooterFillResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.footerFill, lightAlpha: 0.03, darkAlpha: 0.08)
    }

    func testBarFillResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.barFill, lightAlpha: 0.10, darkAlpha: 0.20)
    }

    func testGroupDescriptionResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.groupDescriptionColor, lightAlpha: 0.60, darkAlpha: 0.60)
    }

    func testGroupEmptyResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.groupEmptyColor, lightAlpha: 0.35, darkAlpha: 0.40)
    }

    func testFooterLabelResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.footerLabelColor, lightAlpha: 0.35, darkAlpha: 0.40)
    }

    func testFooterGlyphResolvesMeasuredLightAndChosenDarkFixtureEffectiveAlpha() {
        assertDynamicColor(DesignTokens.footerGlyph, lightAlpha: 0.55, darkAlpha: 0.55)
    }

    private func assertDynamicColor(
        _ color: Color,
        lightAlpha: CGFloat,
        darkAlpha: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertColor(
            color,
            appearance: .aqua,
            effectiveAlpha: lightAlpha,
            file: file,
            line: line
        )
        assertColor(
            color,
            appearance: .darkAqua,
            effectiveAlpha: darkAlpha,
            file: file,
            line: line
        )
    }

    private func assertColor(
        _ color: Color,
        appearance: NSAppearance.Name,
        effectiveAlpha: CGFloat,
        file: StaticString,
        line: UInt
    ) {
        guard let appearance = NSAppearance(named: appearance) else {
            return XCTFail("Could not resolve dynamic color", file: file, line: line)
        }
        var resolved: NSColor?
        var labelColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(NSColorSpace.deviceRGB)
            labelColor = NSColor.labelColor.usingColorSpace(NSColorSpace.deviceRGB)
        }
        guard let resolved, let labelColor else {
            return XCTFail("Could not resolve dynamic color", file: file, line: line)
        }
        XCTAssertEqual(resolved.redComponent, labelColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, labelColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, labelColor.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(resolved.alphaComponent, effectiveAlpha, accuracy: 0.001, file: file, line: line)
    }
}
