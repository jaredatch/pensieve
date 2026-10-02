import Foundation

enum PublishedStringSanitizer {
    static let nameLimit = 80
    static let pathLimit = 256
    static let nameScalarLimit = 4_096
    static let pathScalarLimit = 4_096
    private static let maxScalarsPerCharacter = 16
    private static let blackFlag: UInt32 = 0x1F3F4
    private static let tagRange: ClosedRange<UInt32> = 0xE0020...0xE007F

    static func name(_ value: String, fallback: String) -> String {
        let safe = trimmed(filtered(value, scalarLimit: nameScalarLimit))
        return hasVisibleContent(safe) ? capped(safe, limit: nameLimit) : fallback
    }

    static func path(_ value: String) -> String {
        sanitize(value, limit: pathLimit)
    }

    static func projectName(_ value: String, identityKey: String) -> String {
        let safe = trimmed(filtered(value, scalarLimit: nameScalarLimit))
        if hasVisibleContent(safe) { return capped(safe, limit: nameLimit) }
        let slash = UnicodeScalar(0x2F)!
        let componentScalars = identityKey.unicodeScalars
            .split(separator: slash, omittingEmptySubsequences: false).last ?? []
        let component = String(String.UnicodeScalarView(componentScalars))
        return name(component, fallback: "Project")
    }

    static func sanitize(_ value: String, limit: Int) -> String {
        capped(trimmed(filtered(value, scalarLimit: pathScalarLimit)), limit: limit)
    }

    private static func filtered(_ value: String, scalarLimit: Int) -> String {
        let bounded = value.unicodeScalars.prefix(scalarLimit)
        var current = String(String.UnicodeScalarView(bounded.filter { scalar in
            tagRange.contains(scalar.value) || isAllowed(scalar)
        }))
        while true {
            let next = tagAndClusterFilteringPass(current)
            if next.unicodeScalars.elementsEqual(current.unicodeScalars) { return next }
            current = next
        }
    }

    private static func tagAndClusterFilteringPass(_ value: String) -> String {
        let tagFilteredScalars = value.reduce(into: [UnicodeScalar]()) { result, character in
            let keepsTags = character.unicodeScalars.first?.value == blackFlag
            result.append(contentsOf: character.unicodeScalars.filter { scalar in
                keepsTags || !tagRange.contains(scalar.value)
            })
        }
        let tagFiltered = String(String.UnicodeScalarView(tagFilteredScalars))
        return tagFiltered.reduce(into: "") { result, character in
            let scalars = character.unicodeScalars
            guard !scalars.isEmpty, scalars.count <= maxScalarsPerCharacter else { return }
            result += String(String.UnicodeScalarView(scalars))
        }
    }

    private static func capped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 1 else { return "…" }
        return String(value.prefix(limit - 1)) + "…"
    }

    private static func isAllowed(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        if value == 0x200C || value == 0x200D {
            return true
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned:
            return false
        default:
            return true
        }
    }

    private static func hasVisibleContent(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !scalar.properties.isDefaultIgnorableCodePoint
                && scalar.value != 0x2800
                && !isMark(scalar)
        }
    }

    private static func isMark(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func trimmed(_ value: String) -> String {
        let characters = Array(value)
        guard let first = characters.firstIndex(where: { !isTrimmable($0) }),
              let last = characters.lastIndex(where: { !isTrimmable($0) }) else { return "" }
        return String(characters[first...last])
    }

    private static func isTrimmable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}
