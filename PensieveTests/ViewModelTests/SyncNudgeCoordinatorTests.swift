import XCTest
@testable import Pensieve

extension SyncNudgeTests {
    func testCoordinatorAppliedPullDoesNotNudge() async throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "pulled", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Remote"
        )
        fixture.watcher.emit(skill.directoryName)
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        fixture.watcher.emit(skill.directoryName)

        XCTAssertEqual(fixture.counter.value, 0)
        XCTAssertFalse(fixture.library.externallyModified.contains(skill.directoryName))
    }
    func testExternalEditDuringCoordinatorCycleRemainsExternal() async throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "cycle-external", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Pending"))

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "External"
        )
        fixture.watcher.emit(skill.directoryName)
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: true)

        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertEqual(fixture.library.readBody(skill), "External")
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Pending"))
    }
    func testWatcherEventAfterCleanSampleRechecksBeforeClassification() async throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "classification-race", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()

        fixture.library.beginCoordinatorChanges()
        let sampledSequence = fixture.library.coordinatorWatcherEventSequence
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "External"
        )
        fixture.watcher.emit(skill.directoryName)
        var recheckCount = 0
        await fixture.library.finishCoordinatorChanges(
            hasUnsyncedChanges: false,
            sampledWatcherEventSequence: sampledSequence,
            recheckHasUnsyncedChanges: {
                recheckCount += 1
                return true
            }
        )

        XCTAssertEqual(recheckCount, 1)
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
    }
    func testFinalScanChangeRechecksBeforeDelayedWatcherEvent() async throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "delayed-event", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()

        fixture.library.beginCoordinatorChanges()
        let sampledSequence = fixture.library.coordinatorWatcherEventSequence
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "External"
        )
        var recheckCount = 0
        await fixture.library.finishCoordinatorChanges(
            hasUnsyncedChanges: false,
            sampledWatcherEventSequence: sampledSequence,
            recheckHasUnsyncedChanges: {
                recheckCount += 1
                return true
            }
        )
        fixture.watcher.emit(skill.directoryName)

        XCTAssertEqual(recheckCount, 1)
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
    }
    func testCoordinatorTransientBodyIsReseededFromFinalDiskState() async throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "transient", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Old"
        )
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        fixture.watcher.emit(skill.directoryName)

        XCTAssertEqual(fixture.counter.value, 0)
        XCTAssertFalse(fixture.library.externallyModified.contains(skill.directoryName))
    }
    func testTheCyclesFinalReseedPublishesAnObservedSignal() async throws {
        // The fingerprint is not observed (an off-main mutation under the lock deadlocks against SwiftUI), so a
        // draft that matched a transient body and reads dirty again after the cycle's final re-seed needs one
        // main-thread signal, or File › Save stays disabled with unsaved changes (batch Layer-2, round 4).
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "reseed-signal", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"))
        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Old"
        )
        let token = fixture.library.reloadToken

        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertGreaterThan(fixture.library.reloadToken, token)
    }
    func testCoordinatorTransientBodyMatchingTheDraftKeepsItAndAsksNothing() async throws {
        // The draft happens to equal a body the cycle writes on its way to restoring the original: the draft
        // reads clean for that moment and dirty again after — the text is never dropped, and no question is
        // asked, because the cycle's final body is the baseline the draft was made against.
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "transient-draft", store: fixture.store, context: fixture.context)
        var prompts: [UnsavedChangesPrompt] = []
        fixture.library.unsavedChangesPresenter = { prompt, _ in prompts.append(prompt) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"))

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        XCTAssertFalse(fixture.library.hasUnsavedChanges(for: skill))   // clean for the moment, not dropped
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Old"
        )
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"))
        XCTAssertTrue(prompts.isEmpty)
    }
    func testCoordinatorFinalBodyUnderADraftAsksOnceAfterTheCycle() async throws {
        // The cycle moves the file for good (a pull with a newer body): the draft survives and the one question
        // comes after the cycle, against the final body, not at the intermediate event.
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "moved-under-draft", store: fixture.store, context: fixture.context)
        var prompts: [UnsavedChangesPrompt] = []
        fixture.library.unsavedChangesPresenter = { prompt, _ in prompts.append(prompt) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"))

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        XCTAssertTrue(prompts.isEmpty)                                   // not at the intermediate event
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "New"
        )
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: true)

        XCTAssertEqual(prompts.map(\.reason), [.externalChange])
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"))
        XCTAssertEqual(fixture.library.readBody(skill), "New")
    }
    func testCoordinatorFinalBodyMatchingTheDraftAsksNothing() async throws {
        // The cycle passes through a body that differs from the draft and lands on one that equals it: the
        // question is decided against the final body — clean, the draft retained, nothing asked. A question
        // decided before the fingerprints are refreshed to the final body would ask (round 4).
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "final-matches-draft", store: fixture.store, context: fixture.context)
        var prompts: [UnsavedChangesPrompt] = []
        fixture.library.unsavedChangesPresenter = { prompt, _ in prompts.append(prompt) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"))

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"
        )
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertFalse(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"))
        XCTAssertTrue(prompts.isEmpty)
    }
    func testACleanPullKeepsTheWarningOnARetainedDraft() async throws {
        // A successful pull (no unsynced changes) settles the "modified externally" mark — except on a file whose
        // dirty draft the user kept with Cancel: the label is the warning that Save overwrites (round 2).
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "clean-pull-draft", store: fixture.store, context: fixture.context)
        fixture.library.unsavedChangesPresenter = { _, resolve in resolve(.cancel) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"))

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "New"
        )
        fixture.watcher.emit(skill.directoryName)
        await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"))
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
    }
    func testARemountOverADivergentBodyNudgesSyncOnce() throws {
        // A body that changed while no editor was mounted is classified by the remount: sync is nudged then,
        // and the watcher's later event — an echo of a body the fingerprint already holds — nudges nothing.
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "remount-nudge", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "External"
        )

        XCTAssertEqual(fixture.library.editorBody(for: skill), fixture.store.bodies[skill.directoryName])   // the remount
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
        fixture.watcher.emit(skill.directoryName)
        XCTAssertEqual(fixture.counter.value, 1)
    }
    func testARemountDuringACycleAfterACleanSampleTriggersTheRecheck() async throws {
        // The remount's classification counts as an observed change: a cycle that sampled a clean worktree
        // before it rechecks, exactly as it would after a watcher event.
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "remount-in-cycle", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()

        fixture.library.beginCoordinatorChanges()
        let sampledSequence = fixture.library.coordinatorWatcherEventSequence
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "External"
        )
        XCTAssertEqual(fixture.library.editorBody(for: skill), fixture.store.bodies[skill.directoryName])
        XCTAssertEqual(fixture.counter.value, 0)                              // a cycle nudges at its end
        var recheckCount = 0
        await fixture.library.finishCoordinatorChanges(
            hasUnsyncedChanges: false,
            sampledWatcherEventSequence: sampledSequence,
            recheckHasUnsyncedChanges: {
                recheckCount += 1
                return true
            }
        )

        XCTAssertEqual(recheckCount, 1)
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
    }
}

extension SyncNudgeTests {
    func testHeldRecheckLeavesMainActorFreeAndNewerResultWins() async throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "held-recheck", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.beginCoordinatorChanges()
        let sample = fixture.library.coordinatorWatcherEventSequence
        fixture.store.bodies[skill.directoryName] = "External"
        fixture.watcher.emit(skill.directoryName)
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let entered = expectation(description: "first git recheck held")
        let first = Task {
            await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false,
                sampledWatcherEventSequence: sample, recheckHasUnsyncedChanges: {
                    XCTAssertFalse(Thread.isMainThread, "git recheck must run outside the main actor")
                    entered.fulfill()
                    if !Thread.isMainThread { try? gate.wait() }
                    return false
                })
        }
        await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
        XCTAssertTrue(fixture.library.isApplyingCoordinatorChanges, "main actor runs while git waits")
        let newerGate = TestWait.Gate(owner: self)
        defer { newerGate.open() }
        let newerEntered = expectation(description: "newer recheck held")
        let newer = Task {
            await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false,
                sampledWatcherEventSequence: sample, recheckHasUnsyncedChanges: {
                    newerEntered.fulfill()
                    if !Thread.isMainThread { try? newerGate.wait() }
                    return false
                })
        }
        await fulfillment(of: [newerEntered], timeout: TestWait.timeoutSeconds)
        fixture.store.bodies[skill.directoryName] = "Latest external edit"
        fixture.watcher.emit(skill.directoryName)
        newerGate.open()
        await newer.value
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
        gate.open()
        await first.value
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName), "old clean result must be ignored")
        XCTAssertEqual(fixture.counter.value, 1, "only the newest completion requests the later sync")
    }
}

extension SyncNudgeTests {
    func testLateRecheckEventsFinishAndSettleOnlyEarlierChanges() async throws {
        for change in ["echo", "same skill", "other skill", "app echo"] {
            try await assertEventDuringRecheckFinishes(change: change)
        }
    }

    private func assertEventDuringRecheckFinishes(change: String) async throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "late-event", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        let other = try insertSkill(slug: "other", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: other)
        fixture.library.beginCoordinatorChanges()
        let sample = fixture.library.coordinatorWatcherEventSequence
        fixture.store.bodies[skill.directoryName] = "Before git status"
        fixture.watcher.emit(skill.directoryName)
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let entered = expectation(description: "recheck held before a later watcher event")
        let checks = Counter()
        let finish = Task {
            await fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false,
                sampledWatcherEventSequence: sample, recheckHasUnsyncedChanges: {
                    if checks.increment() == 1 {
                        entered.fulfill()
                        if !Thread.isMainThread { try? gate.wait() }
                    }
                    return false
                })
        }
        await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
        let lateSlug = change == "other skill" ? other.directoryName : skill.directoryName
        if change != "echo" { fixture.store.bodies[lateSlug] = "During git status" }
        if change == "app echo" { fixture.library.noteAppAuthoredBody(skill, body: "During git status") }
        fixture.watcher.emit(lateSlug)
        gate.open()
        await finish.value
        XCTAssertEqual(checks.value, 1, "watcher traffic must not extend a cycle's git recheck")
        XCTAssertFalse(fixture.library.isApplyingCoordinatorChanges)
        let realChange = change == "same skill" || change == "other skill"
        XCTAssertEqual(fixture.counter.value, realChange ? 1 : 0, "only a non-echo event requests a later sync")
        XCTAssertEqual(fixture.library.externallyModified.contains(skill.directoryName), change == "same skill",
            "a clean check settles the earlier pull unless that skill changed during the check")
        XCTAssertEqual(fixture.library.externallyModified.contains(other.directoryName), change == "other skill")
        fixture.store.bodies[skill.directoryName] = "After the cycle"
        fixture.watcher.emit(skill.directoryName)
        XCTAssertEqual(fixture.counter.value, realChange ? 2 : 1, "watcher changes must resume normal delivery after finishing")
    }
}
