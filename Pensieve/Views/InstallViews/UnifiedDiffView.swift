import SwiftUI

/// Inert line rendering of the worker's bounded hunks. Long lines scroll horizontally without wrapping.
struct UnifiedDiffView: View {
    let diff: UnifiedDiff
    let notes: [[Int: [String]]]

    private enum RowContent {
        case header(String)
        case line(UnifiedDiffLine)
        case note(String)
    }

    private struct Row: Identifiable {
        let id: Int
        let content: RowContent
    }

    /// One identity space for the lazy stack, including headers and repeated notes.
    /// These are lightweight row values; SwiftUI still builds only the visible row views.
    private var rows: [Row] {
        var result: [Row] = []
        for (hunkIndex, hunk) in diff.hunks.enumerated() {
            let hunkNotes = notes.indices.contains(hunkIndex) ? notes[hunkIndex] : [:]
            result.append(Row(id: result.count, content: .header(hunk.header)))
            for (lineIndex, line) in hunk.lines.enumerated() {
                result.append(Row(id: result.count, content: .line(line)))
                for note in hunkNotes[lineIndex] ?? [] {
                    result.append(Row(id: result.count, content: .note(note)))
                }
            }
        }
        return result
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row.content {
                        case let .header(header):
                            diffRow(old: nil, new: nil, marker: "", text: AttributedString(header),
                                    fill: DesignTokens.diffHunkFill, kind: nil)
                        case let .line(line):
                            diffRow(old: line.oldLineNumber, new: line.newLineNumber,
                                    marker: marker(line.kind), text: ViewChangesPresentation.lineText(line),
                                    fill: fill(line.kind), kind: line.kind)
                        case let .note(note):
                            Text(verbatim: note)
                                .font(DesignTokens.diffLineNumber).foregroundStyle(.secondary)
                                .padding(.leading,
                                         2 * DesignTokens.diffNumberColumnWidth + DesignTokens.diffMarkerColumnWidth)
                                .frame(maxWidth: .infinity, minHeight: DesignTokens.diffRowHeight, alignment: .leading)
                                .background(DesignTokens.diffHunkFill)
                        }
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
                .padding(.vertical, DesignTokens.diffBodyVerticalPadding)
            }
        }
    }

    private func diffRow(old: Int?, new: Int?, marker: String, text: AttributedString,
                         fill: Color, kind: UnifiedDiffLine.Kind?) -> some View {
        HStack(spacing: 0) {
            number(old)
            number(new)
            Text(verbatim: marker)
                .font(DesignTokens.diffMarker)
                .foregroundStyle(kind == .removed ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))
                .frame(width: DesignTokens.diffMarkerColumnWidth)
            Text(text)
                .font(DesignTokens.diffText)
                .foregroundStyle(kind == nil ? .secondary : .primary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: DesignTokens.diffTextLineHeight, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.trailing, DesignTokens.diffTrailingInset)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.diffRowHeight, maxHeight: DesignTokens.diffRowHeight,
               alignment: .leading)
        .background(fill)
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .font(DesignTokens.diffLineNumber)
            .foregroundStyle(.tertiary)
            .frame(width: DesignTokens.diffNumberColumnWidth, alignment: .trailing)
    }

    private func marker(_ kind: UnifiedDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private func fill(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .added: return DesignTokens.diffAddedFill
        case .removed: return DesignTokens.diffRemovedFill
        case .context: return .clear
        }
    }
}
