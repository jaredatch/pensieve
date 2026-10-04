import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol PreviewImageLoading {
    func loadImage(at url: URL, skillDirectory: String?, budget: PreviewImageBudgeting?) throws -> CGImage
}

enum PreviewImageError: Error {
    case blocked, invalidImage
}

/// Has no network transport. Only embedded image bytes and bounded regular files inside the
/// caller's skill directory reach ImageIO. The file service checks containment on the opened inode.
struct PreviewImageLoader: PreviewImageLoading {
    static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumDimension = 2_048
    static let maximumSourceDimension = 16_384
    static let maximumPixels = 25_000_000
    private static let allowedTypes = Set([UTType.png, .jpeg, .gif, .webP, .heic].map(\.identifier))
    private let fileService: FileServiceProtocol
    private let decode: (CGImageSource) -> CGImage?

    init(fileService: FileServiceProtocol = FileService(), decode: ((CGImageSource) -> CGImage?)? = nil) {
        self.fileService = fileService
        self.decode = decode ?? Self.thumbnail
    }

    /// The one relative-URL rule, shared by document previews and direct loader callers.
    /// Filesystem admission remains in localPath and the contained descriptor read.
    static func resolvedURL(_ url: URL, skillDirectory: String?, documentRelativePath: String = "SKILL.md") -> URL? {
        guard url.scheme == nil else { return url }
        guard let skillDirectory else { return nil }
        // Standardize the existing root, not the possibly missing leaf, before resolving it.
        let root = URL(fileURLWithPath: skillDirectory, isDirectory: true).standardizedFileURL
        let document = URL(fileURLWithPath: root.path + "/" + documentRelativePath)
        return URL(string: url.relativeString, relativeTo: document.deletingLastPathComponent())?.absoluteURL
    }

    func loadImage(at url: URL, skillDirectory: String?, budget: PreviewImageBudgeting? = nil) throws -> CGImage {
        try budget?.checkAvailable()
        let data: Data
        if url.scheme?.lowercased() == "data" {
            data = try embeddedData(url)
        } else {
            let path = try localPath(url, skillDirectory: skillDirectory)
            guard let skillDirectory else { throw PreviewImageError.blocked }
            data = try fileService.readRegularFileData(at: path, maximumBytes: Self.maximumBytes,
                                                      containedIn: skillDirectory)
        }
        guard data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), Self.allowedTypes.contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= Self.maximumSourceDimension, height.intValue <= Self.maximumSourceDimension,
              width.intValue <= Self.maximumPixels / height.intValue else { throw PreviewImageError.invalidImage }
        let pixels = width.intValue * height.intValue
        try budget?.reserve(pixels)
        guard let image = decode(source) else { throw PreviewImageError.invalidImage }
        return image
    }

    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
    }

    private func localPath(_ url: URL, skillDirectory: String?) throws -> String {
        guard let skillDirectory, skillDirectory.hasPrefix("/"),
              url.scheme == nil || url.scheme?.lowercased() == "file",
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw PreviewImageError.blocked
        }
        let directory = URL(fileURLWithPath: skillDirectory, isDirectory: true)
        guard let safeDirectory = SkillStore.safeSkillDirectory(
            slug: directory.lastPathComponent, base: directory.deletingLastPathComponent().path,
            fileService: fileService
        ) else { throw PreviewImageError.blocked }
        let root = URL(fileURLWithPath: safeDirectory, isDirectory: true).standardizedFileURL
        guard let resolved = Self.resolvedURL(url, skillDirectory: root.path) else { throw PreviewImageError.blocked }
        let path = resolved.standardizedFileURL.path
        guard !path.contains("\0"), path.hasPrefix(root.path + "/") else { throw PreviewImageError.blocked }
        return path
    }

    private func embeddedData(_ url: URL) throws -> Data {
        let encoded = url.absoluteString
        let base64Limit = ((Self.maximumBytes + 2) / 3) * 4
        guard encoded.utf8.count <= base64Limit * 3 + 256,
              let comma = encoded.firstIndex(of: ",") else { throw PreviewImageError.invalidImage }
        let header = encoded[encoded.index(encoded.startIndex, offsetBy: 5)..<comma].lowercased()
        let fields = header.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.first?.hasPrefix("image/") == true else { throw PreviewImageError.blocked }
        let isBase64 = fields.last == "base64"
        let payload = encoded[encoded.index(after: comma)...]
        let bytes = try percentDecodedBytes(payload, limit: isBase64 ? base64Limit : Self.maximumBytes)
        if isBase64 {
            guard let data = Data(base64Encoded: bytes), data.count <= Self.maximumBytes else {
                throw PreviewImageError.invalidImage
            }
            return data
        }
        return bytes
    }

    private func percentDecodedBytes(_ text: Substring, limit: Int) throws -> Data {
        let bytes = Array(text.utf8)
        var decoded = Data()
        var index = 0
        while index < bytes.count {
            guard decoded.count < limit else { throw PreviewImageError.invalidImage }
            if bytes[index] == 37 {
                guard index + 2 < bytes.count,
                      let high = hexDigit(bytes[index + 1]), let low = hexDigit(bytes[index + 2]) else {
                    throw PreviewImageError.invalidImage
                }
                decoded.append(high * 16 + low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }

    private func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
