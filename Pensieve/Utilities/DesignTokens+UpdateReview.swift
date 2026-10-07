import SwiftUI

/// Update review tokens (PLAN-47): the Updates sheet and the View Changes window, measured from their Sketch frames.
extension DesignTokens {
    // MARK: - Updates sheet

    /// Measured from the Updates sheet on 2026-10-05; stock controls keep their native appearance.
    static let updatesTitle = Font.system(size: 16, weight: .bold)
    static let updatesSubtitle = Font.system(size: 13)
    static let updatesRowName = Font.system(size: 13, weight: .semibold)
    static let updatesRowSource = Font.system(size: 13)
    static let updatesRowCommits = Font.system(size: 11, design: .monospaced)
    static let updatesChangesButton = Font.system(size: 11)
    static let updatesSheetWidth: CGFloat = 480
    static let updatesSheetPadding: CGFloat = 20
    static let updatesHeaderGap: CGFloat = 4
    static let updatesHeaderBottom: CGFloat = 12
    static let updatesTitleLineHeight: CGFloat = 20
    static let updatesSubtitleLineHeight: CGFloat = 16
    static let updatesCheckboxHeight: CGFloat = 24
    static let updatesDividerHeight: CGFloat = 1
    static let updatesRowBodyOffset: CGFloat = 21
    static let updatesRowNameLineHeight: CGFloat = 16
    static let updatesRowCommitsLineHeight: CGFloat = 13
    static let updatesSelectionPadding = EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20)
    static let updatesRowPadding = EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
    static let updatesRowMetaGap: CGFloat = 2
    static let updatesRowBodyTop: CGFloat = 4
    static let updatesLocalEditsGap: CGFloat = 10
    static let updatesLocalEditsPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let updatesLocalEditsCornerRadius: CGFloat = 8
    static let updatesLocalEditsContentGap: CGFloat = 8
    static let updatesLocalEditsIconGap: CGFloat = 6
    static let updatesLocalEditsIconSize: CGFloat = 16
    static let updatesFooterPadding = EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20)
    static let updatesCancelWidth: CGFloat = 75
    static let updatesUpdateWidth: CGFloat = 78
    static let updatesButtonHeight: CGFloat = 28
    static let updatesLocalEditsFill = Color(nsColor: .systemOrange).opacity(0.12)
    /// Native sheet frame inset under the unified main toolbar, measured at 900×600 on 2026-10-06.
    static let updatesSheetTopInset: CGFloat = 52
    static let updatesMaximumHeight = mainWindowMinimumHeight - updatesSheetTopInset

    // MARK: - View Changes window

    /// Measured from the View Changes frame on 2026-10-05. Title and path use the recorded defaults.
    static let changesTitle = Font.system(size: 16, weight: .bold)
    static let changesSubtitle = Font.system(size: 10)
    static let changesFileName = Font.system(size: 12)
    static let changesFileFolder = Font.system(size: 10)
    static let changesCount = Font.system(size: 11, design: .monospaced)
    static let changesFilePath = Font.system(size: 11, design: .monospaced)
    static let changesSummary = Font.system(size: 10)
    static let diffLineNumber = Font.system(size: 11, design: .monospaced)
    static let diffText = Font.system(size: 12, design: .monospaced)
    static let diffMarker = Font.system(size: 12, design: .monospaced)
    static let changesButton = Font.system(size: 13)
    static let changesWindowWidth: CGFloat = 1040
    static let changesWindowHeight: CGFloat = 660
    static let changesSidebarWidth: CGFloat = 240
    static let changesSidebarInset: CGFloat = 8
    static let changesSidebarHeaderTop: CGFloat = 4
    static let changesSidebarHeaderBottom: CGFloat = 6
    static let changesFileRowHeight: CGFloat = 28
    static let changesNestedFileRowHeight: CGFloat = 42
    static let changesFileRowHorizontalPadding: CGFloat = 10
    static let changesFileRowGap: CGFloat = 8
    static let changesFileRowSpacing: CGFloat = 2
    static let changesFileFolderGap: CGFloat = 1
    static let changesCountGap: CGFloat = 4
    static let changesFileGlyphWidth: CGFloat = 13
    static let changesFileGlyphHeight: CGFloat = 16
    static let changesToolbarHeight: CGFloat = 59
    static let changesToolbarInset: CGFloat = 16
    static let changesTitleGap: CGFloat = 2
    static let changesGitHubButtonWidth: CGFloat = 128
    static let changesUpdateButtonWidth: CGFloat = 78
    static let changesButtonHeight: CGFloat = 28
    static let changesDividerHeight: CGFloat = 1
    static let changesFileHeaderHeight: CGFloat = 29
    static let changesFileNameMinimumWidth: CGFloat = 80
    static let changesFileMarkerMinimumWidth: CGFloat = 60
    static let changesFilePathMinimumWidth: CGFloat = 160
    static let changesFileSummaryMinimumWidth: CGFloat = 160
    static let diffRowHeight: CGFloat = 20
    static let diffTextLineHeight: CGFloat = 18
    static let diffNumberColumnWidth: CGFloat = 36
    static let diffMarkerColumnWidth: CGFloat = 28
    static let diffTrailingInset: CGFloat = 16
    static let diffBodyVerticalPadding: CGFloat = 6

    static let diffHiddenCharacter = Color(nsColor: .systemOrange)

    /// Light frame opacities; dark uses the same opacities on system semantic colors, pending the look gate.
    static let diffHunkFill = dynamic(light: 0.04, dark: 0.04)
    static let diffRemovedFill = Color(nsColor: .systemRed).opacity(0.10)
    static let diffAddedFill = Color(nsColor: .systemGreen).opacity(0.12)
    static let changesDividerFill = dynamic(light: 0.05, dark: 0.05)
}
