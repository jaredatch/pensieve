import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

private struct ReadFailureStubError: LocalizedError {
    let errorDescription: String? = "stub failure"
}

private struct ReadFailureCategoryReconciler: CategoryReconcilerProtocol {
    func reconcile(context: ModelContext) -> BatchResult {
        BatchResult.readFailure("deploy intent ownership", error: ReadFailureStubError())
    }
}

private struct ReadFailureScenarioReconciler: ScenarioReconcilerProtocol {
    func reconcile(context: ModelContext) -> BatchResult { BatchResult() }
}

private final class ReadFailureSkillStore: SkillStoreProtocol {
    private(set) var deletedDirectoryNames: [String] = []

    func createSkill(name: String, description: String, body: String) throws -> String { "created" }
    func readBody(directoryName: String) throws -> String { "" }
    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        return SkillRewriteResult(content: body, didWrite: true)
    }
    func writeBody(directoryName: String, body: String) throws {}

    func deleteSkill(directoryName: String) throws {
        deletedDirectoryNames.append(directoryName)
    }

    func listSkills() throws -> [String] { [] }
}

extension CategoryReconcileWiringTests {
    @MainActor
    func testDeleteSkillCountsReadFailureWithoutCallingItADeployFailure() throws {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            IntentAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let skill = Skill(name: "Skill S", directoryName: "skill-s")
        context.insert(skill)
        try context.save()
        let skillStore = ReadFailureSkillStore()
        let library = SkillLibraryViewModel(skillStore: skillStore)

        let result = library.deleteSkill(
            skill,
            context: context,
            categoryReconciler: ReadFailureCategoryReconciler(),
            scenarioReconciler: ReadFailureScenarioReconciler()
        )

        XCTAssertEqual(result, .retainedReconcileFailed(failures: 1))
        XCTAssertTrue(library.error?.contains("couldn't read deploy intent ownership") == true)
        XCTAssertFalse(library.error?.localizedCaseInsensitiveContains("deploy(s) failed") == true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 1)
        XCTAssertTrue(skillStore.deletedDirectoryNames.isEmpty)
    }
}
