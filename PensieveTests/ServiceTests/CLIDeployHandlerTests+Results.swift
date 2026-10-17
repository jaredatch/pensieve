import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension CLIDeployHandlerTests {
    func testSavedIntentWithFailedReconcileReportsPartialAsTheWindowDoes() async throws {
        let h = try CLIDeployFixture(reconcile: { context in
            var result = BatchResult()
            for skill in (try? context.fetch(FetchDescriptor<Skill>())) ?? [] {
                result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name,
                    platform: .claudeCode, target: .userWide, error: "fixture reconcile failure"))
            }
            return result
        })
        let result = await h.handler.handle(h.request(), context: h.context)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.envelope.error?.code, "partial")
        XCTAssertEqual(result.envelope.changed, true)
        XCTAssertEqual(fields(result)["intentSaved"], .bool(true))
        XCTAssertFalse(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
        XCTAssertEqual(try h.intents().count, 1)
        let window = DeployIntentModel(service: h.service)
        let batch = try window.set(true, skill: h.other, platform: .claudeCode, target: .userWide, context: h.context)
        XCTAssertEqual(batch.failures.first?.error, "fixture reconcile failure")
        XCTAssertNotNil(window.error)
        XCTAssertFalse(h.platform.isDeployed(skill: h.other, platform: .claudeCode))
        let readFailure = "fixture shared read failure"
        let multi = try CLIDeployFixture(reconcile: { _ in
            var result = BatchResult()
            result.readFailures = [BatchReadFailure(message: readFailure)]
            return result
        })
        let reply = await multi.handler.handle(multi.request(skills: [multi.skill.directoryName, multi.other.directoryName]),
            context: multi.context)
        XCTAssertEqual(reply.exitCode, 1)
        XCTAssertEqual(fields(reply)["failures"], .array([.string(readFailure)]), "A shared read failure is reported once")
        XCTAssertEqual(reply.envelope.error?.message, readFailure)
        let remote = await multi.handler.handle(multi.request(machines: ["Mini"]), context: multi.context)
        XCTAssertEqual(remote.exitCode, 1, "Remote intent still reports shared reconciliation read failures")
        XCTAssertEqual(remote.envelope.error?.code, "partial")
        XCTAssertEqual(fields(remote)["failures"], .array([.string(readFailure)]))
    }

    func testKeylessArtifactWrittenBeforeSaveFailureReportsPartial() async throws {
        let h = try CLIDeployFixture(platformSave: { _ in throw DeployStubFailure() })
        let result = await h.handler.handle(h.request(project: "Local"), context: h.context)
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .claudeCode, target: .project(h.keyless)))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.envelope.error?.code, "partial")
        XCTAssertEqual(result.envelope.changed, true)
        XCTAssertEqual(fields(result)["intentSaved"], .bool(false))
        guard case let .array(results) = fields(result)["results"], case let .object(pair) = results.first else {
            return XCTFail("Missing partial result")
        }
        XCTAssertEqual(pair["artifactWritten"], .bool(true))
        XCTAssertEqual(pair["applied"], .bool(false), "The pair's metadata save failed")
        XCTAssertTrue(try h.intents().isEmpty)
    }

    func testFailedManifestRestoreNamesTheDiskChangeAsPartial() async throws {
        var writes = 0
        let h = try CLIDeployFixture(save: { _ in throw DeployStubFailure() }, beforeManifestWrite: {
            writes += 1
            if writes > 1 { throw DeployStubFailure() }
        })
        let result = await h.handler.handle(h.request(), context: h.context)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.envelope.error?.code, "partial")
        XCTAssertEqual(result.envelope.changed, true)
        XCTAssertEqual(fields(result)["manifestMayHaveChanged"], .bool(true))
        XCTAssertTrue(try h.intents().isEmpty)
        let manifest = try NativeTestWork.run { try h.manifest.read(fromRoot: h.root) }
        XCTAssertEqual(manifest.deployIntents.count, 1, "The first manifest was published before its restore failed")
        XCTAssertFalse(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
    }

}
