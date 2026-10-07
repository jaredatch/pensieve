import SwiftUI

struct ViewChangesFileRow: View {
    let file: PinnedSkillFileDiff

    var body: some View {
        let parent = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: DesignTokens.changesFileRowGap) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.changesFileGlyphWidth, height: DesignTokens.changesFileGlyphHeight)
            VStack(alignment: .leading, spacing: DesignTokens.changesFileFolderGap) {
                Text(ViewChangesPresentation.styledText((file.path as NSString).lastPathComponent, filename: true))
                    .font(DesignTokens.changesFileName).lineLimit(1).truncationMode(.middle)
                if !parent.isEmpty {
                    Text(ViewChangesPresentation.styledText(parent, filename: true)).font(DesignTokens.changesFileFolder)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(minWidth: DesignTokens.changesFileNameMinimumWidth, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: DesignTokens.changesCountGap) {
                if let counts = ViewChangesPresentation.sidebarCounts(file) {
                    let added = counts.added
                    let removed = counts.removed
                    if added > 0 || removed == 0 { Text("+\(added)").foregroundStyle(Color(nsColor: .systemGreen)) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Color(nsColor: .systemRed)) }
                }
            }
            .font(DesignTokens.changesCount)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            if let marker = ViewChangesPresentation.sidebarMarker(file) {
                Text(verbatim: marker).font(DesignTokens.changesCount).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: DesignTokens.changesFileMarkerMinimumWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, DesignTokens.changesFileRowHorizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: parent.isEmpty ? DesignTokens.changesFileRowHeight : DesignTokens.changesNestedFileRowHeight)
        .contentShape(Rectangle())
    }
}
