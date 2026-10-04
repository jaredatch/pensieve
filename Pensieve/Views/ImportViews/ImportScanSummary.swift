import SwiftUI

struct ImportScanSummary: View {
    let summary: String?

    var body: some View {
        if let summary {
            Text(verbatim: summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
