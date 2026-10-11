import XCTest
@testable import Pensieve

extension SkillHistoryAsyncTests {
    func assertLaterReadExplainsRetiredRestore() async throws {
        try await assertRetirementBelongsToItsSkill()
        try await assertReplacementReadsKeepRetirementReason()
        try await assertSameVersionReadAndNewRestore()
    }

    private func assertReplacementReadsKeepRetirementReason() async throws {
        for asDiff in [false, true] {
            for (readFinishesFirst, readFails) in [(false, false), (false, true), (true, false), (true, true)] {
                let fixture = try fixture(), model = SkillHistoryTabPresentation()
                fixture.git.commits = [Self.commit("restore"), Self.commit("read")]
                await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
                let restoreVersion = try XCTUnwrap(model.snapshot.versions.first)
                let readVersion = try XCTUnwrap(model.snapshot.versions.last)
                let restoreGate = TestWait.Gate(owner: self), readGate = TestWait.Gate(owner: self)
                defer { restoreGate.open(); readGate.open() }
                let restoring = expectation(description: "confirmed Restore held")
                let reading = expectation(description: "replacement History read held")
                let reads = Counter()
                fixture.git.showOperation = { sha in
                    if sha == "restore" { restoring.fulfill(); try? restoreGate.wait() } else {
                        reads.increment()
                        if reads.value == 1 { reading.fulfill() }
                        try? readGate.wait()
                    }
                    return sha == "read" && readFails ? nil : sha + " body"
                }
                let restore = model.restore(restoreVersion, skill: fixture.skill, git: fixture.git,
                    workingDir: "/repo", store: fixture.store, library: fixture.library, notifier: {})
                await fulfillment(of: [restoring], timeout: TestWait.timeoutSeconds)
                let read = Task { await model.read(readVersion, skill: fixture.skill, git: fixture.git,
                    workingDir: "/repo", asDiff: asDiff) }
                await fulfillment(of: [reading], timeout: TestWait.timeoutSeconds)
                let name = "asDiff=\(asDiff), readFinishesFirst=\(readFinishesFirst), readFails=\(readFails)"
                let message = "Nothing was restored. Another History read started before Restore finished."
                XCTAssertEqual(model.errorMessage, message, name)
                if readFinishesFirst { readGate.open(); await read.value }
                let secondRead = Task { await model.read(readVersion, skill: fixture.skill, git: fixture.git,
                    workingDir: "/repo", asDiff: asDiff) }
                await TestWait.until(failureMessage: "Second read did not start: " + name) { reads.value == 2 }
                XCTAssertTrue(model.errorMessage?.hasPrefix(message) == true, name)
                restoreGate.open()
                let restored = await restore.value
                XCTAssertFalse(restored, name)
                if !readFinishesFirst { readGate.open() }
                readGate.open()
                await read.value
                await secondRead.value
                XCTAssertEqual(model.errorMessage, message + (readFails ? " Couldn't load that version." : ""), name)
                XCTAssertNil(model.restoringVersion, name)
                XCTAssertEqual(fixture.store.bodies["example"], "Current", name)
                XCTAssertEqual(fixture.counter.value, 0, name)
                XCTAssertEqual(asDiff ? model.diff?.body : model.selection?.sha,
                               readFails ? nil : (asDiff ? "read body" : "read"), name)
            }
        }
    }

    private func assertRetirementBelongsToItsSkill() async throws {
        let fixture = try fixture(), model = SkillHistoryTabPresentation()
        fixture.git.commits = [Self.commit("restore")]
        await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
        let version = try XCTUnwrap(model.snapshot.versions.first)
        let gate = TestWait.Gate(owner: self), reads = Counter()
        defer { gate.open() }
        fixture.git.showOperation = { _ in
            reads.increment()
            if reads.value == 1 { try? gate.wait() }
            return "Historical"
        }
        let restore = model.restore(version, skill: fixture.skill, git: fixture.git,
            workingDir: "/repo", store: fixture.store, library: fixture.library, notifier: {})
        await TestWait.until(failureMessage: "Restore on A did not start") { gate.waiterCount == 1 }
        await model.read(version, skill: fixture.skill, git: fixture.git, workingDir: "/repo", asDiff: false)
        let message = "Nothing was restored. Another History read started before Restore finished."
        XCTAssertEqual(model.errorMessage, message)
        let other = Skill(name: "Other", directoryName: "other")
        await model.load(skill: other, git: fixture.git, workingDir: "/repo")
        XCTAssertNil(model.errorMessage, "A read retiring A's Restore must not put its message on B")
        XCTAssertNil(fixture.library.error, "Read retirement stays in its own History tab")
        await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
        XCTAssertEqual(model.errorMessage, message, "Returning to A retains its reason until a new Restore")
        gate.open()
        let restored = await restore.value
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.store.bodies["example"], "Current")
        XCTAssertEqual(fixture.counter.value, 0)
    }

    private func assertSameVersionReadAndNewRestore() async throws {
        let fixture = try fixture(), model = SkillHistoryTabPresentation()
        fixture.git.commits = [Self.commit("restore")]
        await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
        let version = try XCTUnwrap(model.snapshot.versions.first)
        let gate = TestWait.Gate(owner: self), reads = Counter()
        defer { gate.open() }
        fixture.git.showOperation = { _ in
            reads.increment()
            if reads.value == 1 { try? gate.wait() }
            return "Historical"
        }
        let old = model.restore(version, skill: fixture.skill, git: fixture.git,
            workingDir: "/repo", store: fixture.store, library: fixture.library, notifier: {})
        await TestWait.until(failureMessage: "First Restore did not start") { gate.waiterCount == 1 }
        await model.read(version, skill: fixture.skill, git: fixture.git, workingDir: "/repo", asDiff: true)
        XCTAssertEqual(model.errorMessage, "Nothing was restored. Another History read started before Restore finished.")
        let fresh = model.restore(version, skill: fixture.skill, git: fixture.git,
            workingDir: "/repo", store: fixture.store, library: fixture.library, notifier: {})
        XCTAssertNil(model.errorMessage, "A new Restore clears the retired attempt's message before its read")
        let restored = await fresh.value
        XCTAssertTrue(restored)
        gate.open()
        let oldRestored = await old.value
        XCTAssertFalse(oldRestored)
        XCTAssertNil(model.errorMessage, "An older retired Restore cannot replace the new Restore's result")
        XCTAssertEqual(fixture.store.bodies["example"], "Historical")
    }
}
