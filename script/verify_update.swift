// Public-key-only verification of an already published Sparkle archive.
// This tool never reads a signing key or writes an archive.
import CryptoKit
import Foundation

do {
    let args = CommandLine.arguments
    guard args.count == 5, let length = UInt64(args[2]),
          let signature = Data(base64Encoded: args[3]), signature.count == 64,
          let key = Data(base64Encoded: args[4]), key.count == 32 else {
        throw NSError(domain: "Invalid length, EdDSA signature or public key", code: 1)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
    guard UInt64(data.count) == length else {
        throw NSError(domain: "Published DMG length does not match appcast", code: 1)
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    guard publicKey.isValidSignature(signature, for: data) else {
        throw NSError(domain: "Published DMG EdDSA signature does not match appcast", code: 1)
    }
} catch {
    fputs("release: \(error)\n", stderr)
    exit(1)
}
