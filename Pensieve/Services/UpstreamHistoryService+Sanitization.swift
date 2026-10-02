import Foundation

extension UpstreamHistoryService {
    static func safeRow(_ row: UpstreamHistoryRow) -> UpstreamHistoryRow {
        UpstreamHistoryRow(
            sha: row.sha,
            author: safeDisplay(row.author, limit: authorLimit),
            date: row.date,
            subject: safeDisplay(row.subject, limit: subjectLimit),
            filesChanged: row.filesChanged,
            linesAdded: row.linesAdded,
            linesRemoved: row.linesRemoved,
            skillMarkdown: row.skillMarkdown
        )
    }

    static func containsUnsafeControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.properties.generalCategory == .control
                || $0.properties.generalCategory == .lineSeparator
                || $0.properties.generalCategory == .paragraphSeparator
        }
    }

    static func safeDisplay(_ value: String, limit: Int) -> String {
        var output = ""
        var emittedScalars = 0
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count, emittedScalars < limit {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                index += 1
                if index < scalars.count, scalars[index] == "[" {
                    index += 1
                    while index < scalars.count {
                        let code = scalars[index]
                        index += 1
                        if (0x40 ... 0x7E).contains(code.value) { break }
                    }
                }
                continue
            }
            let category = scalar.properties.generalCategory
            if category == .control || category == .lineSeparator || category == .paragraphSeparator {
                output.append(" ")
            } else if category != .format {
                output.unicodeScalars.append(scalar)
            } else {
                index += 1
                continue
            }
            emittedScalars += 1
            index += 1
        }
        return output
    }
}
