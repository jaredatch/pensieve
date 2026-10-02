import XCTest
@testable import Pensieve

extension SyncNudgeTests {
    /// Pins the install fixture's fidelity to the production bracket, not production itself.
    func testInstallGateThrowAfterWriteEndsSuccessfully() throws {
        let fixture = try libraryFixture()
        let gate = TestWait.Gate(owner: self)
        let candidate = SkillCandidate(
            path: "skills/demo", slug: "demo", name: "Demo", skillDescription: "Description",
            treeHash: "tree", containsSymlink: false, unavailableReason: nil
        )
        var wrote = false
        let service = NudgeInstallService(
            candidates: [candidate], beforeInstallReturn: { try gate.wait(timeout: .zero) },
            onInstallWrite: { _ in wrote = true }
        )
        let source = try service.fetch(repo: "fixture", ref: nil, credential: nil)
        var events: [String] = []
        let registration = SyncBodyWriteRegistration(
            begin: { slug, _ in events.append("begin:\(slug)") },
            end: { slug, succeeded in events.append("end:\(slug):\(succeeded)") }
        )

        XCTAssertThrowsError(try service.install(
            candidate: candidate, from: source, credential: nil,
            bodyWriteRegistration: registration, context: fixture.context
        ))

        XCTAssertTrue(wrote)
        XCTAssertEqual(events, ["begin:demo", "end:demo:true"])
        expectWriteGateTimeoutAtTeardown()
    }

    /// Pins the apply fixture's fidelity to the production bracket, not production itself.
    func testApplyGateThrowAfterWriteEndsSuccessfully() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "demo", store: fixture.store, context: fixture.context)
        let oldBody = fixture.store.bodies["demo"]
        let gate = TestWait.Gate(owner: self)
        var events: [String] = []
        let registration = SyncBodyWriteRegistration(
            begin: { slug, _ in events.append("begin:\(slug)") },
            end: { slug, succeeded in events.append("end:\(slug):\(succeeded)") }
        )

        XCTAssertThrowsError(try Self.applyBodyWrite(
            target: skill, write: fixture.store.writeBody, registration: registration,
            beforeReturn: { try gate.wait(timeout: .zero) }
        ))

        XCTAssertNotEqual(fixture.store.bodies["demo"], oldBody)
        XCTAssertEqual(events, ["begin:demo", "end:demo:true"])
        expectWriteGateTimeoutAtTeardown()
    }

    /// Pins the install fixture's fidelity to the production bracket, not production itself.
    func testInstallWriteThrowEndsBodyWriteUnsuccessfully() throws {
        let fixture = try libraryFixture()
        let candidate = SkillCandidate(
            path: "skills/demo", slug: "demo", name: "Demo", skillDescription: "Description",
            treeHash: "tree", containsSymlink: false, unavailableReason: nil
        )
        let service = NudgeInstallService(
            candidates: [candidate], beforeInstallReturn: { XCTFail("post-write hook must not run") },
            onInstallWrite: { _ in throw NudgeFailure.beforeCanonicalWrite }
        )
        let source = try service.fetch(repo: "fixture", ref: nil, credential: nil)
        var events: [String] = []
        let registration = SyncBodyWriteRegistration(
            begin: { slug, _ in events.append("begin:\(slug)") },
            end: { slug, succeeded in events.append("end:\(slug):\(succeeded)") }
        )

        XCTAssertThrowsError(try service.install(
            candidate: candidate, from: source, credential: nil,
            bodyWriteRegistration: registration, context: fixture.context
        ))

        XCTAssertEqual(events, ["begin:demo", "end:demo:false"])
    }

    /// Pins the apply fixture's fidelity to the production bracket, not production itself.
    func testApplyWriteThrowEndsBodyWriteUnsuccessfully() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "demo", store: fixture.store, context: fixture.context)
        let oldBody = fixture.store.bodies["demo"]
        var events: [String] = []
        let registration = SyncBodyWriteRegistration(
            begin: { slug, _ in events.append("begin:\(slug)") },
            end: { slug, succeeded in events.append("end:\(slug):\(succeeded)") }
        )

        XCTAssertThrowsError(try Self.applyBodyWrite(
            target: skill, write: { _, _ in throw NudgeFailure.beforeCanonicalWrite }, registration: registration,
            beforeReturn: { XCTFail("post-write hook must not run") }
        ))

        XCTAssertEqual(fixture.store.bodies["demo"], oldBody)
        XCTAssertEqual(events, ["begin:demo", "end:demo:false"])
    }

    nonisolated static func applyBodyWrite(
        target: Skill, write: (String, String) throws -> Void, registration: SyncBodyWriteRegistration,
        beforeReturn: () throws -> Void
    ) throws -> SkillUpdateCompletion {
        let expectedBody = SkillSerializer.serialize(
            name: target.name, description: "New description", body: "New"
        )
        registration.begin(target.directoryName, SkillParser.stripFrontmatter(expectedBody))
        var bodyWriteSucceeded = false
        defer { registration.end(target.directoryName, bodyWriteSucceeded) }
        try write(target.directoryName, expectedBody)
        bodyWriteSucceeded = true
        try beforeReturn()
        return SkillUpdateCompletion(
            skillID: target.id, name: target.name, skillDescription: "New description",
            installedOriginData: Data("new-origin".utf8), updatedAt: Date()
        )
    }

    private func expectWriteGateTimeoutAtTeardown() {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("Gate did not open normally: timedOut") }
        XCTExpectFailure("Only the automatic gate teardown check must fail", options: options)
    }
}
