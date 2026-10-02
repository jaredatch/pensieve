import SwiftUI

/// Mail's message-list row, the one row component for every middle-column list. The fonts
/// are the macOS type scale's `.headline` (13pt bold) and `.subheadline` (11pt), which measured equal
/// to Mail's sender, subject, and preview lines on 2026-09-07; 3pt line spacing and 5pt vertical
/// padding reproduce Mail's line pitch (19pt then 17pt) in a 68pt three-line row. No leading icon
/// and no status dot; the separator starts at the text's leading edge as Mail's
/// does. 4pt of horizontal padding on top of the inset list's own 16pt puts the text 20pt from the
/// column edge, flush with the toolbar title, and 10pt inside the selection rectangle on each side
/// (measured on a Mac, 2026-09-10). The view reads only its model and two
/// Bools: no disk, no queries, no dates.
struct ListRowView: View {
    let model: ListRowModel
    var showsLine2 = true
    var showsLine3 = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                if let glyph = model.glyph {
                    glyphView(glyph)
                }
                if let trailing = model.trailingText {
                    Text(trailing)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if showsLine2, let line2 = model.line2 {
                Text(line2)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(model.line2TruncatesMiddle ? .middle : .tail)
            }
            if showsLine3, let line3 = model.line3 {
                Text(line3)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(EdgeInsets(top: 5, leading: Spacing.xs, bottom: 5, trailing: Spacing.xs))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + Spacing.xs }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func glyphView(_ glyph: ListRowModel.Glyph) -> some View {
        switch glyph {
        case .gitHub:
            Image("github-mark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .foregroundStyle(.primary)
                .accessibilityLabel(glyph.accessibilityLabel)
        case .updateAvailable:
            Image(systemName: "arrow.down.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(glyph.accessibilityLabel)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityLabel(glyph.accessibilityLabel)
        }
    }
}
