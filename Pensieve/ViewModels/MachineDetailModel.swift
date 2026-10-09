import Foundation

struct MachineObservabilityDependencies {
    let stateService: MachineStateServicing
    let identity: MachineIdentityProviding
    let root: String
    let now: () -> Date

}

@Observable
final class MachineDetailModel {
    struct ProjectSummary: Equatable, Identifiable {
        let identityKey: String
        let kind: String
        let name: String

        var id: String { identityKey }
    }

    struct AgentSummary: Equatable, Identifiable {
        let rawValue: String
        let name: String
        let iconName: String

        var id: String { rawValue }
    }

    struct DeploySummary: Equatable, Identifiable {
        let id: String
        let skillSlug: String
        let displaySkillSlug: String
        let platformName: String
        let projectName: String?
        let projectKey: String?
    }

    let machineID: String
    let name: String
    let appVersion: String
    let publishedAt: Date
    let isLocalMachine: Bool
    let agents: [AgentSummary]
    let registeredHereProjects: [ProjectSummary]
    let onlyOnMachineProjects: [ProjectSummary]
    let userDeploys: [DeploySummary]
    let projectDeploys: [DeploySummary]

    @ObservationIgnored private let now: () -> Date

    init(
        state: MachineState,
        localProjectIdentityKeys: Set<String>,
        localMachineID: String?,
        now: @escaping () -> Date
    ) {
        machineID = state.machineID
        name = PublishedStringSanitizer.name(state.name, fallback: "Mac")
        appVersion = PublishedStringSanitizer.name(state.appVersion, fallback: "Unknown")
        publishedAt = state.publishedAt
        isLocalMachine = state.machineID == localMachineID
        agents = Self.agentSummaries(state.agents)
        let projects = Self.projectSummaries(state.projects)
        registeredHereProjects = projects.filter { localProjectIdentityKeys.contains($0.identityKey) }
        onlyOnMachineProjects = projects.filter { !localProjectIdentityKeys.contains($0.identityKey) }
        userDeploys = Self.userDeploySummaries(state.userDeploys)
        projectDeploys = Self.projectDeploySummaries(state.projectDeploys, projects: state.projects)
        self.now = now
    }

    var secondsSinceLastUpdated: TimeInterval {
        max(0, now().timeIntervalSince(publishedAt))
    }

    var currentDate: Date { now() }

    var lastUpdatedText: String {
        lastUpdatedText(relativeTo: now())
    }

    func lastUpdatedText(relativeTo date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .standalone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let relative = formatter.localizedString(for: publishedAt, relativeTo: date)
        return "Last updated \(relative)"
    }
}

private extension MachineDetailModel {
    static func projectSummary(_ project: MachineStateProject) -> ProjectSummary {
        ProjectSummary(
            identityKey: project.identityKey,
            kind: project.kind,
            name: PublishedStringSanitizer.projectName(project.name, identityKey: project.identityKey)
        )
    }

    static func projectSummaries(_ projects: [MachineStateProject]) -> [ProjectSummary] {
        var unique: [String: ProjectSummary] = [:]
        for project in projects where unique[project.identityKey] == nil {
            unique[project.identityKey] = projectSummary(project)
        }
        return unique.values.sorted { ($0.name, $0.identityKey) < ($1.name, $1.identityKey) }
    }

    static func agentSummaries(_ agents: [String]) -> [AgentSummary] {
        Set(agents).sorted().map { rawValue in
            guard let platform = PlatformTarget(rawValue: rawValue) else {
                return AgentSummary(
                    rawValue: rawValue,
                    name: PublishedStringSanitizer.name(rawValue, fallback: "Agent"),
                    iconName: "gearshape"
                )
            }
            return AgentSummary(rawValue: rawValue, name: platform.displayName, iconName: platform.iconName)
        }
    }

    static func userDeploySummaries(_ deploys: [MachineStateUserDeploy]) -> [DeploySummary] {
        let summaries = deploys.map { deploy in
            DeploySummary(
                id: "user|\(deploy.slug)|\(deploy.platform)",
                skillSlug: deploy.slug,
                displaySkillSlug: PublishedStringSanitizer.name(deploy.slug, fallback: "Skill"),
                platformName: platformName(deploy.platform),
                projectName: nil,
                projectKey: nil
            )
        }
        return uniqueDeploys(summaries)
    }

    static func projectDeploySummaries(
        _ deploys: [MachineStateProjectDeploy],
        projects: [MachineStateProject]
    ) -> [DeploySummary] {
        let names = Dictionary(projects.map {
            ($0.identityKey, PublishedStringSanitizer.projectName($0.name, identityKey: $0.identityKey))
        }, uniquingKeysWith: { first, _ in first })
        let summaries = deploys.map { deploy in
            DeploySummary(
                id: "project|\(deploy.projectKey)|\(deploy.slug)|\(deploy.platform)",
                skillSlug: deploy.slug,
                displaySkillSlug: PublishedStringSanitizer.name(deploy.slug, fallback: "Skill"),
                platformName: platformName(deploy.platform),
                projectName: names[deploy.projectKey]
                    ?? PublishedStringSanitizer.projectName("", identityKey: deploy.projectKey),
                projectKey: deploy.projectKey
            )
        }
        return uniqueDeploys(summaries)
    }

    static func platformName(_ rawValue: String) -> String {
        PlatformTarget(rawValue: rawValue)?.displayName
            ?? PublishedStringSanitizer.name(rawValue, fallback: "Agent")
    }

    static func uniqueDeploys(_ deploys: [DeploySummary]) -> [DeploySummary] {
        var unique: [String: DeploySummary] = [:]
        for deploy in deploys where unique[deploy.id] == nil {
            unique[deploy.id] = deploy
        }
        return unique.values.sorted { $0.id < $1.id }
    }
}
