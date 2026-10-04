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

    func checkDirectoryReadable(at path: String) throws {
        guard let directory = opendir(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        defer { closedir(directory) }
        guard access(path, R_OK | X_OK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
    }
}
