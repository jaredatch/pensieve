import Foundation
import SwiftData
@testable import Pensieve

struct InertMachineIdentity: MachineIdentityProviding {
    static let value = "00000000-0000-4000-8000-000000000001"

    func identifier() throws -> String { Self.value }
}

struct FixedMachineIdentity: MachineIdentityProviding {
    let value: String
    func identifier() throws -> String { value }
}

struct EmptyMachineDetection: AgentDetectionServiceProtocol {
    func isInstalled(_ platform: PlatformTarget) -> Bool { false }
    func installedPlatforms() -> [PlatformTarget] { [] }
}

struct InertMachineStateService: MachineStateServicing {
    func compose(machineID: String, context: ModelContext, publishedAt: Date) throws -> MachineState {
        MachineState(schemaVersion: 1, machineID: machineID, name: "Test Mac", appVersion: "test",
                     publishedAt: publishedAt, agents: [], projects: [], userDeploys: [], projectDeploys: [])
    }

    func write(_ state: MachineState, toRoot root: String) throws {}
    func readAll(fromRoot root: String) -> [MachineState] { [] }
}
