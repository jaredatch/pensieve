import Foundation
@testable import Pensieve

extension FileServiceProtocol {
    /// Test doubles model empty/absent directories without host I/O. Nonempty sources require
    /// an explicit implementation, including their source-validation receipt.
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws -> RegularFileCopyReceipt {
        guard !isSymlink(at: source), directoryExists(at: source) else {
            return RegularFileCopyReceipt(validateSource: {})
        }
        guard try listDirectory(at: source).isEmpty else { throw CocoaError(.featureUnsupported) }
        return RegularFileCopyReceipt(validateSource: {})
    }
}
