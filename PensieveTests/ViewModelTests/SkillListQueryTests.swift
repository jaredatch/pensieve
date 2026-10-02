import XCTest
@testable import Pensieve

final class SkillListQueryTests: XCTestCase {
    func testNameSortIsLocalizedCaseInsensitiveAndReversible() {
        let skills = [skill("skill-creator"), skill("Humanizer"), skill("basecamp")]
        let ascending = SkillListQuery.sorted(skills, by: .name, direction: .ascending)
        let descending = SkillListQuery.sorted(skills, by: .name, direction: .descending)

        XCTAssertEqual(ascending.map(\.name), ["basecamp", "Humanizer", "skill-creator"])
        XCTAssertEqual(descending.map(\.name), Array(ascending.map(\.name).reversed()))
    }

    func testDateSortsUseCreatedAndUpdated() {
        let alpha = skill("Alpha"), beta = skill("Beta")
        alpha.createdAt = Date(timeIntervalSince1970: 20)
        beta.createdAt = Date(timeIntervalSince1970: 10)
        alpha.updatedAt = Date(timeIntervalSince1970: 10)
        beta.updatedAt = Date(timeIntervalSince1970: 20)

        XCTAssertEqual(SkillListQuery.sorted([alpha, beta], by: .created, direction: .ascending).map(\.name),
                       ["Beta", "Alpha"])
        XCTAssertEqual(SkillListQuery.sorted([alpha, beta], by: .updated, direction: .descending).map(\.name),
                       ["Beta", "Alpha"])
    }

    func testDeployFilterUsesIndexAndIsIgnoredWhenUnavailable() {
        let alpha = skill("Alpha"), beta = skill("Beta"), gamma = skill("Gamma")
        let skills = [alpha, beta, gamma]
        let index = DeployIndex(records: [
            record(slug: alpha.directoryName, scope: "user", key: nil),
            record(slug: beta.directoryName, scope: "project", key: "project")
        ])

        XCTAssertEqual(apply(skills, filter: SkillListFilter(deploy: .deployed), index: index).map(\.name),
                       ["Alpha", "Beta"])
        XCTAssertEqual(apply(skills, filter: SkillListFilter(deploy: .notDeployed), index: index).map(\.name),
                       ["Gamma"])
        XCTAssertEqual(apply(skills, filter: SkillListFilter(deploy: .deployed), index: .unavailable).count, 3)
    }

    func testSourceFilter() {
        let linked = skill("Linked"), local = skill("Local")
        linked.installedOrigin = InstalledOrigin(
            repo: "https://github.com/example/skills", path: "skills/linked", ref: "main",
            installedCommit: "commit", installedTree: "tree", contentHash: "hash",
            installedAt: Date(), updatedAt: Date()
        )

        XCTAssertEqual(apply([linked, local], filter: SkillListFilter(source: .gitHub)).map(\.name), ["Linked"])
        XCTAssertEqual(apply([linked, local], filter: SkillListFilter(source: .local)).map(\.name), ["Local"])
    }

    func testEmptyInstalledOriginCountsAsLocal() {
        let skill = skill("Damaged")
        skill.installedOrigin = .empty

        XCTAssertEqual(apply([skill], filter: SkillListFilter(source: .local)).map(\.name), ["Damaged"])
        XCTAssertTrue(apply([skill], filter: SkillListFilter(source: .gitHub)).isEmpty)
    }

    func testTagsFilterIsAnyOf() {
        let alpha = skill("Alpha", tags: ["swift"])
        let beta = skill("Beta", tags: ["docs"])
        let gamma = skill("Gamma", tags: ["other"])

        let result = apply([alpha, beta, gamma], filter: SkillListFilter(tags: ["swift", "docs"]))
        XCTAssertEqual(result.map(\.name), ["Alpha", "Beta"])
    }

    func testCategoryFilterResolvesSlugsAndGroupsAnd() {
        let alpha = skill("Alpha", tags: ["swift"]), beta = skill("Beta", tags: ["docs"])
        let category = Pensieve.Category(name: "One")
        category.skillSlugs = [alpha.directoryName]

        var filter = SkillListFilter(categoryIDs: [category.id])
        XCTAssertEqual(apply([alpha, beta], filter: filter, categories: [category]).map(\.name), ["Alpha"])
        filter.tags = ["docs"]
        XCTAssertTrue(apply([alpha, beta], filter: filter, categories: [category]).isEmpty)
    }

    func testSearchMatchesNameDescriptionTagsTrimmedCaseInsensitive() {
        let name = skill("Needle Name")
        let description = skill("Description", description: "Has NEEDLE text")
        let tag = skill("Tag", tags: ["NeedleTag"])
        let other = skill("Other")
        let spec = SkillListSpec(search: "  needle ")

        XCTAssertEqual(SkillListQuery.apply([name, description, tag, other], spec: spec,
                                            deployIndex: .empty, categories: []).map(\.name),
                       ["Description", "Needle Name", "Tag"])
    }

    func testFilterIsActive() {
        XCTAssertFalse(SkillListFilter().isActive)
        XCTAssertTrue(SkillListFilter(deploy: .deployed).isActive)
        XCTAssertTrue(SkillListFilter(source: .gitHub).isActive)
        XCTAssertTrue(SkillListFilter(tags: ["swift"]).isActive)
        XCTAssertTrue(SkillListFilter(categoryIDs: [UUID()]).isActive)
    }

    func testStaleTagAndCategorySelectionsAreIgnored() {
        let alpha = skill("Alpha", tags: ["swift"]), beta = skill("Beta")
        let stale = SkillListFilter(tags: ["missing"], categoryIDs: [UUID()])
        XCTAssertEqual(apply([alpha, beta], filter: stale).count, 2)

        let mixed = SkillListFilter(tags: ["missing", "swift"])
        XCTAssertEqual(apply([alpha, beta], filter: mixed).map(\.name), ["Alpha"])
    }

    func testPrunedDropsUnknownTagsAndCategories() {
        let liveID = UUID(), staleID = UUID()
        let filter = SkillListFilter(deploy: .deployed, source: .gitHub,
                                     tags: ["live", "stale"], categoryIDs: [liveID, staleID])
        let pruned = filter.pruned(liveTags: ["live"], liveCategoryIDs: [liveID])

        XCTAssertEqual(pruned.deploy, .deployed)
        XCTAssertEqual(pruned.source, .gitHub)
        XCTAssertEqual(pruned.tags, ["live"])
        XCTAssertEqual(pruned.categoryIDs, [liveID])
        XCTAssertFalse(SkillListFilter(tags: ["stale"]).pruned(liveTags: [], liveCategoryIDs: []).isActive)
    }

    private func skill(_ name: String, description: String = "", tags: [String] = []) -> Skill {
        Skill(name: name, skillDescription: description, tags: tags, directoryName: name.lowercased())
    }

    private func apply(_ skills: [Skill], filter: SkillListFilter,
                       index: DeployIndex = .empty, categories: [Pensieve.Category] = []) -> [Skill] {
        SkillListQuery.apply(skills, spec: SkillListSpec(filter: filter), deployIndex: index, categories: categories)
    }

    private func record(slug: String, scope: String, key: String?) -> DeployStateRecord {
        DeployStateRecord(slug: slug, platform: PlatformTarget.claudeCode.rawValue, scope: scope,
                          projectIdentityKey: key, artifactPath: "/\(slug)", recordedAt: "2026-09-07T00:00:00Z")
    }
}
