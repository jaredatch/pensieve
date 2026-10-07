import Foundation

/// One bounded observation per path and phase. Retain the error so absence and an
/// uncheckable folder keep their distinct policies. A fresh phase uses a new instance.
final class ProjectFolderProbe {
    private let fileService: FileServiceProtocol
    private var results: [String: Result<Void, Error>] = [:]

    init(fileService: FileServiceProtocol) { self.fileService = fileService }

    func require(_ path: String) throws {
        let result = results[path] ?? Result { try fileService.requireProjectDirectory(at: path) }
        results[path] = result
        try result.get()
    }

    func isAvailable(_ path: String) -> Bool { (try? require(path)) != nil }
}
