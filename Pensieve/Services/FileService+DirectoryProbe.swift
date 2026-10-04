import Darwin
import Foundation

extension FileService {
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
