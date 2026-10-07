import SwiftUI

struct ViewChangesFileHeader: View {
    let file: PinnedSkillFileDiff

    var body: some View {
        HStack {
            Text(ViewChangesPresentation.styledText(file.path, filename: true))
                .font(DesignTokens.changesFilePath).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: DesignTokens.changesFilePathMinimumWidth, maxWidth: .infinity, alignment: .leading)
            Text(verbatim: ViewChangesPresentation.summary(file))
                .font(DesignTokens.changesSummary).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: DesignTokens.changesFileSummaryMinimumWidth, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.changesToolbarInset)
        .frame(minHeight: DesignTokens.changesFileHeaderHeight)
    }
}
