import XCTest
import SwiftData
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

final class CategoryStoreTests: XCTestCase {
    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func categoryCount(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<PensieveCategory>()).count
    }

    @MainActor
    func testCreateInsertsTrimmedCategoryAndRejectsBlankName() throws {
        let context = try makeContext()
        let store = CategoryStore()

        XCTAssertEqual(try categoryCount(in: context), 0)

        let category = try XCTUnwrap(store.create(name: "  Backend  ", context: context))

        XCTAssertEqual(category.name, "Backend")
        XCTAssertEqual(try categoryCount(in: context), 1)
        XCTAssertNil(store.create(name: "   ", context: context))
        XCTAssertEqual(try categoryCount(in: context), 1)
    }

    @MainActor
    func testRenameChangesName() throws {
        let context = try makeContext()
        let store = CategoryStore()
        let category = try XCTUnwrap(store.create(name: "Backend", context: context))

        store.rename(category, to: "Frontend", context: context)

        XCTAssertEqual(category.name, "Frontend")
    }

    @MainActor
    func testSetProjectUsesIdentityKeyAndIsIdempotent() throws {
        let context = try makeContext()
        let store = CategoryStore()
        let category = try XCTUnwrap(store.create(name: "Backend", context: context))
        let project = Project(name: "P1", path: "/tmp/p1")
        project.identityKey = "git:github.com/me/p1"
        context.insert(project)

        store.setProject(project, inCategory: category, member: true, context: context)
        store.setProject(project, inCategory: category, member: true, context: context)

        XCTAssertEqual(category.projectKeys, ["git:github.com/me/p1"])
        XCTAssertNotEqual(category.projectKeys.first, project.id.uuidString)

        store.setProject(project, inCategory: category, member: false, context: context)

        XCTAssertTrue(category.projectKeys.isEmpty)
    }

    @MainActor
    func testSetProjectWithPendingIdentityIsNoOp() throws {
        let context = try makeContext()
        let store = CategoryStore()
        let category = try XCTUnwrap(store.create(name: "Backend", context: context))
        let project = Project(name: "Pending", path: "/tmp/pending")
        context.insert(project)

        store.setProject(project, inCategory: category, member: true, context: context)

        XCTAssertEqual(category.projectKeys.count, 0)
    }

    @MainActor
    func testSetSkillUsesDirectoryNameAndIsIdempotent() throws {
        let context = try makeContext()
        let store = CategoryStore()
        let category = try XCTUnwrap(store.create(name: "Backend", context: context))
        let skill = Skill(name: "Review", directoryName: "review")
        context.insert(skill)

        store.setSkill(skill, inCategory: category, assigned: true, context: context)
        store.setSkill(skill, inCategory: category, assigned: true, context: context)

        XCTAssertEqual(category.skillSlugs, ["review"])

        store.setSkill(skill, inCategory: category, assigned: false, context: context)

        XCTAssertTrue(category.skillSlugs.isEmpty)
    }

    @MainActor
    func testCategoriesContainingProjectKeyFiltersCategories() throws {
        let context = try makeContext()
        let store = CategoryStore()
        let backend = try XCTUnwrap(store.create(name: "Backend", context: context))
        let frontend = try XCTUnwrap(store.create(name: "Frontend", context: context))
        let project = Project(name: "P1", path: "/tmp/p1")
        project.identityKey = "git:github.com/me/p1"
        context.insert(project)

        store.setProject(project, inCategory: backend, member: true, context: context)

        let matches = store.categories(containingProjectKey: "git:github.com/me/p1", context: context)

        XCTAssertEqual(matches.map(\.name), ["Backend"])
        XCTAssertFalse(matches.contains { $0.name == frontend.name })
    }

    @MainActor
    func testCategoriesContainingSkillSlugFiltersCategories() throws {
        let context = try makeContext()
        let store = CategoryStore()
        let backend = try XCTUnwrap(store.create(name: "Backend", context: context))
        let frontend = try XCTUnwrap(store.create(name: "Frontend", context: context))
        let skill = Skill(name: "Review", directoryName: "review")
        context.insert(skill)

        store.setSkill(skill, inCategory: frontend, assigned: true, context: context)

        let matches = store.categories(containingSkillSlug: "review", context: context)

        XCTAssertEqual(matches.map(\.name), ["Frontend"])
        XCTAssertFalse(matches.contains { $0.name == backend.name })
    }
}
