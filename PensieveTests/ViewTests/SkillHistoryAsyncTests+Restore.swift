import XCTest
@testable import Pensieve

extension SkillHistoryAsyncTests {
    func assertLaterReadExplainsRetiredRestore() async throws {
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
                fixture.git.showOperation = { sha in
                    if sha == "restore" { restoring.fulfill(); try? restoreGate.wait() } else {
                        reading.fulfill(); try? readGate.wait()
                    }
                    return sha == "read" && readFails ? nil : sha + " body"
                }
                let restore = model.restore(restoreVersion, skill: fixture.skill, git: fixture.git,
                    workingDir: "/repo", store: fixture.store, library: fixture.library, notifier: {})
                await fulfillment(of: [restoring], timeout: TestWait.timeoutSeconds)
                let read = Task { await model.read(readVersion, skill: fixture.skill, git: fixture.git,
                    workingDir: "/repo", asDiff: asDiff) }
                await fulfillment(of: [reading], timeout: TestWait.timeoutSeconds)
                let message = "Nothing was restored. You opened another version before Restore finished."
                XCTAssertEqual(model.errorMessage, message, "Retiring a confirmed Restore must explain its refusal")
                if readFinishesFirst { readGate.open(); await read.value }
                restoreGate.open()
                let restored = await restore.value
                XCTAssertFalse(restored)
                if !readFinishesFirst { readGate.open(); await read.value }
                XCTAssertEqual(model.errorMessage, message + (readFails ? " Couldn't load that version." : ""))
                XCTAssertNil(model.restoringVersion)
                XCTAssertEqual(fixture.store.bodies["example"], "Current")
                XCTAssertEqual(fixture.counter.value, 0)
                if asDiff { XCTAssertEqual(model.diff?.body, readFails ? nil : "read body") } else {
                    XCTAssertEqual(model.selection?.sha, readFails ? nil : "read")
                }
            }
        }
    }
}
