import CryptoKit
import Foundation

/// The bundled document carries its original byte digest across Macs. Edits keep the version
/// marker but no longer match it; an unrelated same-named skill has neither this marker nor known bytes.
enum BundledSkillContent {
    private static let prefix = "pensieve-bundled: "
    private static let legacyDigest = "caab5f804aca0efdc3afa6655fde32b70ccfce37f458b05c4d5c2751ad2b1cc5"

    static func version(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("---\n") else { return nil }
        let header = text.components(separatedBy: "\n---").first ?? ""
        if let line = header.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }) {
            let value = String(line.dropFirst(prefix.count))
            if value.count == 64 && value.allSatisfy({ $0.isHexDigit }) { return value }
        }
        return digest(data) == legacyDigest ? legacyDigest : nil
    }

    static func isUnedited(_ data: Data) -> Bool {
        guard let version = version(data), let text = String(data: data, encoding: .utf8) else { return false }
        var original = text
        if let marker = original.range(of: prefix + version + "\n") { original.removeSubrange(marker) }
        return digest(Data(original.utf8)) == version
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
