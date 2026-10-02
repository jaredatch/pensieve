import SwiftUI

struct DiffRow: Equatable {
    let this: String?
    let other: String?
    let changed: Bool
}

struct LineDiffView: View {
    let thisText: String
    let otherText: String
    let maxRows: Int
    let thisLabel: String
    let otherLabel: String

    init(this thisText: String, other otherText: String, maxRows: Int = 400,
         thisLabel: String = "This Mac", otherLabel: String = "Other Mac") {
        self.thisText = thisText
        self.otherText = otherText
        self.maxRows = maxRows
        self.thisLabel = thisLabel
        self.otherLabel = otherLabel
    }

    var body: some View {
        let rows = Self.alignedRows(this: thisText, other: otherText)
        let visibleRows = Array(rows.prefix(maxRows))
        let truncatedCount = rows.count - visibleRows.count

        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Text(thisLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(otherLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            LazyVStack(spacing: Spacing.xxs) {
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                    DiffLineRow(row: row)
                }
                if truncatedCount > 0 {
                    Text("... diff truncated - \(truncatedCount) more lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Spacing.xs)
                }
            }
        }
    }

    /// Side-by-side alignment. Equal lines are unchanged; removed/inserted lines are changed; a removal
    /// next to an insertion is a changed pair.
    static func alignedRows(this thisText: String, other otherText: String) -> [DiffRow] {
        let a = thisText.components(separatedBy: "\n")
        let b = otherText.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>()
        var inserted: [Int: String] = [:]
        for change in diff {
            switch change {
            case let .remove(offset, _, _):
                removed.insert(offset)
            case let .insert(offset, element, _):
                inserted[offset] = element
            }
        }
        var rows: [DiffRow] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            let aRemoved = i < a.count && removed.contains(i)
            let bInserted = j < b.count && inserted[j] != nil
            if aRemoved && bInserted {
                rows.append(DiffRow(this: a[i], other: b[j], changed: true))
                i += 1
                j += 1
            } else if aRemoved {
                rows.append(DiffRow(this: a[i], other: nil, changed: true))
                i += 1
            } else if bInserted {
                rows.append(DiffRow(this: nil, other: b[j], changed: true))
                j += 1
            } else {
                rows.append(DiffRow(this: a[i], other: b[j], changed: false))
                i += 1
                j += 1
            }
        }
        return rows
    }
}

private struct DiffLineRow: View {
    let row: DiffRow

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            diffCell(row.this)
            diffCell(row.other)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(row.changed ? Color.orange.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Spacing.xs, style: .continuous))
    }

    private func diffCell(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
