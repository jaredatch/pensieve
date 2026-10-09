import SwiftData
import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func testBodyAndOverlayForOneSlugGroupIntoOneSkillCard() async throws {
        let context = try makeContext()
        context.insert(Skill(name: "Deploy Helper", directoryName: "deploy-helper"))
        try context.save()
        let engine = StubResolutionEngine()
        engine.inspections = [.conflicts(ConflictSet(items: [
            bodyItem(slug: "deploy-helper"),
            overlayItem(slug: "deploy-helper")
        ]))]
        let model = makeModel(engine: engine)

        await model.loadAndReport(context: context)

        let groups = try readyGroups(from: model.phase)
        XCTAssertEqual(groups.count, 1, "body + overlay for the same slug must be one pickable group")
        XCTAssertEqual(groups[0].id, "skill:deploy-helper")
        XCTAssertEqual(groups[0].title, "Deploy Helper")
        XCTAssertEqual(groups[0].subtitle, "Body and settings differ")
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertFalse(model.canApply)
        try await assertDistinctEntityNamespaces()
    }

    func testUnknownSkillSlugFallsBackToSlugTitle() async throws {
        let history = try ConflictHistoryFixture(test: self)
        defer { try? history.remove() }
        await history.runtime.bootstrapTask.value
        try await assertEquivalentRowsDoNotTrap()
        let context = try makeContext()
        let engine = StubResolutionEngine()
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "new-skill")]))]
        let model = makeModel(engine: engine)

        await model.loadAndReport(context: context)

        let group = try XCTUnwrap(readyGroups(from: model.phase).first)
        XCTAssertEqual(group.title, "new-skill")
        let degenerate: [(String, ConflictKind)] = [
            ("skills/SKILL.md", .body), ("skills//SKILL.md", .body),
            ("skills/./SKILL.md", .body), ("skills/../SKILL.md", .body),
            ("manifest/skills/.yaml", .overlay), ("manifest/skills/", .overlay)
        ]
        context.insert(Skill(name: "Empty slug must not match", directoryName: ""))
        try context.save()
        for (path, kind) in degenerate {
            engine.inspections = [.conflicts(ConflictSet(items: [
                ConflictItem(path: path, kind: kind, thisMachine: nil, otherMachine: nil)
            ]))]
            await model.loadAndReport(context: context)
            let fallback = try XCTUnwrap(readyGroups(from: model.phase).first)
            XCTAssertEqual(fallback.id, (kind == .body ? "body-path:" : "overlay-path:") + path)
            XCTAssertEqual(fallback.title, path)
            if kind == .body { await assertHistoryAction(path: path, slug: "", available: false, fixture: history) }
        }
    }

    func assertDistinctEntityNamespaces() async throws {
        let context = try makeContext()
        context.insert(Skill(name: "Projects Skill", directoryName: "projects"))
        try context.save()
        let engine = StubResolutionEngine()
        let registry = ConflictItem(path: "manifest/projects.yaml", kind: .project,
                                    thisMachine: nil, otherMachine: nil)
        let fallback = ConflictItem(path: "projects", kind: .body, thisMachine: nil, otherMachine: nil)
        let mismatch = ConflictItem(path: registry.path, kind: .body, thisMachine: nil, otherMachine: nil)
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "projects"), registry, fallback, mismatch]))]
        let model = makeModel(engine: engine)
        await model.loadAndReport(context: context)
        let groups = try readyGroups(from: model.phase)
        XCTAssertEqual(groups.map(\.id), ["skill:projects", "project:registry", "body-path:projects",
                                         "body-path:manifest/projects.yaml"])
        XCTAssertEqual(groups.map(\.title), ["Projects Skill", "Project registry", "projects", registry.path])
        XCTAssertEqual(groups.map(\.items.count), [1, 1, 1, 1])
        XCTAssertEqual(groups.last?.subtitle, "Body differs", "The item's body kind must own its presentation")
        model.choose("skill:projects", .thisMachine)
        XCTAssertFalse(model.canApply, "Choosing one entity must leave the others unresolved")
        let chosen = try readyGroups(from: model.phase)
        XCTAssertEqual(chosen.filter { $0.chosen != nil }.map(\.id), ["skill:projects"])
    }

    func assertEquivalentRowsDoNotTrap() async throws {
        let context = try makeContext()
        let names = ["caf\u{00E9}", "cafe\u{0301}"]
        for (index, slug) in names.enumerated() {
            context.insert(Skill(name: "Equivalent \(index)", directoryName: slug))
        }
        try context.save()
        let engine = StubResolutionEngine()
        engine.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: names[0]), overlayItem(slug: names[1])]))]
        let model = makeModel(engine: engine)
        await model.loadAndReport(context: context)
        let groups = try readyGroups(from: model.phase)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(["Equivalent 0", "Equivalent 1"].contains(try XCTUnwrap(groups.first).title))
        XCTAssertEqual(groups.first?.items.count, 2)
    }
}
