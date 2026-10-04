import CryptoKit
import Foundation
@testable import Pensieve

/// Audits dependency notices with a wide filename net and reviewed exemptions.
/// Candidates contain license/licence (including licensing), copying, copyright or
/// notice. Source/script/data extensions and symlinks are excluded. Complete text is
/// required unless the package-relative path has an explicit single-line exemption.
/// Notices hidden in source comments are outside this discovery.
struct NoticeInventory {
    struct MissingNotice: Error, CustomStringConvertible {
        let description: String
    }

    let fileService: FileServiceProtocol
    struct LicenseExemption {
        let package: String
        let path: String
        let reason: String
    }
    // Add reviewed non-attribution candidates here: package, checkout-relative path, reason.
    static let licenseExemptions: [LicenseExemption] = [
        LicenseExemption(package: "sparkle", path: "Tests/Resources/SparkleTestCodeSignApp.enc.nolicense.dmg",
                         reason: "Encrypted unarchiver test fixture; excluded from Sparkle's shipped binary target.")
    ]
    let exemptions: [LicenseExemption]

    init(fileService: FileServiceProtocol, exemptions: [LicenseExemption] = Self.licenseExemptions) {
        self.fileService = fileService
        self.exemptions = exemptions
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @discardableResult
    func checkSwiftPackages(resolved: String, checkouts: String,
                            notices: NoticeDocument, credits: String) throws -> [[String: Any]] {
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
                let relative = String(path.dropFirst(root.count + 1))
                if exemptions.contains(where: {
                    $0.package.lowercased() == identity.lowercased() && $0.path == relative
                        && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !$0.reason.contains(where: \.isNewline)
                }) { continue }
                let license: String
                do {
                    license = Self.normalized(try fileService.readFile(at: path))
                } catch {
                    throw MissingNotice(description: "Unreadable license candidate: \(identity)/\(relative): \(error)")
                }
                guard !license.isEmpty, bundled.contains(license) else {
                    throw MissingNotice(description: "Missing bundled license: \(identity)/\(relative)")
                }
            }
        }
        return pins
    }

    func checkEditorPackages(lockfile: String, notices: NoticeDocument, credits: String) throws {
        let json = try JSONSerialization.jsonObject(with: fileService.readData(at: lockfile)) as? [String: Any]
        guard let packages = json?["packages"] as? [String: [String: Any]] else {
            throw MissingNotice(description: "Invalid editor package-lock.json")
        }
        let bundled = Self.normalized(credits)
        for path in packages.keys.sorted() where !path.isEmpty && packages[path]?["dev"] as? Bool != true {
            let name = path.components(separatedBy: "node_modules/").last ?? path
            guard let entries = notices.editorEntries[name] else {
                throw MissingNotice(description: "Missing notice for editor package \(name)")
            }
            let version = packages[path]?["version"] as? String ?? "<missing>"
            guard version != "<missing>", let entry = entries.first(where: { $0.version == version }) else {
                throw MissingNotice(description: "Version mismatch for editor package \(name): "
                                    + "lockfile \(version), notice \(entries.map(\.version).joined(separator: ", "))")
            }
            guard let body = entry.license, packages[path]?["license"] as? String == "MIT" else {
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

    private static let excludedExtensions: Set<String> = [
        "swift", "c", "h", "m", "mm", "cpp", "py", "sh", "js", "ts", "go", "rb", "json", "yml", "yaml", "plist", "xml"
    ]

    private func licenseFiles(in directory: String) throws -> [String] {
        var result: [String] = []
        for name in try fileService.listDirectory(at: directory).sorted() where name != ".git" {
            let path = directory + "/" + name
            let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
            if fileService.isSymlink(at: path) { continue }
            if fileService.directoryExists(at: path) {
                result += try licenseFiles(in: path)
            } else if !Self.excludedExtensions.contains(suffix),
                      name.range(of: "licen[sc](?:e|ing)|copying|copyright|notice",
                                 options: [.regularExpression, .caseInsensitive]) != nil {
                result.append(path)
            }
        }
        return result
    }
}

/// Yams omits a separate libYAML license file. Keep the vendor version and upstream
/// notice digest together so changing Yams requires rechecking that vendored notice.
struct LibYAMLNoticeAudit {
    static let yamsVersion = "6.2.2"
    // yaml/libyaml 0.2.5's complete License, normalized only for whitespace.
    static let digest = "6cc0c393c5cb002fce678ab4f5e7642c58fdb32f9e7ee27ada2ef111df5ac021"

    static func checkVendorVersion(pins: [[String: Any]]) throws {
        guard let pin = pins.first(where: { ($0["identity"] as? String)?.lowercased() == "yams" }) else {
            throw NoticeInventory.MissingNotice(description: "Stale libYAML notice: Yams is no longer resolved; "
                                                + "remove its notice or audit the new vendor")
        }
        let version = (pin["state"] as? [String: Any])?["version"] as? String ?? "<missing>"
        guard version == yamsVersion else {
            throw NoticeInventory.MissingNotice(description: "Recheck libYAML notice for Swift package yams \(version); "
                                                + "audited Yams version is \(yamsVersion)")
        }
    }

    static func noticeDigest(_ license: String) -> String {
        SHA256.hash(data: Data(NoticeInventory.normalized(license).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
