import Foundation

/// Git config entries in file order, keyed as section.subsection.key. Includes are not followed.
/// Parse the entire text before returning entries so corruption after a value still refuses it.
enum GitConfigText {
    private static let gitWhitespace = CharacterSet(charactersIn: " \t\r\n")

    static func entries(_ config: String) throws -> [(key: String, value: String?)] {
        var section = ""
        var entries: [(key: String, value: String?)] = []
        for logical in configLines(config) {
            var line = String(logical.unicodeScalars.drop(while: gitWhitespace.contains))
            if line.hasPrefix("[") {
                guard let range = line.range(of: #"^\[[A-Za-z0-9.-]+([ \t\r]+"([^"\\]|\\.)*")?\]"#,
                                             options: .regularExpression) else { throw CocoaError(.fileReadCorruptFile) }
                let header = String(line[range].dropFirst().dropLast())
                section = sectionName(header)
                line = String(line[range.upperBound...].unicodeScalars.drop(while: gitWhitespace.contains))
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            guard let keyRange = line.range(of: #"^[A-Za-z][A-Za-z0-9-]*"#, options: .regularExpression) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let key = String(line[keyRange]).lowercased()
            let rest = String(line[keyRange.upperBound...].drop { $0 == " " || $0 == "\t" })
            let value: String?
            if rest.isEmpty { value = nil } else {
                guard rest.hasPrefix("=") else { throw CocoaError(.fileReadCorruptFile) }
                value = try configValue(String(rest.dropFirst()))
            }
            entries.append((section + "." + key, value))
        }
        return entries
    }

    /// Quoted subsections keep case and consume any backslash escape; dotted headers fold case.
    private static func sectionName(_ header: String) -> String {
        guard let quote = header.firstIndex(of: "\"") else { return header.lowercased() }
        let section = header[..<quote].trimmingCharacters(in: gitWhitespace).lowercased()
        var subsection = "", escaped = false
        for character in header[header.index(after: quote)...].dropLast() {
            if escaped {
                subsection.append(character)
                escaped = false
            } else if character == "\\" { escaped = true } else { subsection.append(character) }
        }
        return section + "." + subsection
    }

    private static func configLines(_ config: String) -> [String] {
        var lines: [String] = [], line = ""
        var quoted = false, escaped = false, comment = false, value = false
        let text = config.hasPrefix("\u{FEFF}") ? String(config.dropFirst()) : config
        for character in text.replacingOccurrences(of: "\r\n", with: "\n") {
            if character == "\n" {
                if escaped && !comment && value {
                    line.removeLast()
                } else {
                    lines.append(line)
                    line = ""
                    quoted = false
                    comment = false
                    value = false
                }
                escaped = false
                continue
            }
            line.append(character)
            if comment { continue }
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                quoted.toggle()
            } else if !quoted && character == "=" { value = true
            } else if !quoted && (character == "#" || character == ";") { comment = true }
        }
        lines.append(line)
        return lines
    }

    private static func configValue(_ text: String) throws -> String {
        var quoted = false, escaped = false, result = "", whitespace = ""
        for character in text {
            if escaped {
                let escapes: [Character: String] = ["n": "\n", "t": "\t", "b": "\u{8}", "\\": "\\", "\"": "\""]
                guard let value = escapes[character] else { throw CocoaError(.fileReadCorruptFile) }
                result += whitespace + value
                whitespace = ""
                escaped = false
            } else if character == "\\" { escaped = true } else if character == "\"" {
                result += whitespace
                whitespace = ""
                quoted.toggle()
            } else if !quoted && (character == "#" || character == ";") { break
            } else if !quoted && character.unicodeScalars.allSatisfy(gitWhitespace.contains) {
                if !result.isEmpty { whitespace += String(character) }
            } else {
                result += whitespace + String(character)
                whitespace = ""
            }
        }
        guard !quoted else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
