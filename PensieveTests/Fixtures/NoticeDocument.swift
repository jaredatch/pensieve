import Foundation

/// License blocks come from credits.py, the renderer itself. Source line numbers
/// associate grouped editor entries without another fence parser.
struct NoticeDocument {
    struct LicenseBlock: Decodable {
        let startLine: Int
        let endLine: Int
        let text: String
    }
    struct EditorEntry {
        let version: String
        let license: String?
    }
    let text: String
    let licenseBlocks: [LicenseBlock]
    let editorEntries: [String: [EditorEntry]]

    init(_ source: String, licenseBlocks: [LicenseBlock]) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = normalized
        self.licenseBlocks = licenseBlocks
        var entries: [String: [EditorEntry]] = [:]
        var pending: [(name: String, index: Int)] = []
        var blockIndex = 0
        for (number, line) in normalized.components(separatedBy: "\n").enumerated() {
            while blockIndex < licenseBlocks.count && licenseBlocks[blockIndex].endLine < number { blockIndex += 1 }
            let block = blockIndex < licenseBlocks.count ? licenseBlocks[blockIndex] : nil
            if let block, block.startLine == number {
                for item in pending {
                    if let version = entries[item.name]?[item.index].version {
                        entries[item.name]?[item.index] = EditorEntry(version: version, license: block.text)
                    }
                }
                pending.removeAll()
            }
            if let block, block.startLine <= number { continue }
            if Self.isHeading(line) {
                pending.removeAll()
            }
            guard line.hasPrefix("- `"), let end = line.dropFirst(3).range(of: "` ") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound])
            let version = line[end.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "<missing>"
            pending.append((name, entries[name, default: []].count))
            entries[name, default: []].append(EditorEntry(version: version, license: nil))
        }
        editorEntries = entries
    }

    private static func isHeading(_ line: String) -> Bool {
        let marks = line.prefix { $0 == "#" }.count
        return (1...6).contains(marks) && line.dropFirst(marks).first == " "
    }
}
