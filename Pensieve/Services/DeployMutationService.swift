import Foundation
import Observation
import SwiftData

struct DeployIntentMachine: Identifiable, Equatable {
    let id: String
    let name: String
    let isLocal: Bool
    let isUnseen: Bool
}

struct DeployIntentDependencies {
    let identity: MachineIdentityProviding
    let stateService: MachineStateServicing
    let root: String
    let manifestService: ManifestSnapshotting
    let fetchIntents: (ModelContext) throws -> [MachineDeployIntent]
    let writeManifest: (ModelContext) throws -> Void
    let saveContext: (ModelContext) throws -> Void
    let notifier: SyncStateNotifying
    let reconcile: @MainActor (ModelContext) -> BatchResult
    let reconcileSelection: (@MainActor ([DeployMutationPair], ModelContext) -> BatchResult)?
    let lockPath: String
    let lockProvider: (String) -> SyncLock?
    let remoteRetractions: RemoteRetractionStore

    init(
        identity: MachineIdentityProviding,
        stateService: MachineStateServicing,
        root: String,
        manifestService: ManifestSnapshotting = ManifestService(),
        fetchIntents: @escaping (ModelContext) throws -> [MachineDeployIntent] = {
            try $0.fetch(FetchDescriptor<MachineDeployIntent>())
        },
        writeManifest: @escaping (ModelContext) throws -> Void,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        notifier: @escaping SyncStateNotifying,
        reconcile: @escaping @MainActor (ModelContext) -> BatchResult = { _ in BatchResult() },
        reconcileSelection: (@MainActor ([DeployMutationPair], ModelContext) -> BatchResult)? = nil,
        lockPath: String,
        lockProvider: @escaping (String) -> SyncLock? = { SyncLock.tryAcquire(at: $0) },
        remoteRetractions: RemoteRetractionStore = RemoteRetractionStore()
    ) {
        self.identity = identity
        self.stateService = stateService
        self.root = root
        self.manifestService = manifestService
        self.fetchIntents = fetchIntents
        self.writeManifest = writeManifest
        self.saveContext = saveContext
        self.notifier = notifier
        self.reconcile = reconcile
        self.reconcileSelection = reconcileSelection
        self.lockPath = lockPath
        self.lockProvider = lockProvider
        self.remoteRetractions = remoteRetractions
    }

    static func live(
        identity: MachineIdentityProviding,
        stateService: MachineStateServicing,
        root: String,
        lockPath: String,
        notifier: @escaping SyncStateNotifying,
        reconcile: @escaping @MainActor (ModelContext) -> BatchResult,
        reconcileSelection: (@MainActor ([DeployMutationPair], ModelContext) -> BatchResult)? = nil,
        remoteRetractions: RemoteRetractionStore = RemoteRetractionStore()
    ) -> Self {
        let manifestService = ManifestService()
        return Self(
            identity: identity,
            stateService: stateService,
            root: root,
            manifestService: manifestService,
            writeManifest: { context in
                try manifestService.write(try manifestService.snapshot(from: context), toRoot: root)
            },
            notifier: notifier,
            reconcile: reconcile,
            reconcileSelection: reconcileSelection,
            lockPath: lockPath,
            remoteRetractions: remoteRetractions
        )
    }
}

enum DeployIntentApplyOutcome {
    case intentOnly
    case localDeploy(BatchResult)
}

enum DeployIntentModelError: LocalizedError {
    case invalidComponent(String)
    case remoteTargetIsThisMac
    case syncInProgress
    case selectionChanged
    case ingestPending

    var errorDescription: String? {
        switch self {
        case let .invalidComponent(value):
            "Invalid deploy intent component: \(value)"
        case .remoteTargetIsThisMac:
            "This Mac must use its local deployment controls."
        case .syncInProgress:
            "Sync is running. Try again when it finishes."
        case .ingestPending:
            "Deployment couldn't update this Mac's library. Try deploying again."
        case .selectionChanged:
            "A selected skill was removed while the library updated. Choose the skills again."
        }
    }
}

enum DeployIntentPersistenceError: LocalizedError {
    case manifestRestoreFailed(save: Error, restore: Error)

    var errorDescription: String? {
        switch self {
        case let .manifestRestoreFailed(save, restore):
            "Saving deployment intent failed (\(save.localizedDescription)), and the restore of its manifest failed "
                + "(\(restore.localizedDescription))."
        }
    }
}

@MainActor
protocol DeployMutationServicing: AnyObject {
    var platformVM: PlatformViewModel { get }
    var dependencies: DeployIntentDependencies { get }
    var machines: [DeployIntentMachine] { get }
    var availablePlatforms: [PlatformTarget] { get }
    func reload(context: ModelContext) throws
    func targetCatalog(context: ModelContext, localID: String) throws -> DeployTargetCatalog
    func selectedMachineIDs(skills: [Skill], platforms: Set<PlatformTarget>, context: ModelContext) throws -> Set<String>
    func setRemote(_ selected: Bool, machineID: String, projectKey: String?, skill: Skill,
                   platform: PlatformTarget, context: ModelContext) throws
    func set(_ selected: Bool, skill: Skill, platform: PlatformTarget, target: DeployTarget,
             context: ModelContext) throws -> BatchResult
    func setProjectSelection(_ selected: Bool, skills: [Skill], platforms: Set<PlatformTarget>,
                             project: Project, context: ModelContext) throws -> DeployIntentApplyOutcome
    func setSelected(_ selected: Bool, machineID: String, skill: Skill, platform: PlatformTarget,
                     context: ModelContext) throws -> BatchResult?
    func apply(skills: [Skill], platforms: Set<PlatformTarget>, selectedMachineIDs: Set<String>,
               context: ModelContext) throws -> DeployIntentApplyOutcome
    func retract(skills: [Skill], platforms: Set<PlatformTarget>, machineIDs: Set<String>,
                 context: ModelContext) throws -> DeployIntentApplyOutcome
    func change(_ selected: Bool, pairs: [DeployMutationPair], dryRun: Bool,
                context: ModelContext) throws -> DeployMutationReport
}

@MainActor
@Observable
final class DeployMutationService: DeployMutationServicing {
    let platformVM: PlatformViewModel
    let dependencies: DeployIntentDependencies

    private(set) var machines: [DeployIntentMachine] = []
    private(set) var availablePlatforms: [PlatformTarget] = []

    init(platformVM: PlatformViewModel, dependencies: DeployIntentDependencies) {
        self.platformVM = platformVM
        self.dependencies = dependencies
    }

    func reload(context: ModelContext) throws {
        let catalog = try targetCatalog(context: context, localID: dependencies.identity.identifier())
        machines = catalog.machines
        let remoteRaws = catalog.states.flatMap(\.agents) + catalog.intents.filter { $0.projectKey == nil }.map(\.platformRaw)
        let remotePlatforms = remoteRaws.compactMap(PlatformTarget.init(rawValue:))
        let localPlatforms = platformVM.deployablePlatforms(forProject: false)
        let admitted = Set(localPlatforms + remotePlatforms)
        availablePlatforms = PlatformTarget.allCases.filter(admitted.contains)
    }

    func selectedMachineIDs(
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        context: ModelContext
    ) throws -> Set<String> {
        let slugs = Set(skills.map(\.directoryName))
        let platformRaws = Set(platforms.map(\.rawValue))
        let rows = try dependencies.fetchIntents(context)
        return Set(rows.compactMap { row in
            row.projectKey == nil && slugs.contains(row.skillSlug) && platformRaws.contains(row.platformRaw)
                ? row.machineID : nil
        })
    }
}
