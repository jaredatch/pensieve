import XCTest
@testable import Pensieve

extension UpstreamHistoryFlowReviewTests {
    func testNewOriginPrunesHeldFailuresProbeAndChecksButKeepsTheManualAsk() async throws {
        for field in ["commit", "tree", "hash"] {
            let fixture = try sequenceFixture(.memory)
            let model = fixture.model
            let old = try XCTUnwrap(model.flows[fixture.skill.id]?.held.first)
            model.flows[fixture.skill.id]?.failures[old.key] = .init(message: "old", localRevision: .initial)
            model.flows[fixture.skill.id]?.probeAnswer = (old.value.origin, .success(fixture.fresh.headCommit))
            model.flows[fixture.skill.id]?.requestedChecks.insert(.init(skillID: fixture.skill.id,
                                                                       origin: old.value.origin, head: "old"))
            model.invalidateForManualCheck(skillID: fixture.skill.id)
            var updated = try origin(for: fixture.skill)
            switch field {
            case "commit": updated.installedCommit = String(repeating: "4", count: 40)
            case "tree": updated.installedTree = String(repeating: "5", count: 40)
            default: updated.contentHash = String(repeating: "6", count: 64)
            }
            fixture.skill.installedOrigin = updated
            fixture.enqueue("new")
            try await fixture.flow.release("new.request")
            let current = try XCTUnwrap(model.flows[fixture.skill.id])
            XCTAssertTrue(current.held.isEmpty, field)
            XCTAssertTrue(current.failures.isEmpty, field)
            XCTAssertNil(current.probeAnswer, field)
            XCTAssertTrue(current.requestedChecks.isEmpty, field)
            XCTAssertTrue(current.manualPending, field)
            XCTAssertEqual(current.manualCount, 1)
            XCTAssertEqual(model.flows[fixture.otherSkill.id]?.held.count, 1)
            try await fixture.flow.drain()
            XCTAssertEqual(model.state, .loaded(fixture.fresh))
            await fixture.flow.close()
        }
    }

    func testOldOriginWorkersCannotRefillPrunedState() async throws {
        for kind in ["read", "probe"] {
            for fails in [false, true] {
                let fixture = try sequenceFixture(.memory, fails: fails)
                fixture.enqueue("old", intent: kind == "read" ? .retry : .appearance)
                try await fixture.flow.run(["old.request", "\(kind)1.start"])
                var updated = try origin(for: fixture.skill)
                updated.installedCommit = String(repeating: "7", count: 40)
                fixture.skill.installedOrigin = updated
                let expectedOrigin = UpstreamHistoryViewModel.OriginKey(origin: updated)
                fixture.enqueue("new")
                try await fixture.flow.run(["new.request", "\(kind)1.finish", "\(kind)1.resume"])
                var current = try XCTUnwrap(fixture.model.flows[fixture.skill.id])
                XCTAssertTrue(current.held.values.allSatisfy { $0.origin == expectedOrigin })
                XCTAssertTrue(current.failures.keys.allSatisfy { $0.request.origin == expectedOrigin })
                XCTAssertNil(current.probeAnswer)
                try await fixture.flow.drain()
                current = try XCTUnwrap(fixture.model.flows[fixture.skill.id])
                XCTAssertTrue(current.held.values.allSatisfy { $0.origin == expectedOrigin })
                XCTAssertTrue(current.failures.keys.allSatisfy { $0.request.origin == expectedOrigin })
                XCTAssertNil(current.probeAnswer)
                XCTAssertTrue(current.jobs.isEmpty)
                await fixture.flow.close()
            }
        }
    }

    func testWiderDiskAnswerCannotReplaceANewerReadHead() async throws {
        for sameHead in [false, true] {
            let fixture = try sequenceFixture(.memory)
            let oldWide = result(head: fixture.kept.headCommit, window: 2, subject: "disk")
            let fresh = sameHead ? fixture.kept : fixture.fresh
            let freshWide = result(head: fresh.headCommit, window: 2, subject: "fresh wide")
            try seedHistoryDisk(oldWide, for: fixture.skill, in: fixture.disk)
            let calls = HistorySequenceCalls()
            let model = owner(cache: fixture.disk, read: { _, _, count in
                calls.append("w\(count)")
                return count == 1 ? fresh : freshWide
            })
            try seedHistoryMemory(fixture.kept, for: fixture.skill, in: model)
            let flow = fixture.flow
            model.sequenceHooks = flow.hooks
            flow.enqueue("A") { await model.request(skill: fixture.skill, intent: .retry) }
            try await flow.run(["A.request", "read1.start"])
            flow.enqueue("D") { await model.request(skill: fixture.skill, windowCount: 2) }
            try await flow.run(["D.request", "disk1.start", "disk1.finish", "read1.finish", "read1.resume", "disk1.resume"])
            XCTAssertEqual(model.state, sameHead ? .loaded(oldWide) : .refreshing(fresh))
            XCTAssertEqual(model.flows[fixture.skill.id]?.held.values.first?.readHead, fresh.headCommit)
            try await flow.drain()
            XCTAssertEqual(calls.values, sameHead ? ["w1"] : ["w1", "w2"])
            XCTAssertEqual(model.state, .loaded(sameHead ? oldWide : freshWide))
            await flow.close()
        }
    }

    func testRetainFencesEachDroppedSkillOnceAndAlsoRemovesDiskOnlyEntries() async throws {
        let fixture = try sequenceFixture(.memory)
        let diskOnly = installedHistorySkill(name: "disk only")
        try seedHistoryDisk(fixture.kept, for: fixture.skill, in: fixture.disk)
        try seedHistoryDisk(fixture.otherResult, for: fixture.otherSkill, in: fixture.disk)
        try seedHistoryDisk(fixture.kept, for: diskOnly, in: fixture.disk)
        let generation = fixture.disk.beginRequest(skillID: fixture.skill.id, superseding: false)
        fixture.model.retain(skillIDs: [fixture.otherSkill.id])
        fixture.disk.withOrderedDiskAccess {}
        XCTAssertNil(fixture.model.flows[fixture.skill.id])
        XCTAssertNotNil(fixture.model.flows[fixture.otherSkill.id])
        XCTAssertFalse(fixture.disk.generationIsCurrent(skillID: fixture.skill.id, generation: generation))
        XCTAssertEqual(fixture.disk.beginRequest(skillID: fixture.skill.id, superseding: false), generation + 2,
                       "One removal fence, then one revival generation")
        let directory = fixture.disk.directory
        XCTAssertFalse(fileService.fileExists(at: directory + "/" + fixture.skill.id.uuidString.lowercased() + ".json"))
        XCTAssertFalse(fileService.fileExists(at: directory + "/" + diskOnly.id.uuidString.lowercased() + ".json"))
        XCTAssertTrue(fileService.fileExists(at: directory + "/" + fixture.otherSkill.id.uuidString.lowercased() + ".json"))
    }
}
