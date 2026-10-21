import Foundation
@testable import Pensieve

/// Explicit neutral paths for unit doubles whose operation never needs a disk fixture. Integration
/// tests continue to pass their owned temporary directories. No value here resolves a live location.
enum TestPaths {
    static let root = TestTemporaryDirectory.path + "NeutralDependencies-" + UUID().uuidString
    static let storeRoot = root + "/.pensieve"
    static let appSupportDir = root + "/support"
    static let homeDirectory = root + "/home"
    static let skillsDir = storeRoot + "/skills"
    static let syncLockPath = appSupportDir + "/sync.lock"
    static var gitAskpassHelperPath: String { appSupportDir + "/git-askpass.sh" }
    static let git = GitService(askpassHelperPath: appSupportDir + "/git-askpass.sh")
    static let deployPaths = DeployPaths(skillsDirectory: skillsDir,
        userSkillsDirectories: [.claudeCode: homeDirectory + "/.claude/skills", .grok: homeDirectory + "/.grok/skills",
            .codex: homeDirectory + "/.codex/skills", .openClaw: homeDirectory + "/.openclaw/skills",
            .hermes: homeDirectory + "/.hermes/skills/pensieve"],
        cursorUserRulesDirectory: homeDirectory + "/.cursor/rules")
    static let scanner = ImportScanner(fileService: FileService(),
        claudeSkillsDir: root + "/claude", grokSkillsDir: root + "/grok", cursorRulesDir: root + "/cursor",
        codexSkillsDir: root + "/codex", storeRoot: storeRoot)
    static var engine: SyncEngine { SyncEngine(gitService: git, lockPath: syncLockPath) }
    static var stateService: MachineStateService {
        MachineStateService(agentDetection: AgentDetectionService(homeDirectory: homeDirectory,
            applicationsDirectory: homeDirectory + "/Applications"),
            deployState: { DeployState(schemaVersion: DeployStateStore.currentSchemaVersion, records: []) },
            homeDirectory: homeDirectory)
    }
    static func linkService(fileService: FileServiceProtocol) -> LinkService {
        LinkService(fileService: fileService, paths: deployPaths)
    }

    static func cursorCompiler(fileService: FileServiceProtocol) -> CursorCompiler {
        CursorCompiler(fileService: fileService,
            skillStore: SkillStore(fileService: fileService, baseDir: skillsDir, storeRoot: skillsDir),
            userRulesDirectory: deployPaths.cursorUserRulesDirectory)
    }

    static var backfillPaths: DeployStateBackfillPaths {
        DeployStateBackfillPaths(pensieveSkillsDir: skillsDir, cursorUserRulesDir: deployPaths.cursorUserRulesDirectory,
            userSkillsRoot: deployPaths.userSkillsRoot)
    }
}

/// Matches a publisher's temporary entry or one of its children using the real store namespace.
struct TestStoreTemporary {
    let parent: String
    private let prefix: String

    init(root: String, files: FileServiceProtocol, kind: String = "vendor") throws {
        let location = try VendorTemporaryDirectory.namespace(storeRoot: root, fileService: files, kind: kind)
        parent = location.parent
        prefix = location.prefix
    }

    func paths(files: FileServiceProtocol) throws -> [String] {
        guard files.directoryExists(at: parent) else { return [] }
        return try files.listDirectory(at: parent).map { parent + "/" + $0 }.filter { contains($0) }
    }

    func contains(_ path: String) -> Bool {
        guard path.hasPrefix(parent + "/") else { return false }
        let relative = path.dropFirst(parent.count + 1)
        guard let name = relative.split(separator: "/").first else { return false }
        return VendorTemporaryDirectory.contains(String(name), prefix: prefix)
    }
}
