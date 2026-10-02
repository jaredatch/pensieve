import Foundation

/// Pure, SwiftData-free `.mdc` generator (PLAN-12 / 12.1). Extracted from
/// `CursorCompiler.generateMDC` byte-for-byte so the GUI compiler and the background daemon share
/// one implementation and can never drift. `directoryName` is accepted for call-site uniformity with
/// the daemon's reconcile pass; the compiled `.mdc` content does not embed it.
enum CursorMDC {
    static func generate(
        directoryName: String,
        description: String,
        cursorConfig: CursorAdapterConfig?,
        body: String
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
}
