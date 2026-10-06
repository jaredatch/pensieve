import Foundation

/// Skill links are untrusted. Only web URLs leave the app; local navigation is limited to
/// the Content tab's admitted file choices and the rendered document's headings.
enum SkillPreviewLinkPolicy {
    enum Decision: Equatable {
        case openWeb
        case scrollTo(String)
        case selectFile(String)
        case ignore
    }

    struct HeadingTarget: Equatable {
        let id: UUID
        let slug: String
        let position: Double
    }

    static func decision(for url: URL, documentRelativePath: String, files: [String]) -> Decision {
        if url.scheme != nil {
            return WebLinkPolicy.isWebURL(url) ? .openWeb : .ignore
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == nil, components.query == nil,
              let path = components.percentEncodedPath.removingPercentEncoding else { return .ignore }
        if path.isEmpty {
            guard let fragment = components.fragment, !fragment.isEmpty else { return .ignore }
            return .scrollTo(fragment)
        }
        guard !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .ignore }
        let folder = documentRelativePath.split(separator: "/").dropLast().map(String.init)
        guard let resolved = normalized(folder + path.split(separator: "/").map(String.init)) else { return .ignore }
        if resolved == documentRelativePath {
            guard let fragment = components.fragment, !fragment.isEmpty else { return .ignore }
            return .scrollTo(fragment)
        }
        guard files.contains(resolved) else { return .ignore }
        return .selectFile(resolved)
    }

    private static func normalized(_ components: [String]) -> String? {
        var result: [String] = []
        for component in components {
            switch component {
            case ".": continue
            case "..":
                guard !result.isEmpty else { return nil }
                result.removeLast()
            default: result.append(component)
            }
        }
        return result.isEmpty ? nil : result.joined(separator: "/")
    }

    static func slug(_ heading: String) -> String {
        return String(String.UnicodeScalarView(heading.lowercased().unicodeScalars.compactMap { scalar in
            if scalar == " " { return "-" }
            let category = scalar.properties.generalCategory
            let isMark = category == .nonspacingMark || category == .spacingMark
            let isVariation = (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
            return !isVariation && (CharacterSet.alphanumerics.contains(scalar) || isMark
                || scalar == "-" || scalar == "_") ? scalar : nil
        }))
    }

    /// Geometry supplies document order even when SwiftUI reports preferences out of order.
    static func firstHeading(for slug: String, in headings: [HeadingTarget]) -> UUID? {
        var used: Set<String> = []
        for heading in headings.sorted(by: { $0.position < $1.position }) {
            var candidate = heading.slug
            var suffix = 0
            while used.contains(candidate) {
                suffix += 1
                candidate = "\(heading.slug)-\(suffix)"
            }
            used.insert(candidate)
            if candidate == slug.lowercased() { return heading.id }
        }
        return nil
    }
}
