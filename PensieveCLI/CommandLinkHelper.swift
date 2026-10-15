import Foundation

/// The authorization runner invokes this narrow operation in a separate process. It has no app,
/// store, socket or launch behavior. Fixture runners invoke the same operation without elevation.
enum CommandLinkHelper {
    static func run(_ encoded: String, files: FileServiceProtocol) -> Int32 {
        do {
            guard let bytes = Data(base64Encoded: encoded) else { throw CocoaError(.coderReadCorrupt) }
            let request = try JSONDecoder().decode(CommandLinkRequest.self, from: bytes)
            try files.changeCommandLink(request)
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }
}
