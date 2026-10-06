import SwiftUI

/// Measured values from the Skills detail frames and rendered Markdown reference. Keep surfaces on these role tokens
/// instead of mapping Sketch style names back to SwiftUI's fixed text styles.
enum DesignTokens {
    // MARK: - Rendered Markdown

    /// Primer Markdown CSS at a 13 pt body (#111). Pixel lengths scale by 13/16; lengths within
    /// 1 pt of the 4 pt grid snap to it. Em lengths retain their ratios; hairlines never snap to zero.
    static let markdownBodySize: CGFloat = 13
    static let markdownBodyLineHeight: CGFloat = 1.5
    static let markdownHeading1Scale: CGFloat = 2
    static let markdownHeading2Scale: CGFloat = 1.5
    static let markdownHeading3Scale: CGFloat = 1.25
    static let markdownHeading4Scale: CGFloat = 1
    static let markdownHeading5Scale: CGFloat = 0.875
    static let markdownHeading6Scale: CGFloat = 0.85
    static let markdownHeadingLineHeight: CGFloat = 1.25
    static let markdownHeadingTop: CGFloat = Spacing.xl // 24 px → 19.5 → 20 pt
    static let markdownBlockGap: CGFloat = Spacing.md // 16 px → 13 → 12 pt
    static let markdownHeadingRulePadding: CGFloat = 0.3 // em of the heading's font
    static let markdownRuleThickness: CGFloat = 13.0 / 16 // 1 px
    static let markdownListIndent: CGFloat = markdownBodySize * 2 // 2em
    static let markdownListItemGap: CGFloat = markdownBodySize * 0.25 // .25em
    static let markdownCodeScale: CGFloat = 0.85
    static let markdownCodePadding: CGFloat = Spacing.md // 16 px → 13 → 12 pt
    static let markdownCodeRadius: CGFloat = CornerRadius.sm // 6 px → 4.875 → 4 pt
    static let markdownCodeLineHeight: CGFloat = 1.45
    static let markdownQuoteRule: CGFloat = markdownBodySize * 0.25 // .25em
    static let markdownQuoteInset: CGFloat = markdownBodySize // 1em
    static let markdownTableCellVertical: CGFloat = Spacing.xs // 6 px → 4.875 → 4 pt
    static let markdownTableCellHorizontal: CGFloat = markdownBodySize * 0.8125 // .8125em; outside grid tolerance
    static let markdownThematicBreakMargin: CGFloat = Spacing.xl // 24 px → 19.5 → 20 pt
    static let markdownCodeFill = Color(nsColor: .quaternaryLabelColor)
    static let markdownSeparator = Color(nsColor: .separatorColor)

    // MARK: - Detail header and tabs

    /// Measured from `Detail header / v2` on 2026-09-22.
    static let detailTitleSize: CGFloat = 22
    static let detailTitleWeight: Font.Weight = .bold
    static let detailTitle = Font.system(size: detailTitleSize, weight: detailTitleWeight)

    /// Measured from `Detail header / v2` on 2026-09-22.
    static let provenanceSize: CGFloat = 12
    static let provenanceWeight: Font.Weight = .regular
    static let provenance = Font.system(size: provenanceSize, weight: provenanceWeight)

    /// Measured from `Detail header / v2` on 2026-09-22.
    static let provenanceMonoSize: CGFloat = 11
    static let provenanceMonoWeight: Font.Weight = .regular
    static let provenanceMonoDesign: Font.Design = .monospaced
    static let provenanceMono = Font.system(
        size: provenanceMonoSize,
        weight: provenanceMonoWeight,
        design: provenanceMonoDesign
    )

    /// Measured from `Detail header / v2` on 2026-09-22.
    static let provenanceDotSize: CGFloat = 10
    static let provenanceDotWeight: Font.Weight = .regular
    static let provenanceDot = Font.system(size: provenanceDotSize, weight: provenanceDotWeight)

    /// Measured from `Detail header / v2` on 2026-09-22: the repo row is a 16 pt box, where the 12 pt text
    /// alone sets 15 (#22).
    static let provenanceLineHeight: CGFloat = 16

    /// Measured from the Overview frames on 2026-09-22 (`F9DDBD95`, `F8411B97`, `60DF313D`): 16 from the tags
    /// row's bottom to the banner or the tab strip, whichever comes next (#22; the header left 12, and 8 more
    /// above a strip with no banner). The token field sets 14 where the frame's row is 13: a 1 pt residual.
    static let headerBottomInset: CGFloat = 16

    /// Measured from `Skills / Tab Navigation` on 2026-09-22.
    static let tabLabelSize: CGFloat = 13
    static let tabLabelWeight: Font.Weight = .regular
    static let tabLabel = Font.system(size: tabLabelSize, weight: tabLabelWeight)

    /// Measured from `Skills / Tab Navigation` on 2026-09-22.
    static let tabLabelActiveSize: CGFloat = 13
    static let tabLabelActiveWeight: Font.Weight = .medium
    static let tabLabelActive = Font.system(size: tabLabelActiveSize, weight: tabLabelActiveWeight)

    // MARK: - Overview

    /// Measured from `Stat column` on 2026-09-22.
    static let statLabelSize: CGFloat = 12
    static let statLabelWeight: Font.Weight = .regular
    static let statLabel = Font.system(size: statLabelSize, weight: statLabelWeight)

    /// Measured from `Stat column` on 2026-09-22.
    static let statValueSize: CGFloat = 20
    static let statValueWeight: Font.Weight = .semibold
    static let statValue = Font.system(size: statValueSize, weight: statValueWeight)

    /// Measured from `Stat column` on 2026-09-22.
    static let statSubSize: CGFloat = 10
    static let statSubWeight: Font.Weight = .regular
    static let statSub = Font.system(size: statSubSize, weight: statSubWeight)

    /// Measured from `Stat column` on 2026-09-22.
    static let cardFillOpacity = 0.03
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let cardFillDarkOpacity = 0.08
    static let cardFill = dynamic(light: cardFillOpacity, dark: cardFillDarkOpacity)
    static let cardCornerRadius: CGFloat = 10
    static let cardPadding: CGFloat = 10
    static let cardContentGap: CGFloat = 2

    /// Measured from `Skills / Details — Overview (installed)` on 2026-09-22.
    static let sectionHeadingSize: CGFloat = 16
    static let sectionHeadingWeight: Font.Weight = .semibold
    static let sectionHeading = Font.system(size: sectionHeadingSize, weight: sectionHeadingWeight)

    /// Measured from `Key-value row` on 2026-09-22.
    static let kvLabelSize: CGFloat = 12
    static let kvLabelWeight: Font.Weight = .regular
    static let kvLabel = Font.system(size: kvLabelSize, weight: kvLabelWeight)
    static let kvValueColumnStart: CGFloat = 108

    /// Measured from `Key-value row` on 2026-09-22: the separator is 1 pt at 5% black.
    static let kvSeparatorOpacity = 0.05
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let kvSeparatorDarkOpacity = 0.12
    static let kvSeparator = dynamic(light: kvSeparatorOpacity, dark: kvSeparatorDarkOpacity)

    /// Measured from `Key-value row` on 2026-09-22: the trailing glyph is 12 pt in a 16 pt box.
    static let kvGlyphSize: CGFloat = 12
    static let kvGlyph = Font.system(size: kvGlyphSize)
    static let kvGlyphWidth: CGFloat = 16

    /// Measured from `Contents row` on 2026-09-22.
    static let barTrackOpacity = 0.03
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let barTrackDarkOpacity = 0.08
    static let barTrack = dynamic(light: barTrackOpacity, dark: barTrackDarkOpacity)
    static let barHeight: CGFloat = 4
    static let barCornerRadius: CGFloat = 2

    /// Measured from `Contents row` on 2026-09-22.
    static let barFillOpacity = 0.10
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let barFillDarkOpacity = 0.20
    static let barFill = dynamic(light: barFillOpacity, dark: barFillDarkOpacity)

    // MARK: - Update banner

    /// Measured from `Update banner` on 2026-09-22.
    static let bannerFillOpacity = 0.03
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let bannerFillDarkOpacity = 0.08
    static let bannerFill = dynamic(light: bannerFillOpacity, dark: bannerFillDarkOpacity)
    static let bannerCornerRadius: CGFloat = 20
    static let bannerHeight: CGFloat = 40
    static let bannerPadding: CGFloat = 6
    /// Measured from `Skills / Details — Overview` on 2026-09-22: banner y 195–235 → strip y 255.
    static let bannerToStrip: CGFloat = 20

    /// Measured from `Update banner` on 2026-09-22.
    static let bannerTitleSize: CGFloat = 13
    static let bannerTitleWeight: Font.Weight = .semibold
    static let bannerTitle = Font.system(size: bannerTitleSize, weight: bannerTitleWeight)

    // MARK: - Tab content

    /// Measured from `Skills / Details — Overview` (installed, update available),
    /// hairline 286 → card 306.
    static let stripHairlineToContentTop: CGFloat = 20

    /// Measured from `Skills / Details — Content` on 2026-09-22: hairline y 230 → pulldown y 246.
    static let contentRowTop: CGFloat = 16

    // MARK: - Deployments

    /// Measured from `Skills / Details — Deployments (no projects)` on 2026-09-22.
    static let groupTitleSize: CGFloat = 13
    static let groupTitleWeight: Font.Weight = .semibold
    static let groupTitle = Font.system(size: groupTitleSize, weight: groupTitleWeight)
    static let groupTitleLineHeight: CGFloat = 20
    /// Measured in the Settings design: title y 246 → box y 273.
    static let groupTitleToBoxTop: CGFloat = 27
    static let groupSectionSpacing: CGFloat = 32

    /// Measured from `Settings / description` on 2026-09-22.
    static let groupFillOpacity = 0.03
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let groupFillDarkOpacity = 0.08
    static let groupFill = dynamic(light: groupFillOpacity, dark: groupFillDarkOpacity)
    static let groupCornerRadius: CGFloat = 10

    /// Measured from `Settings / description` on 2026-09-22.
    static let groupDescriptionSize: CGFloat = 13
    static let groupDescriptionWeight: Font.Weight = .regular
    static let groupDescription = Font.system(size: groupDescriptionSize, weight: groupDescriptionWeight)
    static let groupDescriptionOpacity = 0.60
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let groupDescriptionDarkOpacity = 0.60
    static let groupDescriptionColor = dynamic(light: groupDescriptionOpacity, dark: groupDescriptionDarkOpacity)

    /// Measured from `Settings / project row` on 2026-09-22.
    static let groupEmptySize: CGFloat = 13
    static let groupEmptyWeight: Font.Weight = .regular
    static let groupEmpty = Font.system(size: groupEmptySize, weight: groupEmptyWeight)
    static let groupEmptyOpacity = 0.35
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let groupEmptyDarkOpacity = 0.40
    static let groupEmptyColor = dynamic(light: groupEmptyOpacity, dark: groupEmptyDarkOpacity)

    /// Measured from `Settings / row` on 2026-09-22.
    static let groupRowHeight: CGFloat = 40
    /// A 16 pt text line centered in the measured 40 pt Settings row.
    static let groupRowVerticalPadding = (groupRowHeight - 16) / 2
    static let groupLeadingInset: CGFloat = 8
    static let groupTrailingInset: CGFloat = 10
    static let groupPlatformTileSize: CGFloat = 20
    static let groupPlatformNameStart: CGFloat = 40
    static let groupNestedInset: CGFloat = 32
    static let groupProjectChevronWidth: CGFloat = 12
    static let groupProjectFolderStart: CGFloat = 24
    static let groupProjectFolderWidth: CGFloat = 20
    static let groupProjectNameStart: CGFloat = 56
    static let groupProjectPathStart: CGFloat = 240

    /// Measured from `Settings / row` on 2026-09-22.
    static let groupSeparatorOpacity = 0.05
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let groupSeparatorDarkOpacity = 0.12
    static let groupSeparator = dynamic(light: groupSeparatorOpacity, dark: groupSeparatorDarkOpacity)
    static let groupSeparatorHeight: CGFloat = 1

    /// Measured from `Footer / bg` on 2026-09-22: 3% over the group's 3% fill composites to 6%.
    static let footerFillOpacity = 0.03
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let footerFillDarkOpacity = 0.08
    static let footerFill = dynamic(light: footerFillOpacity, dark: footerFillDarkOpacity)
    static let footerHeight: CGFloat = 24

    /// Measured from `Settings / add footer` on 2026-09-22.
    static let footerLabelSize: CGFloat = 10
    static let footerLabelWeight: Font.Weight = .regular
    static let footerLabel = Font.system(size: footerLabelSize, weight: footerLabelWeight)
    static let footerLabelOpacity = 0.35
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let footerLabelDarkOpacity = 0.40
    static let footerLabelColor = dynamic(light: footerLabelOpacity, dark: footerLabelDarkOpacity)

    /// Measured from `Settings / add footer` on 2026-09-22.
    static let footerGlyphOpacity = 0.55
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let footerGlyphDarkOpacity = 0.55
    static let footerGlyph = dynamic(light: footerGlyphOpacity, dark: footerGlyphDarkOpacity)
    static let footerGlyphSize: CGFloat = 10
    static let footerGlyphStroke: CGFloat = 2
    static let footerGlyphLeading: CGFloat = 7
    static let footerDividerLeading: CGFloat = 24
    static let footerDividerHeight: CGFloat = 14
    static let footerLabelLeading: CGFloat = 32

    // MARK: - Empty states

    /// Measured from `Empty state / list (280)` and the `Skills / List — No Selection`,
    /// `Skills / Search - No Results` and `Projects / Empty` frames on 2026-10-04: the title inks 24 pt light.
    static let emptyStateTitleSize: CGFloat = 24
    static let emptyStateTitleWeight: Font.Weight = .light
    static let emptyStateTitle = Font.system(size: emptyStateTitleSize, weight: emptyStateTitleWeight)

    /// Measured from the same frames: the description inks 13 pt regular on a 16 pt line.
    static let emptyStateDescriptionSize: CGFloat = 13
    static let emptyStateDescriptionWeight: Font.Weight = .regular
    static let emptyStateDescription = Font.system(
        size: emptyStateDescriptionSize,
        weight: emptyStateDescriptionWeight
    )

    /// Measured from `Empty state / list (280)`: a 10 pt stack gap between title, description and action,
    /// and 16 pt side padding, so a 240 pt description wraps the way the frame does in a 280 pt column.
    static let emptyStateGap: CGFloat = 10
    static let emptyStateSidePadding: CGFloat = 16

    // MARK: - History

    /// Corrected from `Skills / Details — History` on 2026-09-22: hairline y 295 → row top y 315.
    static let historyContentTop: CGFloat = 20

    /// No Sketch frame draws the refresh notes yet. These values are provisional pending a
    /// decision on the PLAN-39 `design` issue.
    static let historyRefreshNoteSize: CGFloat = 11
    static let historyRefreshNoteWeight: Font.Weight = .regular
    static let historyRefreshNote = Font.system(
        size: historyRefreshNoteSize,
        weight: historyRefreshNoteWeight
    )

    /// Measured from the History frame on 2026-09-22: the connector is 1 pt at 10% black.
    static let timelineRuleOpacity = 0.10
    /// Chosen on the dark fixture 2026-09-22, no dark frame; pending a dark-mode design pass.
    static let timelineRuleDarkOpacity = 0.20
    static let timelineRule = dynamic(light: timelineRuleOpacity, dark: timelineRuleDarkOpacity)

    /// Maps effective light measurements and dark-fixture choices onto the semantic label color.
    static func dynamic(light: Double, dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let effectiveAlpha = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            var resolved = NSColor.labelColor.withAlphaComponent(effectiveAlpha)
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor.labelColor.withAlphaComponent(effectiveAlpha)
            }
            return resolved
        })
    }
}
