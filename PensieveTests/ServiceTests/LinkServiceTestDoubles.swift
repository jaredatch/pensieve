import XCTest
@testable import Pensieve

enum LinkServiceScriptedSymlinkTarget {
    case canonical
    case retargeted
    case unavailable
}

struct LinkServiceScriptedPathState {
    let isSymlink: Bool
    let fileExists: Bool
    let directoryExists: Bool
    let symlinkTarget: LinkServiceScriptedSymlinkTarget

    static let missing = LinkServiceScriptedPathState(
        isSymlink: false, fileExists: false, directoryExists: false, symlinkTarget: .unavailable)
    static let realDirectory = LinkServiceScriptedPathState(
        isSymlink: false, fileExists: false, directoryExists: true, symlinkTarget: .unavailable)
    static let realFile = LinkServiceScriptedPathState(
        isSymlink: false, fileExists: true, directoryExists: false, symlinkTarget: .unavailable)
    static let validDirectorySymlink = LinkServiceScriptedPathState(
        isSymlink: true, fileExists: false, directoryExists: true, symlinkTarget: .canonical)
    static let retargetedDirectorySymlink = LinkServiceScriptedPathState(
        isSymlink: true, fileExists: false, directoryExists: true, symlinkTarget: .retargeted)
    static let brokenSymlink = LinkServiceScriptedPathState(
        isSymlink: true, fileExists: false, directoryExists: false, symlinkTarget: .canonical)
}

enum LinkServiceScriptedError: Error {
    case symlinkTargetUnavailable
}

final class LinkServiceScriptedFileService: FileServiceProtocol {
    private let linkPath: String
    private let canonicalDirectory: String
    private let state: LinkServiceScriptedPathState

    private(set) var createSymlinkCalled = false
    private(set) var deleteFileCalled = false
    private(set) var directoryProbePaths: [String] = []
    private(set) var entryTypeProbeCount = 0
    var failRepeatedEntryProbe = false

    init(
        linkPath: String,
        canonicalDirectory: String,
        state: LinkServiceScriptedPathState
    ) {
        self.linkPath = linkPath
        self.canonicalDirectory = canonicalDirectory
        self.state = state
    }

    func readFile(at path: String) throws -> String { "" }
    func readData(at path: String) throws -> Data {
        XCTFail("Scripted double does not support readData: \(path)")
        throw CocoaError(.fileReadUnknown)
    }
    func writeFile(at path: String, content: String) throws {}
    func writeExecutableFile(at path: String, content: String) throws {
        XCTFail("Scripted double does not support writeExecutableFile: \(path)")
        throw CocoaError(.fileWriteUnknown)
    }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        XCTFail("Scripted double does not support copyFile: \(sourcePath) -> \(destinationPath)")
        throw CocoaError(.fileWriteUnknown)
    }
    func deleteFile(at path: String) throws { deleteFileCalled = true }
    func fileExists(at path: String) -> Bool { path == linkPath && state.fileExists }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        guard path == linkPath else { return path == canonicalDirectory ? .directory : nil }
        entryTypeProbeCount += 1
        if failRepeatedEntryProbe && entryTypeProbeCount > 1 { throw CocoaError(.fileReadUnknown) }
        if state.isSymlink { return .symlink }
        if state.directoryExists { return .directory }
        return state.fileExists ? .regular : nil
    }
    func isExecutableFile(at path: String) -> Bool { false }
    func isUserExecutableFile(at path: String) -> Bool {
        XCTFail("Scripted double does not support isUserExecutableFile: \(path)")
        return false
    }
    func directoryExists(at path: String) -> Bool {
        path == canonicalDirectory || (path == linkPath && state.directoryExists)
    }
    func createDirectory(at path: String) throws {}
    func directoryExistsFollowingLinks(at path: String) throws -> Bool {
        directoryProbePaths.append(path)
        return path != linkPath
    }
    func createDirectoryWithoutParents(at path: String) throws {}
    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws {
        try createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        createSymlinkCalled = true
    }
    func symlinkTarget(at path: String) throws -> String {
        guard path == linkPath else { throw LinkServiceScriptedError.symlinkTargetUnavailable }
        switch state.symlinkTarget {
        case .canonical:
            return canonicalDirectory
        case .retargeted:
            return "/outside/retargeted"
        case .unavailable:
            throw LinkServiceScriptedError.symlinkTargetUnavailable
        }
    }
    func isSymlink(at path: String) -> Bool { path == linkPath && state.isSymlink }
    func isRegularFile(at path: String) -> Bool {
        XCTFail("Scripted double does not support isRegularFile: \(path)")
        return false
    }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "" }
}

/// Sandbox contract (PLAN-22 / 22.4): with `physicalSandbox` set, every path-bearing
/// PROTOCOL REQUIREMENT routes through translation + containment; ancestor symlinks are
/// resolved before containment; escapes record XCTFail and are quarantined under one fixed
/// sandbox child. Deliberately NOT defended: `replaceItem` (extension-only, statically
/// dispatched — uninterceptable by any conformer — and unreachable from LinkService, the
/// only production consumer of this seam); fixtures planted by tests through the RAW
/// FileService, which bypass this double knowingly.
final class LinkServiceCanonicalDirectoryFileService: FileServiceProtocol {
    private let wrapped: FileServiceProtocol
    private let pathMappings: [(logical: String, physical: String)]
    private let physicalSandbox: String?
    /// Checkpoints act on translated sandbox paths immediately before their real FileService operation.
    var beforeDirectoryCreation: ((String) throws -> Void)?
    var beforeArtifactCreation: ((String) throws -> Void)?
    var beforeProjectProbe: ((String) throws -> Void)?
    var beforeRuleRead: ((String) throws -> Void)?
    var beforeSymlinkRead: ((String) throws -> Void)?
    /// Physical-path consumers compare physical literals; containment still applies to every lookup.
    var translatesSymlinkTargets = true

    init(
        wrapped: FileServiceProtocol,
        canonicalDirectory: String,
        substituteDirectory: String
    ) {
        self.wrapped = wrapped
        pathMappings = [(canonicalDirectory, substituteDirectory)]
        physicalSandbox = nil
    }

    init(
        wrapped: FileServiceProtocol,
        pathMappings: [(logical: String, physical: String)],
        physicalSandbox: String? = nil
    ) {
        self.wrapped = wrapped
        self.pathMappings = pathMappings.sorted { $0.logical.count > $1.logical.count }
        self.physicalSandbox = physicalSandbox
    }

    private func physicalPath(for logicalPath: String) -> String {
        for mapping in pathMappings
        where logicalPath == mapping.logical || logicalPath.hasPrefix(mapping.logical + "/") {
            return mapping.physical + logicalPath.dropFirst(mapping.logical.count)
        }
        return logicalPath
    }

    private func logicalPath(for physicalPath: String) -> String {
        for mapping in pathMappings
        where physicalPath == mapping.physical || physicalPath.hasPrefix(mapping.physical + "/") {
            return mapping.logical + physicalPath.dropFirst(mapping.physical.count)
        }
        return physicalPath
    }

    private func containmentSpelling(_ path: String) -> String {
        let ns = path as NSString
        let parentComponents = (ns.deletingLastPathComponent as NSString).pathComponents
        guard let firstComponent = parentComponents.first else {
            return path
        }
        var resolvedParent = firstComponent
        for component in parentComponents.dropFirst() {
            resolvedParent = (resolvedParent as NSString).appendingPathComponent(component)
            resolvedParent = (resolvedParent as NSString).resolvingSymlinksInPath
        }
        let leaf = ns.lastPathComponent
        return resolvedParent + "/" + leaf
    }

    private func resolved(_ path: String) -> String {
        let physical = physicalPath(for: path)
        guard let sandbox = physicalSandbox else {
            return physical
        }
        let lexicalLeaf = physical.split(separator: "/", omittingEmptySubsequences: true).last
        let containmentPhysical = containmentSpelling(physical)
        let resolvedSandbox = (sandbox as NSString).resolvingSymlinksInPath
        guard lexicalLeaf != ".", lexicalLeaf != ".." else {
            XCTFail("Hermeticity violation: unmapped path escaped the test sandbox: \(path) -> \(physical)")
            return resolvedSandbox + "/hermeticity-quarantine"
        }
        guard containmentPhysical != resolvedSandbox,
              !containmentPhysical.hasPrefix(resolvedSandbox + "/") else {
            return physical
        }
        XCTFail("Hermeticity violation: unmapped path escaped the test sandbox: \(path) -> \(physical)")
        return resolvedSandbox + "/hermeticity-quarantine"
    }

    func readFile(at path: String) throws -> String {
        try wrapped.readFile(at: resolved(path))
    }
    func readData(at path: String) throws -> Data {
        try wrapped.readData(at: resolved(path))
    }
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        let physical = resolved(path)
        try beforeRuleRead?(physical)
        return try wrapped.readRegularFileData(at: physical, maximumBytes: maximumBytes)
    }
    func readRegularFileHeader(at path: String, maximumBytes: Int) throws -> Data {
        let physical = resolved(path)
        try beforeRuleRead?(physical)
        return try wrapped.readRegularFileHeader(at: physical, maximumBytes: maximumBytes)
    }
    func writeFile(at path: String, content: String) throws {
        try wrapped.writeFile(at: resolved(path), content: content)
    }
    func writeExecutableFile(at path: String, content: String) throws {
        try wrapped.writeExecutableFile(at: resolved(path), content: content)
    }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        try wrapped.copyFile(at: resolved(sourcePath), to: resolved(destinationPath))
    }
    func deleteFile(at path: String) throws {
        try wrapped.deleteFile(at: resolved(path))
    }
    func fileExists(at path: String) -> Bool {
        wrapped.fileExists(at: resolved(path))
    }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        try wrapped.entryExistsWithoutFollowingLinks(at: resolved(path))
    }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        try wrapped.entryTypeWithoutFollowingLinks(at: resolved(path))
    }
    func isExecutableFile(at path: String) -> Bool {
        wrapped.isExecutableFile(at: resolved(path))
    }
    func isUserExecutableFile(at path: String) -> Bool {
        wrapped.isUserExecutableFile(at: resolved(path))
    }
    func directoryExists(at path: String) -> Bool {
        wrapped.directoryExists(at: resolved(path))
    }
    func directoryExistsFollowingLinks(at path: String) throws -> Bool {
        let physical = resolved(path)
        try beforeProjectProbe?(physical)
        return try wrapped.directoryExistsFollowingLinks(at: physical)
    }
    func createDirectoryWithoutParents(at path: String) throws {
        let physical = resolved(path)
        try beforeDirectoryCreation?(physical)
        try wrapped.createDirectoryWithoutParents(at: physical)
    }
    func writeFileWithoutParents(at path: String, content: String) throws {
        let physical = resolved(path)
        try beforeArtifactCreation?(physical)
        try wrapped.writeFileWithoutParents(at: physical, content: content)
    }
    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws {
        let physical = resolved(linkPath)
        try beforeArtifactCreation?(physical)
        try wrapped.createSymlinkWithoutParents(at: physical, pointingTo: resolved(targetPath))
    }
    func createDirectory(at path: String) throws {
        try wrapped.createDirectory(at: resolved(path))
    }
    func deleteDirectory(at path: String) throws {
        try wrapped.deleteDirectory(at: resolved(path))
    }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        let physical = resolved(linkPath)
        try beforeArtifactCreation?(physical)
        try wrapped.createSymlink(
            at: physical,
            pointingTo: resolved(targetPath))
    }
    func symlinkTarget(at path: String) throws -> String {
        let physical = resolved(path)
        try beforeSymlinkRead?(physical)
        let target = try wrapped.symlinkTarget(at: physical)
        return translatesSymlinkTargets ? logicalPath(for: target) : target
    }
    func isSymlink(at path: String) -> Bool {
        wrapped.isSymlink(at: resolved(path))
    }
    func isRegularFile(at path: String) -> Bool {
        wrapped.isRegularFile(at: resolved(path))
    }
    func listDirectory(at path: String) throws -> [String] {
        try wrapped.listDirectory(at: resolved(path))
    }
    func contentsHash(at path: String) throws -> String {
        try wrapped.contentsHash(at: resolved(path))
    }
}

struct LinkServiceScriptedContext {
    let service: LinkService
    let fileService: LinkServiceScriptedFileService
    let projectPath: String
}
