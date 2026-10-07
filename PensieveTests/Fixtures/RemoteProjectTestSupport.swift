import Foundation
@testable import Pensieve

enum RemoteProjectTestSupport {
    static let key = "github.com/example/workspace"
    static let publishedAt = Date(timeIntervalSince1970: 1_000_000)

    static func project(key: String = key, name: String = "Workspace",
                        kind: String = "remote", path: String? = "~/Projects/workspace") -> MachineStateProject {
        MachineStateProject(identityKey: key, kind: kind, name: name, path: path)
    }

    static func machine(id: String = "remote", name: String = "Mac mini",
                        projects: [MachineStateProject] = [project()],
                        deploys: [MachineStateProjectDeploy] = [],
                        publishedAt: Date = publishedAt) -> MachineState {
        MachineState(schemaVersion: 1, machineID: id, name: name, appVersion: "1.0",
                     publishedAt: publishedAt, agents: [], projects: projects,
                     userDeploys: [MachineStateUserDeploy(slug: "user-only", platform: "codex")],
                     projectDeploys: deploys)
    }

    static func deploy(_ slug: String, platform: String = "codex", key: String = key) -> MachineStateProjectDeploy {
        MachineStateProjectDeploy(slug: slug, platform: platform, projectKey: key)
    }
}
