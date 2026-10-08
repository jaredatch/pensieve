import Foundation

/// Process path resolution shared by the app and the SwiftData-free daemon. Only this value
/// selects the live home and Keychain; other constructors receive its paths and credentials.
struct RuntimePaths {
    let storeRoot: String
    let appSupportDir: String
    let homeDirectory: String
    let deployPaths: DeployPaths
    let isProduction: Bool
    let credentialStore: CredentialStoreProtocol

    init(storeRoot: String, appSupportDir: String) {
        self.storeRoot = storeRoot
        self.appSupportDir = appSupportDir
        isProduction = storeRoot == PathConstants.pensieveBaseDir
            && appSupportDir == PathConstants.pensieveAppSupportDir
        homeDirectory = isProduction ? PathConstants.homeDirectory : appSupportDir + "/home"
        let userRoots: [PlatformTarget: String]
        if isProduction {
            userRoots = [
                .claudeCode: PathConstants.claudeCodeUserSkillsDir,
                .grok: PathConstants.grokUserSkillsDir,
                .codex: PathConstants.codexUserSkillsDir,
                .openClaw: PathConstants.openClawUserSkillsDir,
                .hermes: PathConstants.hermesUserSkillsDir + "/" + PathConstants.hermesDefaultCategory
            ]
        } else {
            userRoots = Dictionary(uniqueKeysWithValues: PlatformTarget.allCases.filter(\.usesSymlinks).map {
                ($0, appSupportDir + "/agent-skills/" + $0.rawValue)
            })
        }
        deployPaths = DeployPaths(skillsDirectory: storeRoot + "/skills", userSkillsDirectories: userRoots,
            cursorUserRulesDirectory: isProduction ? PathConstants.cursorUserRulesDir : appSupportDir + "/cursor-rules")
        credentialStore = isProduction ? KeychainCredentialStore() : InMemoryCredentialStore()
    }

    static let production = RuntimePaths(storeRoot: PathConstants.pensieveBaseDir,
                                         appSupportDir: PathConstants.pensieveAppSupportDir)
    var skillsDir: String { deployPaths.skillsDirectory }
    var syncLockPath: String { appSupportDir + "/sync.lock" }
    var gitAskpassHelperPath: String { appSupportDir + "/git-askpass.sh" }

    func makeGitService(fileService: FileServiceProtocol = FileService()) -> GitService {
        GitService(fileService: fileService, askpassHelperPath: gitAskpassHelperPath)
    }

    func makeDeployReconciler(fileService: FileServiceProtocol = FileService()) -> DeployReconciler {
        DeployReconciler(fileService: fileService,
            deployState: DeployStateStore(fileService: fileService, appSupportDir: appSupportDir),
            pensieveSkillsDir: skillsDir, agentSkillDirs: DeployReconciler.agentSkillDirs(paths: deployPaths),
            cursorRulesDir: deployPaths.cursorUserRulesDirectory)
    }
}
