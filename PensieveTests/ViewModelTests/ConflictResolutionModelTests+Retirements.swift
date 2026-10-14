import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func assertProtectedConflictGuidance(counterpart: String, nestedOnThisMac: Bool) async throws {
        let fixture = try NativeTestWork.run {
            let entry: SyncConflictByteFixture.Entry?
            switch counterpart {
            case "folder": entry = .folder
            case "missing": entry = .file(Data("unavailable file".utf8))
            default: entry = nil
            }
            return try SyncConflictByteFixture.gitlinkConflict(both: counterpart == "gitlink", otherEntry: entry,
                changedEntryOnThisMachine: !nestedOnThisMac, skillRoot: true)
        }
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let engine = try NativeTestWork.run {
            try counterpart == "missing" ? fixture.missingObjectEngine(stage: nestedOnThisMac ? 2 : 3) : fixture.engine
        }
        let model = ConflictResolutionModel(engine: engine, git: fixture.git,
            credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: SyncStepModel())
        await model.loadAndReport(container: fixture.contextB.container)
        let groups = try readyGroups(from: model.phase)
        let group = try XCTUnwrap(groups.first { $0.items.contains { $0.path == fixture.path } })
        let item = try XCTUnwrap(group.items.first { $0.path == fixture.path })
        let strings = await renderedComparison(item)
        XCTAssertFalse(strings.contains("Choosing a nested repository or a deletion stops syncing this path. "
            + "Whatever is at this path on this Mac stays where it is."))
        let noChoice = counterpart == "gitlink" || counterpart == "missing"
        let message = "Pensieve can’t resolve this conflict. Resolve it in git: " + fixture.path
        if noChoice {
            XCTAssertTrue(strings.contains(message), "No available version must explain git resolution: \(counterpart)")
        } else {
            XCTAssertTrue(strings.contains("The nested repository can’t be chosen at this path."))
            XCTAssertTrue(strings.contains("Choosing the other version removes the nested repository from sync. "
                + "A folder and its contents stay on this Mac. A file or link at this path is deleted. "
                + "A nested repository kept after deletion stays local, including new files. "
                + "New files in an ordinary folder can sync."))
        }
        let nestedSide: ConflictSide = nestedOnThisMac ? .thisMachine : .otherMachine
        let otherSide: ConflictSide = nestedOnThisMac ? .otherMachine : .thisMachine
        model.choose(group.id, nestedSide)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.selectionError, noChoice ? message
            : "Pensieve can’t sync the nested repository at " + fixture.path + ". Choose the other version.")
        for card in try readyGroups(from: model.phase) where card.id != group.id { model.choose(card.id, otherSide) }
        model.choose(group.id, otherSide)
        XCTAssertEqual(model.canApply, !noChoice)
        if noChoice { XCTAssertEqual(model.selectionError, message) }
    }
}
