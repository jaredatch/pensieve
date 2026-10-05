import Foundation

enum DeployArtifactOccupant {
    case absent, owned, legacy, foreign, foreignLink
    var isOwned: Bool { self == .owned || self == .legacy }
}

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
    func cursor(at path: String, legacyContent: (() throws -> String)?) throws -> DeployArtifactOccupant
    func cursorRuleMayExist(at path: String) throws -> Bool
}

/// Classifies the leaf before any deploy mutation. Stored deployment history supplies no authority.
/// Like the existing deploy writers, the check and mutation are path-based; concurrent same-user
/// replacement between those operations is outside the filesystem threat model.
struct DeployArtifactOwnership: DeployArtifactOwnershipChecking {
    static let maximumHeaderBytes = 64 * 1_024
    let fileService: FileServiceProtocol

    func link(at path: String, skillsDirectory: String, linksFile: Bool) throws -> DeployArtifactOccupant {
        try checked(at: path) {
            guard let type = try leafType(at: path) else { return .absent }
            guard type == .symlink else { return .foreign }
            let target = try fileService.symlinkTarget(at: path)
            return Self.ownsLinkTarget(target, skillsDirectory: skillsDirectory, linksFile: linksFile) ? .owned : .foreignLink
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

    /// Metadata only: an absent or non-regular entry cannot need Cursor deployment history.
    func cursorRuleMayExist(at path: String) throws -> Bool {
        try checked(at: path) { try leafType(at: path) == .regular }
    }

    func cursor(at path: String, legacyContent: (() throws -> String)?) throws -> DeployArtifactOccupant {
        try checked(at: path) {
            guard let type = try leafType(at: path) else { return .absent }
            guard type == .regular else { return .foreign }
            let header = try fileService.readRegularFileHeader(at: path, maximumBytes: Self.maximumHeaderBytes)
            if CursorMDC.hasOwnershipMark(in: header) { return .owned }
            // Missing source is not evidence of ownership. A mark never needs the source.
            guard let legacyContent, let legacy = try? legacyContent() else { return .foreign }
            let expected = Data(legacy.utf8)
            do {
                let current = try fileService.readRegularFileData(at: path, maximumBytes: expected.count)
                return current == expected ? .legacy : .foreign
            } catch let error as CocoaError where error.code == .fileReadTooLarge {
                return .foreign
            }
        }
    }

    private func leafType(at path: String) throws -> FileEntryType? {
        do { return try fileService.entryTypeWithoutFollowingLinks(at: path) } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOTDIR) {
            return nil
        }
    }

    private func checked<Value>(at path: String, _ operation: () throws -> Value) throws -> Value {
        do { return try operation() } catch {
            throw ArtifactOwnershipError.couldNotCheck(path: path, reason: error.localizedDescription)
        }
    }
}
