import CryptoKit
import Foundation
@testable import Pensieve

/// The audit reads one CRLF-normalized document. Only exact LF-delimited text fences
/// enclose licenses; page breaks and other Unicode separators remain part of the text.
struct NoticeDocument {
    struct LicenseBlock {
        let range: Range<String.Index>
        let text: String
    }

    let text: String
    let licenseBlocks: [LicenseBlock]

    init(_ source: String) throws {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        text = normalized
        let expression = try NSRegularExpression(pattern: "(?:\\A|(?<=\\n))```text\\n(.*?)\\n```(?=\\n|\\z)",
                                                 options: .dotMatchesLineSeparators)
        let matches = expression.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
        licenseBlocks = matches.compactMap { match in
            guard let range = Range(match.range, in: normalized),
                  let body = Range(match.range(at: 1), in: normalized) else { return nil }
            return LicenseBlock(range: range, text: String(normalized[body]))
        }
    }

    func license(after position: String.Index) -> String? {
        licenseBlocks.first { $0.range.lowerBound >= position }?.text
    }

    func license(inSection heading: String) -> String? {
        guard let range = text.range(of: heading + "\n") else { return nil }
        return license(after: range.upperBound)
    }
}

/// Yams omits a separate libYAML license file. Keep the vendor version and upstream
/// notice digest together so changing Yams requires rechecking that vendored notice.
struct LibYAMLNoticeAudit {
    static let yamsVersion = "6.2.2"
    // yaml/libyaml 0.2.5's complete License, normalized only for whitespace.
    static let digest = "6cc0c393c5cb002fce678ab4f5e7642c58fdb32f9e7ee27ada2ef111df5ac021"

    static func checkVendorVersion(resolved: String, fileService: FileServiceProtocol) throws {
        let json = try JSONSerialization.jsonObject(with: fileService.readData(at: resolved)) as? [String: Any]
        let pin = (json?["pins"] as? [[String: Any]])?.first { ($0["identity"] as? String)?.lowercased() == "yams" }
        let version = (pin?["state"] as? [String: Any])?["version"] as? String ?? "<missing>"
        guard version == yamsVersion else {
            throw NoticeInventory.MissingNotice(description: "Recheck libYAML notice for Swift package yams \(version); "
                                                + "audited Yams version is \(yamsVersion)")
        }
    }

    static func noticeDigest(_ license: String) -> String {
        SHA256.hash(data: Data(NoticeInventory.normalized(license).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
