import XCTest
@testable import Pensieve

final class RelatedSkillsTests: XCTestCase {
    func testForCategoryReturnsAssignedSkills() {
        let assigned = Skill(name: "Assigned", directoryName: "assigned")
        let unrelated = Skill(name: "Unrelated", directoryName: "unrelated")
        let category = Category(name: "Work")
        category.skillSlugs = [assigned.directoryName]

        let result = RelatedSkills.forCategory(category, in: [assigned, unrelated])

        XCTAssertEqual(result.map(\.directoryName), ["assigned"])
    }

    func testForCategoryWithNoSlugsReturnsEmpty() {
        let category = Category(name: "Empty")
        let skill = Skill(name: "Unrelated", directoryName: "unrelated")

        XCTAssertTrue(RelatedSkills.forCategory(category, in: [skill]).isEmpty)
    }

    func testForTagReturnsTaggedSkills() {
        let tagged = Skill(name: "Tagged", tags: ["swift"], directoryName: "tagged")
        let unrelated = Skill(name: "Unrelated", tags: ["writing"], directoryName: "unrelated")

        let result = RelatedSkills.forTag("swift", in: [tagged, unrelated])

        XCTAssertEqual(result.map(\.directoryName), ["tagged"])
    }

    func testForTagWithNoMatchReturnsEmpty() {
        let skill = Skill(name: "Unrelated", tags: ["writing"], directoryName: "unrelated")

        XCTAssertTrue(RelatedSkills.forTag("swift", in: [skill]).isEmpty)
    }

    func testResolveFindsSkillBySlug() {
        let expected = Skill(name: "Expected", directoryName: "expected")
        let unrelated = Skill(name: "Unrelated", directoryName: "unrelated")

        XCTAssertEqual(RelatedSkills.resolve(slug: "expected", in: [unrelated, expected])?.id, expected.id)
    }

    func testResolveReturnsNilForUnknownSlug() {
        let skill = Skill(name: "Known", directoryName: "known")

        XCTAssertNil(RelatedSkills.resolve(slug: "unknown", in: [skill]))
    }

    func testRelatedSkillsOrderingSortsNumericNamesNaturally() {
        let two = Skill(name: "Skill 2", directoryName: "skill-2")
        let ten = Skill(name: "Skill 10", directoryName: "skill-10")

        let result = [ten, two].relatedSkillsOrdered()

        XCTAssertEqual(result.map(\.directoryName), ["skill-2", "skill-10"])
    }

    func testRelatedSkillsOrderingBreaksNameTiesByDirectoryName() {
        let first = Skill(name: "Same Name", directoryName: "same-name-a")
        let second = Skill(name: "Same Name", directoryName: "same-name-b")

        let result = [second, first].relatedSkillsOrdered()

        XCTAssertEqual(result.map(\.directoryName), ["same-name-a", "same-name-b"])
    }
}
