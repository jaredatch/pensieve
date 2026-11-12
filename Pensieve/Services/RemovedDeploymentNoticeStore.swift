import Foundation

struct RemovedDeploymentNoticeEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    let slug: String
    let projectName: String
    let projectPath: String
    let platform: PlatformTarget

    func matches(_ other: Self) -> Bool {
        slug == other.slug && projectName == other.projectName
            && projectPath == other.projectPath && platform == other.platform
    }
}

protocol RemovedDeploymentNoticeStoring {
    func read() throws -> [RemovedDeploymentNoticeEntry]
    func write(_ entries: [RemovedDeploymentNoticeEntry]) throws
}

/// A this-Mac-only message file. The app's main-actor model is its only writer and reads it once.
struct RemovedDeploymentNoticeStore: RemovedDeploymentNoticeStoring {
    private struct State: Codable {
        var schemaVersion = 1
        let entries: [RemovedDeploymentNoticeEntry]
    }

    private let fileService: FileServiceProtocol
    private let path: String

    init(fileService: FileServiceProtocol, appSupportDir: String) {
        self.fileService = fileService
        path = appSupportDir + "/removed-deployment-notices.json"
    }

    func read() throws -> [RemovedDeploymentNoticeEntry] {
        guard let type = try fileService.entryTypeWithoutFollowingLinks(at: path) else { return [] }
        guard type == .regular else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let state = try decoder.decode(State.self, from: fileService.readData(at: path))
        guard state.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return state.entries
    }

    func write(_ entries: [RemovedDeploymentNoticeEntry]) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(State(entries: entries))
        try fileService.writeData(at: path, data: data)
    }
}
