import XCTest
@testable import Pensieve

extension SyncNudgeTests {
    func testCoordinatorAppliedPullDoesNotNudge() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "pulled", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Remote"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        fixture.watcher.emit(skill.directoryName)

        XCTAssertEqual(fixture.counter.value, 0)
        XCTAssertFalse(fixture.library.externallyModified.contains(skill.directoryName))
    }

    func testExternalEditDuringCoordinatorCycleRemainsExternal() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "cycle-external", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: "Pending")

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "External"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: true)

        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertEqual(fixture.library.readBody(skill), "External")
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, "Pending")
    }

    func testWatcherEventAfterCleanSampleRechecksBeforeClassification() throws {
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
        fixture.library.finishCoordinatorChanges(
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

    func testFinalScanChangeRechecksBeforeDelayedWatcherEvent() throws {
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
        fixture.library.finishCoordinatorChanges(
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

    func testCoordinatorTransientBodyIsReseededFromFinalDiskState() throws {
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
        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        fixture.watcher.emit(skill.directoryName)

        XCTAssertEqual(fixture.counter.value, 0)
        XCTAssertFalse(fixture.library.externallyModified.contains(skill.directoryName))
    }

    func testTheCyclesFinalReseedPublishesAnObservedSignal() throws {
        // The fingerprint is not observed (an off-main mutation under the lock deadlocks against SwiftUI), so a
        // draft that matched a transient body and reads dirty again after the cycle's final re-seed needs one
        // main-thread signal, or File › Save stays disabled with unsaved changes (batch Layer-2, round 4).
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "reseed-signal", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: "Transient")
        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Old"
        )
        let token = fixture.library.reloadToken

        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertGreaterThan(fixture.library.reloadToken, token)
    }

    func testCoordinatorTransientBodyMatchingTheDraftKeepsItAndAsksNothing() throws {
        // The draft happens to equal a body the cycle writes on its way to restoring the original: the draft
        // reads clean for that moment and dirty again after — the text is never dropped, and no question is
        // asked, because the cycle's final body is the baseline the draft was made against.
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "transient-draft", store: fixture.store, context: fixture.context)
        var prompts: [UnsavedChangesPrompt] = []
        fixture.library.unsavedChangesPresenter = { prompt, _ in prompts.append(prompt) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: "Transient")

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        XCTAssertFalse(fixture.library.hasUnsavedChanges(for: skill))   // clean for the moment, not dropped
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Old"
        )
        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, "Transient")
        XCTAssertTrue(prompts.isEmpty)
    }

    func testCoordinatorFinalBodyUnderADraftAsksOnceAfterTheCycle() throws {
        // The cycle moves the file for good (a pull with a newer body): the draft survives and the one question
        // comes after the cycle, against the final body, not at the intermediate event.
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "moved-under-draft", store: fixture.store, context: fixture.context)
        var prompts: [UnsavedChangesPrompt] = []
        fixture.library.unsavedChangesPresenter = { prompt, _ in prompts.append(prompt) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: "Mine")

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        XCTAssertTrue(prompts.isEmpty)                                   // not at the intermediate event
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "New"
        )
        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: true)

        XCTAssertEqual(prompts.map(\.reason), [.externalChange])
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, "Mine")
        XCTAssertEqual(fixture.library.readBody(skill), "New")
    }

    func testCoordinatorFinalBodyMatchingTheDraftAsksNothing() throws {
        // The cycle passes through a body that differs from the draft and lands on one that equals it: the
        // question is decided against the final body — clean, the draft retained, nothing asked. A question
        // decided before the fingerprints are refreshed to the final body would ask (round 4).
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "final-matches-draft", store: fixture.store, context: fixture.context)
        var prompts: [UnsavedChangesPrompt] = []
        fixture.library.unsavedChangesPresenter = { prompt, _ in prompts.append(prompt) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: "Mine")

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Transient"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Mine"
        )
        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertFalse(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, "Mine")
        XCTAssertTrue(prompts.isEmpty)
    }

    func testACleanPullKeepsTheWarningOnARetainedDraft() throws {
        // A successful pull (no unsynced changes) settles the "modified externally" mark — except on a file whose
        // dirty draft the user kept with Cancel: the label is the warning that Save overwrites (round 2).
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "clean-pull-draft", store: fixture.store, context: fixture.context)
        fixture.library.unsavedChangesPresenter = { _, resolve in resolve(.cancel) }
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: "Mine")

        fixture.library.beginCoordinatorChanges()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "New"
        )
        fixture.watcher.emit(skill.directoryName)
        fixture.library.finishCoordinatorChanges(hasUnsyncedChanges: false)

        XCTAssertTrue(fixture.library.hasUnsavedChanges(for: skill))
        XCTAssertEqual(fixture.library.drafts[skill.directoryName]?.body, "Mine")
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

        XCTAssertEqual(fixture.library.editorBody(for: skill), "External")   // the remount
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
        fixture.watcher.emit(skill.directoryName)
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testARemountDuringACycleAfterACleanSampleTriggersTheRecheck() throws {
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
        XCTAssertEqual(fixture.library.editorBody(for: skill), "External")   // the remount, no event yet
        XCTAssertEqual(fixture.counter.value, 0)                              // a cycle nudges at its end
        var recheckCount = 0
        fixture.library.finishCoordinatorChanges(
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
