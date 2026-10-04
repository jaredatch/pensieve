import Foundation

/// Complete image data for decoder admission tests, generated without committed image assets.
enum PreviewImagePolicyFixtures {
    static let webP = Data([
        0x52, 0x49, 0x46, 0x46, 0x1C, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x4C, 0x0F, 0x00, 0x00, 0x00, 0x2F, 0x1F, 0xC0, 0x05,
        0x00, 0x07, 0x10, 0xFD, 0x8F, 0xFE, 0x07, 0x22, 0xA2, 0xFF, 0x01, 0x00
    ])

    static func png(width: Int, height: Int) throws -> Data {
        var header = Data()
        appendBigEndian(UInt32(width), to: &header)
        appendBigEndian(UInt32(height), to: &header)
        header.append(contentsOf: [8, 2, 0, 0, 0])
        // Every RGB sample and row filter is zero. Foundation returns raw DEFLATE, so add
        // the zlib header and Adler-32 checksum required by PNG's IDAT stream.
        let samples = Data(repeating: 0, count: (width * 3 + 1) * height)
        var compressed = Data([0x78, 0x01])
        compressed.append(try (samples as NSData).compressed(using: .zlib) as Data)
        appendBigEndian(UInt32(samples.count % 65_521) << 16 | 1, to: &compressed)
        var image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        image.append(chunk("IHDR", data: header))
        image.append(chunk("IDAT", data: compressed))
        image.append(chunk("IEND", data: Data()))
        return image
    }

    private static func chunk(_ type: String, data: Data) -> Data {
        let payload = Data(type.utf8) + data
        var chunk = Data()
        appendBigEndian(UInt32(data.count), to: &chunk)
        chunk.append(payload)
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in payload {
            checksum = checksum >> 8 ^ crcTable[Int((checksum ^ UInt32(byte)) & 0xFF)]
        }
        appendBigEndian(checksum ^ 0xFFFF_FFFF, to: &chunk)
        return chunk
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                 UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : value >> 1 ^ 0xEDB8_8320 }
        return value
    }
}
