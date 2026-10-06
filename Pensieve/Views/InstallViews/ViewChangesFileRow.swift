import SwiftUI

struct ViewChangesFileRow: View {
    let file: PinnedSkillFileDiff
    let selected: Bool

    var body: some View {
        let parent = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: DesignTokens.changesFileRowGap) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.changesFileGlyphWidth, height: DesignTokens.changesFileGlyphHeight)
            VStack(alignment: .leading, spacing: DesignTokens.changesFileFolderGap) {
                Text(verbatim: (file.path as NSString).lastPathComponent).font(DesignTokens.changesFileName).lineLimit(1)
                if !parent.isEmpty {
                    Text(verbatim: parent).font(DesignTokens.changesFileFolder).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.changesCountGap) {
                if let counts = ViewChangesPresentation.sidebarCounts(file) {
                    let added = counts.added
                    let removed = counts.removed
                    if added > 0 || removed == 0 { Text("+\(added)").foregroundStyle(Color(nsColor: .systemGreen)) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Color(nsColor: .systemRed)) }
                } else {
                    if case .modeOnly = file.content {
                        Text("Mode").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: ViewChangesPresentation.summary(file)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(DesignTokens.changesCount)
        }
        .padding(.horizontal, DesignTokens.changesFileRowHorizontalPadding)
        .frame(height: parent.isEmpty ? DesignTokens.changesFileRowHeight : DesignTokens.changesNestedFileRowHeight)
        .background(selected ? DesignTokens.changesFileRowSelectedFill : .clear,
                    in: RoundedRectangle(cornerRadius: DesignTokens.changesFileRowCornerRadius))
        .contentShape(Rectangle())
    }
}
