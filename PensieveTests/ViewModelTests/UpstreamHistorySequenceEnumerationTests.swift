import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistorySequenceEnumerationTests: UpstreamHistoryCacheTestCase {
    enum Intervening: String, CaseIterable { case none, manual, skillSwitch, remove }

    struct Scenario {
        let seed: UpstreamHistorySequenceFixture.Seed
        var moved = false
        var fails = false
        var changed = false
        var intervening = Intervening.none

        var name: String {
            let baseline = "\(seed.rawValue)-\(moved)-\(fails)-\(changed)"
            return intervening == .none ? baseline : baseline + "." + intervening.rawValue
        }
    }

    private var scenarios: [Scenario] {
        let baseline = [
            Scenario(seed: .empty), Scenario(seed: .empty, fails: true),
            Scenario(seed: .disk), Scenario(seed: .disk, moved: true), Scenario(seed: .disk, fails: true),
            Scenario(seed: .memory), Scenario(seed: .memory, moved: true), Scenario(seed: .memory, fails: true),
            Scenario(seed: .memory, changed: true), Scenario(seed: .memory, moved: true, changed: true),
            Scenario(seed: .memory, fails: true, changed: true)
        ]
        return Intervening.allCases.flatMap { event in baseline.map { item in
            var scenario = item
            scenario.intervening = event
            return scenario
        } }
    }

    private func scenarios(for intervening: Intervening) -> [Scenario] {
        scenarios.filter { $0.intervening == intervening }
    }

    func testEveryReachableTwoRequestOrderWithoutInterveningEvent() async throws {
        try await sweep(.none)
    }

    func testEveryReachableTwoRequestOrderWithManualCheck() async throws {
        try await sweep(.manual)
    }

    func testEveryReachableTwoRequestOrderWithSkillSwitch() async throws {
        try await sweep(.skillSwitch)
    }

    func testEveryReachableTwoRequestOrderWithRemoval() async throws {
        try await sweep(.remove)
    }

    func testTwoRequestOrderSubsetsPartitionExpectedScenarios() {
        let names = Intervening.allCases.flatMap { scenarios(for: $0).map(\.name) }
        XCTAssertEqual(names.count, 44, "The subsets must run all 44 scenarios")
        XCTAssertEqual(Set(names).count, names.count, "The subsets must not repeat a scenario")
        XCTAssertEqual(Set(names), Set(HistorySequenceCoverage.expected.keys), "The subsets must cover the exact domain")
    }

    func testExactCountsRejectExtraReadProbeAndPersist() async throws {
        for extra in ["read", "probe", "persist"] {
            let fixture = try sequenceFixture(.memory)
            let scenario = Scenario(seed: .memory, changed: true, intervening: .manual)
            enqueue(scenario, fixture: fixture)
            try await fixture.flow.run(["A.request", "localEdits1.start", "event.request", "B.request"])
            try await fixture.flow.drain()
            try assertInvariants(fixture, scenario: scenario)
            switch extra {
            case "read", "probe": fixture.calls.append(extra)
            case "persist":
                let id = UUID()
                fixture.flow.hooks.started(.persist, id)
                fixture.flow.hooks.applied(id)
            default: break
            }
            XCTExpectFailure("The exact table counts must reject an extra \(extra)") {
                do {
                    try checkBounds(fixture, scenario: scenario)
                    try assertInvariants(fixture, scenario: scenario)
                } catch { XCTFail(String(describing: error)) }
            }
            await fixture.flow.close()
        }
    }

    func testLateChecksReuseTheBaselineDomain() {
        XCTAssertEqual(scenarios.count, 44, "Late checks must reuse drained baseline fixtures")
        XCTAssertEqual(scenarios.filter { $0.intervening == .none }.count, 11)
    }

    func testHiddenCheckAfterBothRequestsFinishRemainsPending() async throws {
        let fixture = try sequenceFixture(.memory)
        let scenario = Scenario(seed: .memory)
        enqueue(scenario, fixture: fixture)
        try await fixture.flow.drain()
        try assertInvariants(fixture, scenario: scenario)
        try await applyLateCheck(scenario, fixture: fixture)
        await fixture.flow.close()
    }

    func testLateCheckRejectsANonBaselineScenarioWithoutStartingAnEvent() async throws {
        let fixture = try sequenceFixture(.memory)
        do {
            try await applyLateCheck(Scenario(seed: .memory, intervening: .manual), fixture: fixture)
            XCTFail("A non-baseline late check must throw")
        } catch {
            XCTAssertEqual(String(describing: error), "Late checks require a baseline scenario")
        }
        XCTAssertTrue(fixture.flow.scheduled.isEmpty)
        await fixture.flow.close()
    }

    private func applyLateCheck(_ scenario: Scenario, fixture: UpstreamHistorySequenceFixture) async throws {
        guard scenario.intervening == .none else {
            throw HistorySequenceFailure("Late checks require a baseline scenario")
        }
        XCTAssertEqual(fixture.flow.lanes["A"], .done)
        XCTAssertEqual(fixture.flow.lanes["B"], .done)
        XCTAssertTrue(fixture.flow.finished)
        fixture.flow.enqueue("event") { fixture.model.invalidateForManualCheck(skillID: fixture.skill.id) }
        try await fixture.flow.release("event.request")
        try fixture.flow.validateApplications()
        try fixture.validatePublications()
        try assertInvariants(fixture, scenario: scenario, lateCheck: true)
    }

    private func sweep(_ intervening: Intervening) async throws {
        var results: [String: (complete: Int, excluded: Int)] = [:]
        for scenario in scenarios(for: intervening) {
            guard let count = try await enumerate(scenario) else { return }
            XCTAssertGreaterThan(count, 0, scenario.name)
            results[scenario.name] = (count, 0)
            print("HISTORY_REDUCER_COUNT \(scenario.name) \(count)")
        }
        let expectedNames = HistorySequenceCoverage.expected.keys.filter { name in
            intervening == .none ? !name.contains(".") : name.hasSuffix("." + intervening.rawValue)
        }
        XCTAssertEqual(Set(results.keys), Set(expectedNames), "Missing or unexpected scenarios: \(intervening.rawValue)")
        for name in expectedNames.sorted() {
            guard let count = results[name] else {
                XCTFail("Missing scenario: \(name)")
                continue
            }
            print("HISTORY_SEQUENCE_ORDERS \(name) passed=\(count.complete) excludedPrefixes=\(count.excluded)")
            try HistorySequenceCoverage.validate(name, complete: count.complete, excluded: count.excluded)
        }
    }

    private func enumerate(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) async throws -> Int? {
        var prefixes: [[String]] = [[]]
        var completed: Set<[String]> = []
        while let prefix = prefixes.popLast() {
            let fixture = try sequenceFixture(scenario.seed, moved: scenario.moved, fails: scenario.fails)
            enqueue(scenario, fixture: fixture)
            let flow = fixture.flow
            flow.scenario = scenario.name
            let succeeded = await flow.checkRun(file: file, line: line, report: { XCTFail("\(scenario.name): \($0)") }, body: {
                try await flow.run(prefix)
                try await flow.settle()
                while !flow.finished {
                    let choices = flow.enabled
                    let first = try XCTUnwrap(choices.first, "No enabled event: \(flow.scheduled)")
                    for alternate in choices.dropFirst() { prefixes.append(flow.scheduled + [alternate]) }
                    try await flow.release(first)
                    try checkBounds(fixture, scenario: scenario)
                }
                XCTAssertTrue(completed.insert(flow.scheduled).inserted, "Duplicate generated order")
                try flow.validateApplications()
                try fixture.validatePublications()
                try assertInvariants(fixture, scenario: scenario)
                if scenario.intervening == .none {
                    try await applyLateCheck(scenario, fixture: fixture)
                }
            })
            guard succeeded else { return nil }
        }
        return completed.count
    }

    private func enqueue(_ scenario: Scenario, fixture: UpstreamHistorySequenceFixture) {
        fixture.enqueue("A", changed: scenario.changed)
        let model = fixture.model
        switch scenario.intervening {
        case .none: break
        case .manual:
            fixture.flow.enqueue("event", after: "A") { model.invalidateForManualCheck(skillID: fixture.skill.id) }
        case .skillSwitch:
            fixture.flow.enqueue("event", after: "A") { await model.request(skill: fixture.otherSkill) }
        case .remove:
            fixture.flow.enqueue("event", after: "A") { model.remove(skillID: fixture.skill.id) }
        }
        fixture.enqueue("B", after: scenario.intervening == .none ? "A" : "event",
                        changed: scenario.changed, intent: .mountedRefresh)
    }

    private func checkBounds(_ fixture: UpstreamHistorySequenceFixture, scenario: Scenario) throws {
        let limit = scenario.intervening == .manual || scenario.intervening == .remove ? 2 : 1
        let reads = fixture.calls.values.filter { $0 == "read" }.count
        guard reads <= limit, fixture.calls.values.filter({ $0 == "probe" }).count <= 1 else {
            throw HistorySequenceFailure("Unrequested network work: \(fixture.calls.values); \(fixture.flow.scheduled)")
        }
    }

    private func assertInvariants(_ fixture: UpstreamHistorySequenceFixture, scenario: Scenario,
                                  lateCheck: Bool = false) throws {
        let calls = fixture.calls.values
        let context = "\(scenario.name): \(fixture.flow.scheduled.joined(separator: ","))"
        if fixture.flow.finished, fixture.model.flows[fixture.skill.id]?.jobs.isEmpty == true,
           fixture.model.currentRequest != nil {
            switch fixture.model.state {
            case .loading, .refreshing:
                throw HistorySequenceFailure("Finished requests left a transient visible state: \(context)")
            default: break
            }
        }
        let expected = HistorySequenceExpectations(scenario, events: fixture.flow.scheduled)
        XCTAssertEqual(calls.filter { $0 == "read" }.count, expected.reads, context)
        XCTAssertEqual(calls.filter { $0 == "probe" }.count, expected.probes, context)
        XCTAssertEqual(fixture.flow.work.values.filter { $0.kind == .persist }.count, expected.persists, context)
        for (event, count) in expected.readPublications {
            XCTAssertEqual(fixture.flow.publications.filter { $0.event == event }.count, count, context)
        }
        XCTAssertFalse(fixture.flow.publications.contains { $0.event.hasPrefix("persist") }, context)
        XCTAssertEqual(fixture.model.flows[fixture.skill.id]?.manualPending == true, lateCheck, context)
        let externalRead = scenario.intervening == .manual || scenario.intervening == .remove
        let expectedRead = expected.reads > 0
        XCTAssertFalse(calls.contains("otherRead"), context)
        if scenario.fails {
            switch fixture.model.state {
            case .failed where scenario.seed == .empty || scenario.intervening == .remove: break
            case let .loadedWithFailure(result, _): XCTAssertEqual(result, fixture.kept, context)
            default: XCTFail("Lost failure: \(context)")
            }
        } else {
            let fresh = externalRead || scenario.seed == .empty || scenario.moved
            XCTAssertEqual(fixture.model.state, .loaded(fresh ? fixture.fresh : fixture.kept), context)
        }
        if !scenario.fails {
            let generation = fixture.disk.beginRequest(skillID: fixture.skill.id, superseding: false)
            let stored = fixture.disk.load(skillID: fixture.skill.id, origin: try origin(for: fixture.skill),
                                           minimumWindow: 1, generation: generation)
            if expectedRead { XCTAssertEqual(stored?.result, fixture.fresh, context) }
        }
    }
}
