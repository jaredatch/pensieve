import SwiftUI

struct ViewChangesFileRow: View {
    let file: PinnedSkillFileDiff

    var body: some View {
        let parent = (ViewChangesPresentation.filePath(file) as NSString).deletingLastPathComponent
        HStack(spacing: DesignTokens.changesFileRowGap) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.changesFileGlyphWidth, height: DesignTokens.changesFileGlyphHeight)
            VStack(alignment: .leading, spacing: DesignTokens.changesFileFolderGap) {
                Text(verbatim: (ViewChangesPresentation.filePath(file) as NSString).lastPathComponent)
                    .font(DesignTokens.changesFileName).lineLimit(1).truncationMode(.middle)
                if !parent.isEmpty {
                    Text(verbatim: parent).font(DesignTokens.changesFileFolder)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DesignTokens.changesCountGap) {
                if let counts = ViewChangesPresentation.sidebarCounts(file) {
                    let added = counts.added
                    let removed = counts.removed
                    if added > 0 || removed == 0 { Text("+\(added)").foregroundStyle(Color(nsColor: .systemGreen)) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Color(nsColor: .systemRed)) }
                }
                if let marker = ViewChangesPresentation.sidebarMarker(file) {
                    Text(verbatim: marker).foregroundStyle(.secondary)
                }
            }
            .font(DesignTokens.changesCount)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, DesignTokens.changesFileRowHorizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: parent.isEmpty ? DesignTokens.changesFileRowHeight : DesignTokens.changesNestedFileRowHeight)
        .contentShape(Rectangle())
    }
}
