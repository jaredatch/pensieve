import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testAvailableBatchRemovalRetiresForeignAndAbsentPairsWithoutReportingRemoval() throws {
        for platform in [PlatformTarget.codex, .cursor] {
            for inProject in [false, true] {
                for absent in [false, true] {
                    let harness = try contextAndVM()
                    let project = reviewProject(harness.context)
                    let target: DeployTarget = inProject ? .project(project) : .userWide
                    let path = artifactPath(platform, project: target.project?.path)
                    if !absent {
                        try plant(owned: false, legacy: false, platform: platform,
                            path: path, project: target.project?.path)
                    }
                    try reviewRecord(harness.state, path: path, platform: platform, target: target)
                    let result = harness.vm.removeOwnedBatch(
                        pairs: [DeployRemovalPair(skill: skill, platform: platform)], target: target)
                    XCTAssertTrue(result.outcomes.isEmpty)
                    XCTAssertFalse(result.hasFailures)
                    XCTAssertEqual(result.retiredPairs,
                        [BatchPairKey(skillID: skill.id, platform: platform, target: BatchPairTarget(target))])
                    XCTAssertTrue(try harness.state.read().records.isEmpty)
                    if absent {
                        XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
                    } else if platform.usesSymlinks {
                        XCTAssertEqual(try mapped.symlinkTarget(at: path), root + "/foreign")
                    } else {
                        XCTAssertEqual(try mapped.readFile(at: path), "User rule")
                    }
                    if !absent { try mapped.deleteFile(at: path) }
                }
            }
        }
    }

    func testProjectRemovalFailureFormatterBelongsToModelInsteadOfView() throws {
        let expression = "(projectName: \"Example\", result: BatchResult())"
        let obsolete = try checkRemovalBoundary(
            "@MainActor func probe() { _ = ProjectListView.removalFailureMessage" + expression + " }")
        XCTAssertNotEqual(obsolete.0, 0, "The view must only display the model's message")
        let admitted = try checkRemovalBoundary(
            "@MainActor func probe() { _ = ProjectRemovalModel.removalFailureMessage" + expression + " }")
        XCTAssertEqual(admitted.0, 0, admitted.1)
    }

    private func checkRemovalBoundary(_ expression: String) throws -> (Int32, String) {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let source = root + "/removal-boundary.swift"
        try files.writeFile(at: source, content: "@testable import Pensieve\n" + expression + "\n")
        return try typecheckOwnershipProbe(source, products: checkout + "/DerivedData/Build/Products/Debug", checkout: checkout)
    }
}
