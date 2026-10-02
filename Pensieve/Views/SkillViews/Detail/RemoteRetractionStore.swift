import Observation

struct RemoteDeployKey: Hashable {
    let machineID: String
    let skillSlug: String
    let platformRaw: String
    let projectKey: String?

    init(_ intent: MachineDeployIntent) {
        machineID = intent.machineID
        skillSlug = intent.skillSlug
        platformRaw = intent.platformRaw
        projectKey = intent.projectKey
    }

    init(machineID: String, skillSlug: String, platformRaw: String, projectKey: String?) {
        self.machineID = machineID
        self.skillSlug = skillSlug
        self.platformRaw = platformRaw
        self.projectKey = projectKey
    }
}

@Observable
final class RemoteRetractionStore {
    private(set) var held: Set<RemoteDeployKey> = []
    @ObservationIgnored private var published: Set<RemoteDeployKey> = []
    @ObservationIgnored private var seenWhileHeld: Set<RemoteDeployKey> = []

    func recordRetraction(_ key: RemoteDeployKey) {
        held.insert(key)
        if published.contains(key) {
            seenWhileHeld.insert(key)
        }
    }

    func recordIntent(_ key: RemoteDeployKey) {
        held.remove(key)
        seenWhileHeld.remove(key)
    }

    func observe(_ states: [MachineState]) {
        let statesByID = Dictionary(states.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        let currentPublished = Set(states.flatMap(Self.deployKeys))
        var nextHeld = held
        for key in held {
            guard statesByID[key.machineID] != nil else { continue }
            if currentPublished.contains(key) {
                seenWhileHeld.insert(key)
            } else if seenWhileHeld.remove(key) != nil {
                nextHeld.remove(key)
            }
        }
        published = currentPublished
        if nextHeld != held { held = nextHeld }
    }

    private static func deployKeys(_ state: MachineState) -> [RemoteDeployKey] {
        state.userDeploys.map {
            RemoteDeployKey(
                machineID: state.machineID, skillSlug: $0.slug,
                platformRaw: $0.platform, projectKey: nil
            )
        } + state.projectDeploys.map {
            RemoteDeployKey(
                machineID: state.machineID, skillSlug: $0.slug,
                platformRaw: $0.platform, projectKey: $0.projectKey
            )
        }
    }
}
