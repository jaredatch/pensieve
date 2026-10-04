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
    private struct Heading {
        let line: Int
        let text: String
    }
    private let headings: [Heading]
    let text: String
    let licenseBlocks: [LicenseBlock]
    let editorEntries: [String: [EditorEntry]]

    init(_ source: String, licenseBlocks: [LicenseBlock]) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = normalized
        self.licenseBlocks = licenseBlocks
        var headings: [Heading] = []
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
                headings.append(Heading(line: number, text: line))
                pending.removeAll()
            }
            guard line.hasPrefix("- `"), let end = line.dropFirst(3).range(of: "` ") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound])
            let version = line[end.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "<missing>"
            pending.append((name, entries[name, default: []].count))
            entries[name, default: []].append(EditorEntry(version: version, license: nil))
        }
        self.headings = headings
        editorEntries = entries
    }

    func hasSection(_ heading: String) -> Bool {
        headings.contains { $0.text == heading }
    }

    func license(inSection heading: String) -> String? {
        guard let index = headings.firstIndex(where: { $0.text == heading }) else { return nil }
        let start = headings[index].line
        let end = headings.dropFirst(index + 1).first?.line ?? Int.max
        return licenseBlocks.first { $0.startLine > start && $0.endLine < end }?.text
    }

    private static func isHeading(_ line: String) -> Bool {
        let marks = line.prefix { $0 == "#" }.count
        return (1...6).contains(marks) && line.dropFirst(marks).first == " "
    }
}
