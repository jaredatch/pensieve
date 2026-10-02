import Foundation

/// Removes terminal escapes and replaces control characters in untrusted display text.
enum DisplayTextSanitizer {
    static func singleLine(_ value: String) -> String {
        sanitize(value).components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Printed log lines keep their whitespace and text; only terminal commands and non-tab controls go.
    static func logLine(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var output = ""
        var index = 0
        while index < scalars.count {
            if let end = terminalEscapeEnd(in: scalars, at: index) {
                index = end
                continue
            }
            let scalar = scalars[index]
            let category = scalar.properties.generalCategory
            if category == .lineSeparator || category == .paragraphSeparator {
                output.append(" ")
            } else if category != .format || scalar.value == 0x200C || scalar.value == 0x200D,
                      scalar.value == 9 || category != .control {
                output.unicodeScalars.append(scalar)
            }
            index += 1
        }
        return output
    }

    private static func terminalEscapeEnd(in scalars: [Unicode.Scalar], at start: Int) -> Int? {
        let first = scalars[start].value
        let isEscape = first == 0x1B
        guard isEscape || [0x90, 0x98, 0x9B, 0x9D, 0x9E, 0x9F].contains(first) else { return nil }
        var index = start + 1
        guard index < scalars.count else { return index }
        let command = isEscape ? scalars[index].value : first
        if isEscape { index += 1 }
        if command == 0x5B || command == 0x9B {
            return terminalCSIEnd(in: scalars, from: index)
        }
        if [0x50, 0x58, 0x5D, 0x5E, 0x5F, 0x90, 0x98, 0x9D, 0x9E, 0x9F].contains(command) {
            return terminalStringEnd(in: scalars, from: index)
        }
        // Other ESC commands have zero or more intermediate bytes followed by a final byte.
        if (0x20 ... 0x2F).contains(command) {
            while index < scalars.count, (0x20 ... 0x2F).contains(scalars[index].value) { index += 1 }
            if index < scalars.count, (0x30 ... 0x7E).contains(scalars[index].value) { index += 1 }
        }
        return (0x20 ... 0x7E).contains(command) ? index : start + 1
    }

    private static func terminalCSIEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let code = scalars[index].value
            guard (0x20 ... 0x7E).contains(code) else { break }
            index += 1
            if (0x40 ... 0x7E).contains(code) { break }
        }
        return index
    }

    private static func terminalStringEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let code = scalars[index].value
            if code == 7 || code == 0x9C { return index + 1 }
            if code == 0x1B, index + 1 < scalars.count, scalars[index + 1].value == 0x5C { return index + 2 }
            index += 1
        }
        return index
    }

    static func sanitize(_ value: String) -> String {
        var output = ""
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if let end = terminalEscapeEnd(in: scalars, at: index) {
                index = end
                continue
            }
            let scalar = scalars[index]
            let category = scalar.properties.generalCategory
            if CharacterSet.newlines.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else if category == .control {
                output.append(" ")
            } else if category != .format || scalar.value == 0x200C || scalar.value == 0x200D {
                output.unicodeScalars.append(scalar)
            } else {
                index += 1
                continue
            }
            index += 1
        }
        return output
    }
}
