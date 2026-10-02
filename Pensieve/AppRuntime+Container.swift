import SwiftData

extension AppRuntime {
    static func makeContainer(
        configuration: ModelConfiguration? = nil
    ) throws -> ModelContainer {
        let schema = Schema([
            Skill.self,
            Project.self,
            SkillProjectAssignment.self,
            ScenarioAssignment.self,
            DeployRecord.self,
            Category.self,
            Scenario.self,
            RepoUpdateCursor.self,
            MachineDeployIntent.self,
            IntentAssignment.self
        ])
        if let configuration {
            return try ModelContainer(for: schema, configurations: configuration)
        }
        return try ModelContainer(for: schema)
    }
}
