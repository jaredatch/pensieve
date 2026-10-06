import Foundation

/// Pure, SwiftData-free `.mdc` generator (PLAN-12 / 12.1). Extracted from
/// `CursorCompiler.generateMDC` byte-for-byte so the GUI compiler and the background daemon share
/// one implementation and can never drift. `directoryName` is accepted for call-site uniformity with
/// the daemon's reconcile pass; the compiled `.mdc` content does not embed it.
enum CursorMDC {
    /// A YAML comment supplies provenance without adding a Cursor setting or rule instruction.
    static let ownershipMark = "# pensieve: managed"

    static func generate(
        directoryName: String,
        description: String,
        cursorConfig: CursorAdapterConfig?,
        body: String
    ) -> String {
        let legacy = generateLegacy(directoryName: directoryName, description: description,
                                    cursorConfig: cursorConfig, body: body)
        return "---\n" + ownershipMark + "\n" + legacy.dropFirst(4)
    }

    static func generateLegacy(
        directoryName: String, description: String, cursorConfig: CursorAdapterConfig?, body: String
    ) -> String {
        var frontmatter: [String] = []

        let config = cursorConfig ?? CursorAdapterConfig()

        // Description: use Cursor config description, fall back to the skill description.
        let resolvedDescription = config.description ?? description
        if !resolvedDescription.isEmpty {
            frontmatter.append("description: \(resolvedDescription)")
        }

        // Globs
        if let globs = config.globs, !globs.isEmpty {
            let globString = globs.joined(separator: ", ")
            frontmatter.append("globs: \(globString)")
        }

        // alwaysApply
        frontmatter.append("alwaysApply: \(config.alwaysApply)")

        return "---\n" + frontmatter.joined(separator: "\n") + "\n---\n\n" + body + "\n"
    }

    /// Only an exact comment line inside a closed, first-line frontmatter block is authority.
    /// CRLF and a leading UTF-8 BOM are accepted. Text beyond the closing fence is ignored.
    static func hasOwnershipMark(in header: Data) -> Bool {
        let bytes = header.starts(with: [0xEF, 0xBB, 0xBF]) ? header.dropFirst(3) : header[...]
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first == "---" else { return false }
        var marked = false
        for line in lines.dropFirst() {
            if line == "---" { return marked }
            if line == ownershipMark { marked = true }
        }
        return false
    }
}
