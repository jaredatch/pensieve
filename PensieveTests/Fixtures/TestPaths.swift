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
        MachineStateService(agentDetection: AgentDetectionService(homeDirectory: homeDirectory),
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
