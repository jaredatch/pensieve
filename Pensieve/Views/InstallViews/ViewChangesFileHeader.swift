import SwiftUI

struct ViewChangesFileHeader: View {
    let file: PinnedSkillFileDiff

    var body: some View {
        HStack {
            Text(verbatim: ViewChangesPresentation.filePath(file))
                .font(DesignTokens.changesFilePath).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Spacer()
            Text(verbatim: ViewChangesPresentation.summary(file))
                .font(DesignTokens.changesSummary).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 160, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.changesToolbarInset)
        .frame(height: DesignTokens.changesFileHeaderHeight)
    }
}
