import Foundation

/// License blocks come from credits.py, the renderer itself. Source line numbers
/// associate grouped editor entries and exact headings without another fence parser.
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
    struct Heading {
        let line: Int
        let text: String
    }

    let text: String
    let licenseBlocks: [LicenseBlock]
    let editorEntries: [String: [EditorEntry]]
    private let headings: [Heading]

    init(_ source: String, licenseBlocks: [LicenseBlock]) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = normalized
        self.licenseBlocks = licenseBlocks
        var entries: [String: [EditorEntry]] = [:]
        var headers: [Heading] = []
        var blockIndex = 0
        for (number, line) in normalized.components(separatedBy: "\n").enumerated() {
            while blockIndex < licenseBlocks.count && licenseBlocks[blockIndex].endLine < number { blockIndex += 1 }
            let block = blockIndex < licenseBlocks.count ? licenseBlocks[blockIndex] : nil
            if let block, block.startLine <= number { continue }
            if Self.isHeading(line) { headers.append(Heading(line: number, text: line)) }
            guard line.hasPrefix("- `"), let end = line.dropFirst(3).range(of: "` ") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound])
            let version = line[end.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "<missing>"
            entries[name, default: []].append(EditorEntry(version: version, license: block?.text))
        }
        editorEntries = entries
        headings = headers
    }

    func license(inSection heading: String) -> String? {
        guard let index = headings.firstIndex(where: { $0.text == heading }) else { return nil }
        let start = headings[index].line
        let end = index + 1 < headings.count ? headings[index + 1].line : Int.max
        return licenseBlocks.first { $0.startLine > start && $0.startLine < end }?.text
    }

    private static func isHeading(_ line: String) -> Bool {
        let marks = line.prefix { $0 == "#" }.count
        return (1...6).contains(marks) && line.dropFirst(marks).first == " "
    }
}
