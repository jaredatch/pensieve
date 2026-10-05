import Foundation

enum DeployArtifactOccupant { case absent, owned, foreign }

enum ArtifactOwnershipError: LocalizedError {
    case occupiedPath(String)
    case couldNotCheck(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .occupiedPath(let path):
            "An artifact Pensieve does not own already exists at \(path). "
                + "Pensieve will not overwrite it — move or delete it, then deploy again."
        case .couldNotCheck(let path, let reason):
            "Could not check ownership at \(path): \(reason). Nothing was changed."
        }
    }
}

protocol DeployArtifactOwnershipChecking {
    func link(at path: String, skillsDirectory: String, linksFile: Bool) throws -> DeployArtifactOccupant
    func cursor(at path: String, legacyContent: () throws -> String) throws -> DeployArtifactOccupant
}

/// Classifies the leaf before any deploy mutation. Stored deployment history supplies no authority.
/// Like the existing deploy writers, the check and mutation are path-based; concurrent same-user
/// replacement between those operations is outside the filesystem threat model.
struct DeployArtifactOwnership: DeployArtifactOwnershipChecking {
    static let maximumHeaderBytes = 64 * 1_024
    let fileService: FileServiceProtocol

    func link(at path: String, skillsDirectory: String, linksFile: Bool) throws -> DeployArtifactOccupant {
        try checked(at: path) {
            guard let type = try fileService.entryTypeWithoutFollowingLinks(at: path) else { return .absent }
            guard type == .symlink else { return .foreign }
            let target = try fileService.symlinkTarget(at: path)
            return Self.ownsLinkTarget(target, skillsDirectory: skillsDirectory, linksFile: linksFile) ? .owned : .foreign
        }
    }

    static func ownsLinkTarget(_ target: String, skillsDirectory: String, linksFile: Bool) -> Bool {
        let prefix = skillsDirectory + "/"
        guard skillsDirectory.hasPrefix("/"), target.hasPrefix(prefix) else { return false }
        let components = target.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == (linksFile ? 2 : 1),
              let name = components.first, !name.isEmpty, name != ".", name != ".." else { return false }
        return !linksFile || components.last == "SKILL.md"
    }

    func cursor(at path: String, legacyContent: () throws -> String) throws -> DeployArtifactOccupant {
        try checked(at: path) {
            guard let type = try fileService.entryTypeWithoutFollowingLinks(at: path) else { return .absent }
            guard type == .regular else { return .foreign }
            let header = try fileService.readRegularFileHeader(at: path, maximumBytes: Self.maximumHeaderBytes)
            if CursorMDC.hasOwnershipMark(in: header) { return .owned }
            let expected = Data(try legacyContent().utf8)
            do {
                let current = try fileService.readRegularFileData(at: path, maximumBytes: expected.count)
                return current == expected ? .owned : .foreign
            } catch let error as CocoaError where error.code == .fileReadTooLarge {
                return .foreign
            }
        }
    }

    private func checked(at path: String, _ operation: () throws -> DeployArtifactOccupant) throws -> DeployArtifactOccupant {
        do { return try operation() } catch {
            throw ArtifactOwnershipError.couldNotCheck(path: path, reason: error.localizedDescription)
        }
    }
}
