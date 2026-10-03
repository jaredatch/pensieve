import Foundation
@testable import Pensieve

/// Audits resolved dependencies and documentation/plain-text files whose names contain
/// license, licence, copying, copyright, notice or unlicense (case-insensitively).
/// Source/tooling extensions and symlinks are excluded. Embedded notices (swift-cmark
/// and Sparkle) are compared as complete text. Notices hidden in source comments are
/// outside this discovery; libYAML's omitted license is audited separately.
struct NoticeInventory {
    struct MissingNotice: Error, CustomStringConvertible {
        let description: String
    }

    let fileService: FileServiceProtocol

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func checkSwiftPackages(resolved: String, checkouts: String, notices: NoticeDocument, credits: String) throws {
        let data = try fileService.readData(at: resolved)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let pins = json?["pins"] as? [[String: Any]] else {
            throw MissingNotice(description: "Invalid Package.resolved")
        }
        let directories = try fileService.listDirectory(at: checkouts)
        let bundled = Self.normalized(credits)
        for pin in pins {
            guard let identity = pin["identity"] as? String else {
                throw MissingNotice(description: "Missing package identity in Package.resolved")
            }
            let pattern = "\\[([^]]+)\\]\\(https://github.com/[^/]+/"
                + NSRegularExpression.escapedPattern(for: identity) + "(?:\\.git)?\\)"
            let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            guard let match = expression.firstMatch(in: notices.text,
                                                    range: NSRange(notices.text.startIndex..., in: notices.text)),
                  let nameRange = Range(match.range(at: 1), in: notices.text),
                  credits.contains(String(notices.text[nameRange])) else {
                throw MissingNotice(description: "Missing notice for Swift package \(identity)")
            }
            guard let directory = directories.first(where: { $0.lowercased() == identity.lowercased() }) else {
                throw MissingNotice(description: "Missing checkout for Swift package \(identity)")
            }
            let root = checkouts + "/" + directory
            let licenses = try licenseFiles(in: root)
            guard !licenses.isEmpty else {
                throw MissingNotice(description: "No license files for Swift package \(identity)")
            }
            for path in licenses {
                let license = Self.normalized(try fileService.readFile(at: path))
                guard !license.isEmpty, bundled.contains(license) else {
                    throw MissingNotice(description: "Missing bundled license: \(identity)/\(path.dropFirst(root.count + 1))")
                }
            }
        }
    }

    func checkEditorPackages(lockfile: String, notices: NoticeDocument, credits: String) throws {
        let json = try JSONSerialization.jsonObject(with: fileService.readData(at: lockfile)) as? [String: Any]
        guard let packages = json?["packages"] as? [String: [String: Any]] else {
            throw MissingNotice(description: "Invalid editor package-lock.json")
        }
        let bundled = Self.normalized(credits)
        for path in packages.keys.sorted() where !path.isEmpty && packages[path]?["dev"] as? Bool != true {
            let name = path.components(separatedBy: "node_modules/").last ?? path
            let marker = "- `\(name)` "
            let expression = try NSRegularExpression(pattern: "(?:\\A|(?<=\\n))"
                                                     + NSRegularExpression.escapedPattern(for: marker) + "([^\\n]*)")
            let entries = expression.matches(in: notices.text, range: NSRange(notices.text.startIndex..., in: notices.text))
            guard !entries.isEmpty else {
                throw MissingNotice(description: "Missing notice for editor package \(name)")
            }
            let version = packages[path]?["version"] as? String ?? "<missing>"
            let versions = entries.map { entry in
                Range(entry.range(at: 1), in: notices.text).flatMap { range in
                    notices.text[range].split(whereSeparator: \.isWhitespace).first.map(String.init)
                } ?? "<missing>"
            }
            guard version != "<missing>", let index = versions.firstIndex(of: version),
                  let entry = Range(entries[index].range, in: notices.text) else {
                throw MissingNotice(description: "Version mismatch for editor package \(name): "
                                    + "lockfile \(version), notice \(versions.joined(separator: ", "))")
            }
            guard let body = notices.license(after: entry.upperBound), packages[path]?["license"] as? String == "MIT" else {
                throw MissingNotice(description: "Missing or unsupported license for editor package \(name)")
            }
            let license = Self.normalized(body)
            guard license.contains("Copyright"), license.contains("Permission is hereby granted"),
                  license.contains("THE SOFTWARE IS PROVIDED"),
                  bundled.contains(license), credits.contains(name) else {
                throw MissingNotice(description: "Missing bundled license for editor package \(name)")
            }
        }
    }

    func checkouts(for host: URL) throws -> String {
        let products = host.deletingLastPathComponent().deletingLastPathComponent()
        let build = products.deletingLastPathComponent()
        guard products.lastPathComponent == "Products", build.lastPathComponent == "Build" else {
            throw MissingNotice(description: "Cannot locate Swift package checkouts from test host: \(host.path)")
        }
        let path = build.deletingLastPathComponent().appendingPathComponent("SourcePackages/checkouts").path
        guard fileService.directoryExists(at: path) else {
            throw MissingNotice(description: "Missing Swift package checkouts for test host: \(path)")
        }
        return path
    }

    private func licenseFiles(in directory: String) throws -> [String] {
        var result: [String] = []
        for name in try fileService.listDirectory(at: directory).sorted() where name != ".git" {
            let path = directory + "/" + name
            let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
            if fileService.isSymlink(at: path) { continue }
            if fileService.directoryExists(at: path) {
                result += try licenseFiles(in: path)
            } else if ["", "txt", "md", "markdown", "rst", "html"].contains(suffix),
                      name.range(of: "licen[sc]e|copying|copyright|notice|unlicense",
                                 options: [.regularExpression, .caseInsensitive]) != nil {
                result.append(path)
            }
        }
        return result
    }
}
