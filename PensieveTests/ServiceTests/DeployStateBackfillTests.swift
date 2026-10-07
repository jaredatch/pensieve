import SwiftData
import XCTest
@testable import Pensieve

final class DeployStateBackfillTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var store: DeployStateStore!
    private var paths: DeployStateBackfillPaths!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveDeployStateBackfillTests-\(UUID().uuidString)"
        fileService = FileService()
        store = DeployStateStore(fileService: fileService, appSupportDir: tempDir + "/app-support")
        let userSkillsRoots: [PlatformTarget: String] = [
            .claudeCode: tempDir + "/agents/claude/skills",
            .codex: tempDir + "/agents/codex/skills",
            .openClaw: tempDir + "/agents/openclaw/skills",
            .hermes: tempDir + "/agents/hermes/skills/pensieve"
        ]
        paths = DeployStateBackfillPaths(
            pensieveSkillsDir: tempDir + "/pensieve/skills",
            cursorUserRulesDir: tempDir + "/cursor/rules",
            userSkillsRoot: { userSkillsRoots[$0] }
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    func testSeedsPensieveOwnedUserSymlinkAndIgnoresForeignSymlink() throws {
        let context = try makeContext()
        try makeCanonicalSkill("owned")
        try makeCanonicalSkill("foreign")
        let claudeRoot = try XCTUnwrap(paths.userSkillsRoot(.claudeCode))
        let ownedLink = claudeRoot + "/owned"
        let foreignLink = claudeRoot + "/foreign"
        try fileService.createSymlink(at: ownedLink, pointingTo: paths.pensieveSkillsDir + "/owned")
        try fileService.createSymlink(at: foreignLink, pointingTo: tempDir + "/outside/foreign")
        try store.replaceAll([stateRecord(slug: "owned", platform: .claudeCode, artifactPath: ownedLink,
                                          recordedAt: "2026-01-01T00:00:00Z")])

        makeBackfill().backfill(context: context)

        let records = try store.read().records
        XCTAssertEqual(records.map(\.artifactPath), [ownedLink])
        XCTAssertEqual(records.first?.recordedAt, "2026-01-01T00:00:00Z")
    }

    @MainActor
    func testCursorHistorySeedsExistingRuleAndIgnoresCollisionWithoutDeployRecord() throws {
        let context = try makeContext()
        let owned = insertedSkill("Owned", slug: "owned", context: context)
        _ = insertedSkill("Collision", slug: "collision", context: context)
        try makeCanonicalSkill("collision")
        let ownedRule = paths.cursorUserRulesDir + "/owned.mdc"
        let collisionRule = paths.cursorUserRulesDir + "/collision.mdc"
        try fileService.writeFile(at: ownedRule, content: "compiled by Pensieve")
        try fileService.writeFile(at: collisionRule, content: "user-authored collision")
        context.insert(DeployRecord(
            skillID: owned.id,
            platform: .cursor,
            targetPath: ownedRule,
            contentHash: "hash"
        ))
        try context.save()

        makeBackfill().backfill(context: context)

        let records = try store.read().records
        XCTAssertEqual(records.map(\.artifactPath), [ownedRule])
        XCTAssertEqual(records.first?.slug, "owned")
        XCTAssertEqual(records.first?.platform, PlatformTarget.cursor.rawValue)
    }

    @MainActor
    func testProjectScopedBackfillValidatesExactShapesIncludingKeylessProjects() throws {
        let context = try makeContext()
        let project = insertedProject("Project", path: tempDir + "/project", identityKey: "project-key", context: context)
        let nilProject = insertedProject("Nil", path: tempDir + "/nil-project", identityKey: nil, context: context)
        let validLinkSkill = insertedSkill("Valid Link", slug: "valid-link", context: context)
        let validCursorSkill = insertedSkill("Valid Cursor", slug: "valid-cursor", context: context)

        for slug in ["valid-link", "valid-cursor", "foreign", "alpha", "beta", "wrong-shape", "nil-skill"] {
            try makeCanonicalSkill(slug)
        }

        let validLink = DeployPaths.linkPath(
            directoryName: validLinkSkill.directoryName,
            platform: .claudeCode,
            projectPath: project.path
        )
        let validTarget = DeployPaths.targetPath(
            directoryName: validLinkSkill.directoryName,
            platform: .claudeCode,
            projectPath: project.path
        )
        try fileService.createSymlink(at: validLink, pointingTo: validTarget)
        context.insert(DeployRecord(
            skillID: UUID(),
            platform: .claudeCode,
            targetPath: validLink,
            contentHash: "stale",
            projectID: project.id
        ))
        insertRecord(skill: validLinkSkill, platform: .claudeCode, targetPath: validLink, project: project, context: context)

        let validCursor = project.path + "/.cursor/rules/valid-cursor.mdc"
        try fileService.writeFile(at: validCursor, content: "project cursor")
        insertRecord(skill: validCursorSkill, platform: .cursor, targetPath: validCursor, project: project, context: context)
        try insertAdditionalProjectRecords(project: project, nilProject: nilProject, context: context)
        try context.save()

        makeBackfill().backfill(context: context)

        let records = try store.read().records
        let keylessLink = DeployPaths.linkPath(directoryName: "nil-skill", platform: .claudeCode, projectPath: nilProject.path)
        XCTAssertEqual(Set(records.map(\.artifactPath)), [validLink, validCursor, keylessLink])
        XCTAssertEqual(Set(records.map(\.projectIdentityKey)), ["project-key", nil])
        XCTAssertEqual(records.first { $0.artifactPath == keylessLink }?.scope, "project")
    }

    @MainActor
    func testDropsStaleRecordsAndSecondRunIsByteIdentical() throws {
        let context = try makeContext()
        try makeCanonicalSkill("owned")
        let ownedLink = try XCTUnwrap(paths.userSkillsRoot(.codex)) + "/owned"
        try fileService.createSymlink(at: ownedLink, pointingTo: paths.pensieveSkillsDir + "/owned")
        try store.replaceAll([
            stateRecord(slug: "stale", platform: .cursor, artifactPath: tempDir + "/missing.mdc"),
            stateRecord(slug: "owned", platform: .codex, artifactPath: ownedLink,
                        recordedAt: "2026-01-01T00:00:00Z")
        ])

        let backfill = makeBackfill()
        backfill.backfill(context: context)
        let firstBytes = try fileService.readFile(at: tempDir + "/app-support/deploy-state.json")
        backfill.backfill(context: context)
        let secondBytes = try fileService.readFile(at: tempDir + "/app-support/deploy-state.json")

        XCTAssertEqual(firstBytes, secondBytes)
        let records = try store.read().records
        XCTAssertEqual(records.map(\.artifactPath), [ownedLink])
        XCTAssertEqual(records.first?.recordedAt, "2026-01-01T00:00:00Z")
    }

    @MainActor
    func testOverlappingProjectAndUserPathsCollapseToOneRecordPerArtifactPath() throws {
        // A project registered at the user's HOME makes the project cursor path equal the
        // user-wide one — the two candidate sources must collapse to ONE record per
        // artifactPath (the schema's unique key), user-wide winning (PLAN-16 / 16.2 Layer-2 P2).
        let context = try makeContext()
        let home = tempDir + "/home"
        paths.cursorUserRulesDir = home + "/.cursor/rules"
        let skill = insertedSkill("Dup", slug: "dup", context: context)
        let project = insertedProject("Home", path: home, identityKey: "example.com/home", context: context)
        let rule = home + "/.cursor/rules/dup.mdc"
        try fileService.writeFile(at: rule, content: "compiled by Pensieve")
        context.insert(DeployRecord(
            skillID: skill.id, platform: .cursor, targetPath: rule, contentHash: "hash"
        ))
        insertRecord(skill: skill, platform: .cursor, targetPath: rule, project: project, context: context)

        makeBackfill().backfill(context: context)

        let records = try store.read().records
        XCTAssertEqual(records.map(\.artifactPath), [rule])
        XCTAssertEqual(records.first?.scope, "user")
        XCTAssertNil(records.first?.projectIdentityKey)
    }

    private func makeBackfill() -> DeployStateBackfill {
        DeployStateBackfill(
            fileService: fileService,
            store: store,
            paths: paths,
            now: { Date(timeIntervalSince1970: 1_784_332_800) }
        )
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeCanonicalSkill(_ slug: String) throws {
        try fileService.writeFile(
            at: paths.pensieveSkillsDir + "/" + slug + "/SKILL.md",
            content: "# \(slug)"
        )
    }

    @MainActor
    private func insertAdditionalProjectRecords(
        project: Project,
        nilProject: Project,
        context: ModelContext
    ) throws {
        let foreignSkill = insertedSkill("Foreign", slug: "foreign", context: context)
        let alpha = insertedSkill("Alpha", slug: "alpha", context: context)
        let beta = insertedSkill("Beta", slug: "beta", context: context)
        let wrongShape = insertedSkill("Wrong Shape", slug: "wrong-shape", context: context)
        let nilSkill = insertedSkill("Nil", slug: "nil-skill", context: context)

        try insertForeignProjectSymlink(skill: foreignSkill, project: project, context: context)
        try insertWrongSkillProjectSymlink(skill: alpha, wrongTargetSkill: beta, project: project, context: context)
        try insertWrongShapeProjectSymlink(skill: wrongShape, project: project, context: context)
        try insertNilIdentityProjectSymlink(skill: nilSkill, project: nilProject, context: context)
    }

    @MainActor
    private func insertForeignProjectSymlink(skill: Skill, project: Project, context: ModelContext) throws {
        let link = DeployPaths.linkPath(directoryName: skill.directoryName, platform: .claudeCode,
                                        projectPath: project.path)
        try fileService.createSymlink(at: link, pointingTo: tempDir + "/outside/foreign")
        insertRecord(skill: skill, platform: .claudeCode, targetPath: link, project: project, context: context)
    }

    @MainActor
    private func insertWrongSkillProjectSymlink(
        skill: Skill,
        wrongTargetSkill: Skill,
        project: Project,
        context: ModelContext
    ) throws {
        let link = DeployPaths.linkPath(directoryName: skill.directoryName, platform: .codex, projectPath: project.path)
        let wrongTarget = DeployPaths.targetPath(directoryName: wrongTargetSkill.directoryName, platform: .codex,
                                                 projectPath: project.path)
        try fileService.createSymlink(at: link, pointingTo: wrongTarget)
        insertRecord(skill: skill, platform: .codex, targetPath: link, project: project, context: context)
    }

    @MainActor
    private func insertWrongShapeProjectSymlink(skill: Skill, project: Project, context: ModelContext) throws {
        let link = project.path + "/.claude/skills/wrong-shape-extra"
        let target = DeployPaths.targetPath(directoryName: skill.directoryName, platform: .claudeCode,
                                            projectPath: project.path)
        try fileService.createSymlink(at: link, pointingTo: target)
        insertRecord(skill: skill, platform: .claudeCode, targetPath: link, project: project, context: context)
    }

    @MainActor
    private func insertNilIdentityProjectSymlink(skill: Skill, project: Project, context: ModelContext) throws {
        let link = DeployPaths.linkPath(directoryName: skill.directoryName, platform: .claudeCode,
                                        projectPath: project.path)
        let target = DeployPaths.targetPath(directoryName: skill.directoryName, platform: .claudeCode,
                                            projectPath: project.path)
        try fileService.createSymlink(at: link, pointingTo: target)
        insertRecord(skill: skill, platform: .claudeCode, targetPath: link, project: project, context: context)
    }

    @MainActor
    private func insertedSkill(_ name: String, slug: String, context: ModelContext) -> Skill {
        let skill = Skill(name: name, directoryName: slug)
        context.insert(skill)
        return skill
    }

    @MainActor
    private func insertedProject(
        _ name: String,
        path: String,
        identityKey: String?,
        context: ModelContext
    ) -> Project {
        let project = Project(name: name, path: path)
        project.identityKey = identityKey
        context.insert(project)
        return project
    }

}

// Fixture builders live in an extension so the test class body stays within the lint budget.
private extension DeployStateBackfillTests {
    @MainActor
    func insertRecord(
        skill: Skill,
        platform: PlatformTarget,
        targetPath: String,
        project: Project,
        context: ModelContext
    ) {
        context.insert(DeployRecord(
            skillID: skill.id,
            platform: platform,
            targetPath: targetPath,
            contentHash: "hash",
            projectID: project.id
        ))
    }

    func stateRecord(
        slug: String,
        platform: PlatformTarget,
        artifactPath: String,
        recordedAt: String = "2026-07-17T00:00:00Z"
    ) -> DeployStateRecord {
        DeployStateRecord(
            slug: slug,
            platform: platform.rawValue,
            scope: "user",
            projectIdentityKey: nil,
            artifactPath: artifactPath,
            recordedAt: recordedAt
        )
    }
}
