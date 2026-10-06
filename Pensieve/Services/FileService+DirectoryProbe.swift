import Darwin
import Foundation

extension FileService {
    func realPath(at path: String) -> String {
        (try? resolveRealPath(at: path)) ?? path
    }

    func resolveRealPath(at path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
