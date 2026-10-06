import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    func testRemovalAPIRequiresClassifiedPairsInsteadOfUnusedCartesianBatch() throws {
        let admitted = "func probe(_ vm: PlatformViewModel, _ skill: Skill) { "
            + "_ = vm.removeOwnedBatch(pairs: [DeployRemovalPair(skill: skill, platform: .cursor)], target: .userWide) }"
        let obsolete = "func probe(_ vm: PlatformViewModel, _ skill: Skill) { "
            + "_ = vm.removeBatch(skills: [skill], platforms: [.cursor], target: .userWide) }"
        XCTAssertEqual(try checkRemovalBoundary(admitted).0, 0)
        XCTAssertNotEqual(try checkRemovalBoundary(obsolete).0, 0,
                          "The unused Cartesian removal API must be unavailable")
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
