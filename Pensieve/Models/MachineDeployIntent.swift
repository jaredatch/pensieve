import SwiftData

@Model
final class MachineDeployIntent {
    @Attribute(.unique) var key: String
    var machineID: String
    var skillSlug: String
    var platformRaw: String
    var projectKey: String?

    init(machineID: String, skillSlug: String, platformRaw: String, projectKey: String? = nil) {
        self.key = Self.makeKey(
            machineID: machineID,
            skillSlug: skillSlug,
            platformRaw: platformRaw,
            projectKey: projectKey
        )
        self.machineID = machineID
        self.skillSlug = skillSlug
        self.platformRaw = platformRaw
        self.projectKey = projectKey
    }

    static func makeKey(
        machineID: String,
        skillSlug: String,
        platformRaw: String,
        projectKey: String?
    ) -> String {
        let userWideKey = machineID + "|" + skillSlug + "|" + platformRaw
        guard let projectKey else { return userWideKey }
        return userWideKey + "|" + projectKey
    }
}
