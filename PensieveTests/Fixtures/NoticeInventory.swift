import Foundation
@testable import Pensieve

/// Audits resolved dependencies and every conventional license file in their checkouts.
/// Embedded notices (swift-cmark and Sparkle) are compared as complete text. libYAML's
/// checkout omits its license file, so the suite also pins its upstream notice separately.
/// This does not discover differently named notices hidden in source comments.
struct NoticeInventory {
    struct MissingNotice: Error, CustomStringConvertible {
        let description: String
    }

    let fileService: FileServiceProtocol

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func checkSwiftPackages(resolved: String, checkouts: String, notices: String, credits: String) throws {
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
            guard let match = expression.firstMatch(in: notices, range: NSRange(notices.startIndex..., in: notices)),
                  let nameRange = Range(match.range(at: 1), in: notices), credits.contains(String(notices[nameRange])) else {
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

    func checkEditorPackages(lockfile: String, notices: String, credits: String) throws {
        let json = try JSONSerialization.jsonObject(with: fileService.readData(at: lockfile)) as? [String: Any]
        guard let packages = json?["packages"] as? [String: [String: Any]] else {
            throw MissingNotice(description: "Invalid editor package-lock.json")
        }
        for path in packages.keys.sorted() where !path.isEmpty && packages[path]?["dev"] as? Bool != true {
            let name = path.components(separatedBy: "node_modules/").last ?? path
            let marker = "- `\(name)` "
            guard let entry = notices.range(of: marker) else {
                throw MissingNotice(description: "Missing notice for editor package \(name)")
            }
            let remainder = notices[entry.upperBound...]
            guard let start = remainder.range(of: "```text\n"),
                  let end = remainder[start.upperBound...].range(of: "\n```"),
                  packages[path]?["license"] as? String == "MIT" else {
                throw MissingNotice(description: "Missing or unsupported license for editor package \(name)")
            }
            let license = Self.normalized(String(remainder[start.upperBound..<end.lowerBound]))
            guard license.contains("Copyright"), license.contains("Permission is hereby granted"),
                  license.contains("THE SOFTWARE IS PROVIDED"),
                  Self.normalized(credits).contains(license), credits.contains(name) else {
                throw MissingNotice(description: "Missing bundled license for editor package \(name)")
            }
        }
    }

    private func licenseFiles(in directory: String) throws -> [String] {
        var result: [String] = []
        for name in try fileService.listDirectory(at: directory).sorted() where name != ".git" {
            let path = directory + "/" + name
            if fileService.isSymlink(at: path) { continue }
            if fileService.directoryExists(at: path) {
                result += try licenseFiles(in: path)
            } else if name.range(of: "^(?:licen[sc]e|copying|notice)(?:[._-].*)?$",
                                 options: [.regularExpression, .caseInsensitive]) != nil {
                result.append(path)
            }
        }
        return result
    }
}
