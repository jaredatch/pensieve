import XCTest
import SwiftData
@testable import Pensieve

/// Named `Batch` (not `BatchTests`) so the frozen 04.5-a selector `./script/test.sh --filter Batch`
/// — i.e. `xcodebuild -only-testing PensieveTests/Batch`, an EXACT class match — actually runs it.
final class Batch: XCTestCase {

    private struct StubDetection: AgentDetectionServiceProtocol {
        func isInstalled(_ platform: PlatformTarget) -> Bool { false }
        func installedPlatforms() -> [PlatformTarget] { [] }
    }

    private struct StubError: LocalizedError {
        var errorDescription: String? { "stub link failure" }
    }

    private struct StubFileService: FileServiceProtocol {
        func readFile(at path: String) throws -> String { "" }
        func writeFile(at path: String, content: String) throws {}
        func deleteFile(at path: String) throws {}
        func fileExists(at path: String) -> Bool { false }
        func isExecutableFile(at path: String) -> Bool { false }
        func directoryExists(at path: String) -> Bool { false }
        func createDirectory(at path: String) throws {}
        func deleteDirectory(at path: String) throws {}
        func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
        func symlinkTarget(at path: String) throws -> String { "" }
        func isSymlink(at path: String) -> Bool { false }
        func isRegularFile(at path: String) -> Bool { true }
        func listDirectory(at path: String) throws -> [String] { [] }
        func contentsHash(at path: String) throws -> String { "hash" }
    }

    /// Stub link service: throws for a designated set of (directoryName, platform) pairs, records
    /// the rest. No filesystem touched — succeeding pairs do NOT write into real agent dirs.
    private final class StubLinkService: LinkServiceProtocol {
        /// keys "directoryName|platform.rawValue" that should throw on link()/unlink().
        var failingLink: Set<String> = []
        var failingUnlink: Set<String> = []
        private(set) var linked: [String] = []
        private(set) var unlinked: [String] = []

        private func key(_ s: Skill, _ p: PlatformTarget) -> String { "\(s.directoryName)|\(p.rawValue)" }

        func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
            if failingLink.contains(key(skill, platform)) { throw StubError() }
            linked.append(key(skill, platform))
        }
        func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
            if failingUnlink.contains(key(skill, platform)) { throw StubError() }
            unlinked.append(key(skill, platform))
        }
        func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }

        func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }
        func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            "/tmp/stub-link/\(skill.directoryName)"
        }
        func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            "/tmp/stub-target/\(skill.directoryName)"
        }
        func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, DeployRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeDeployStateStore() -> DeployStateStore {
        DeployStateStore(
            fileService: FileService(),
            appSupportDir: NSTemporaryDirectory() + "PensieveBatchTests-\(UUID().uuidString)"
        )
    }

    func testReadFailureIsNotAPairOutcome() {
        let result = BatchResult.readFailure("deployment state", error: StubError())

        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.readFailures.count, 1)
        XCTAssertTrue(result.readFailures[0].message.contains("stub link failure"))
        XCTAssertTrue(result.readFailures[0].message.contains("stopped before changing any deploys"))
        XCTAssertFalse(result.readFailures[0].message.localizedCaseInsensitiveContains("nothing changed"))
        XCTAssertFalse(result.readFailures[0].message.localizedCaseInsensitiveContains("relaunch"))
    }

    func testProjectRemovalReadFailureMessageNamesNoDeployCount() {
        let result = BatchResult.readFailure("project deploy intent ownership", error: StubError())

        let message = ProjectListView.removalFailureMessage(projectName: "Example", result: result)

        XCTAssertTrue(message.contains("Removal stopped because Pensieve couldn't read its deploy records"))
        XCTAssertTrue(message.contains("“Example” stays registered"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("nothing was changed"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("deploy(s) failed"))
    }

    @MainActor
    func testDeployBatchContinuesPastSingleFailureAndReportsExactlyOne() throws {
        let context = try makeContext()
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let bravo = Skill(name: "Bravo", directoryName: "bravo")
        [alpha, bravo].forEach(context.insert)

        let stub = StubLinkService()
        // Designate EXACTLY one failing pair, chosen so the test catches BOTH abort shapes:
        // the pairs run alpha×claude, alpha×openClaw, bravo×claude, bravo×openClaw. Failing
        // bravo×claude means (a) the two alpha pairs succeed BEFORE it (proves pre-failure
        // recording), (b) bravo×openClaw runs AFTER it for the SAME skill — so an inner-loop
        // `break` in the deploy catch would drop bravo×openClaw, AND (c) an outer `return`/rethrow
        // drops it too. Either regression makes the success-count assertion go red.
        stub.failingLink = ["bravo|\(PlatformTarget.claudeCode.rawValue)"]

        let vm = PlatformViewModel(
            fileService: StubFileService(),
            linkService: stub,
            agentDetection: StubDetection(),
            deployStateStore: makeDeployStateStore()
        )

        let result = vm.deployBatch(
            skills: [alpha, bravo],
            platforms: [.claudeCode, .openClaw],
            context: context
        )

        // 2 skills × 2 platforms = 4 attempted pairs.
        XCTAssertEqual(result.outcomes.count, 4)
        // Resilience: exactly one failure, the rest succeeded.
        XCTAssertEqual(result.failures.count, 1, "one bad pair must not abort the rest")
        XCTAssertEqual(result.successes.count, 3)

        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.skillName, "Bravo")
        XCTAssertEqual(failure.platform, .claudeCode)
        XCTAssertFalse((failure.error ?? "").isEmpty, "the failure carries a message")

        // One DeployRecord per successful pair, none for the failed pair.
        let records = try context.fetch(FetchDescriptor<DeployRecord>())
        XCTAssertEqual(records.count, 3)

        // The stub actually linked the three good pairs (and not the failed bravo×claude one) —
        // crucially including bravo×openClaw, which runs AFTER the failure for the same skill.
        XCTAssertEqual(
            Set(stub.linked),
            [
                "alpha|\(PlatformTarget.claudeCode.rawValue)",
                "alpha|\(PlatformTarget.openClaw.rawValue)",
                "bravo|\(PlatformTarget.openClaw.rawValue)"
            ]
        )
    }

    @MainActor
    func testRemoveBatchContinuesPastSingleFailureAndReportsExactlyOne() throws {
        let context = try makeContext()
        let alpha = Skill(name: "Alpha", directoryName: "alpha")
        let bravo = Skill(name: "Bravo", directoryName: "bravo")
        [alpha, bravo].forEach(context.insert)

        let stub = StubLinkService()
        stub.failingUnlink = ["alpha|\(PlatformTarget.claudeCode.rawValue)"]

        let vm = PlatformViewModel(
            fileService: StubFileService(),
            linkService: stub,
            agentDetection: StubDetection(),
            deployStateStore: makeDeployStateStore()
        )

        let result = vm.removeBatch(skills: [alpha, bravo], platforms: [.claudeCode, .openClaw])

        XCTAssertEqual(result.outcomes.count, 4)
        XCTAssertEqual(result.failures.count, 1, "one bad pair must not abort the rest")
        XCTAssertEqual(result.successes.count, 3)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.skillName, "Alpha")
        XCTAssertEqual(failure.platform, .claudeCode)
    }
}
