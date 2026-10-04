import Darwin
import Foundation

extension FileService {
    func checkDirectoryReadable(at path: String) throws {
        guard let directory = opendir(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        closedir(directory)
    }
}
