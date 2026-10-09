import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillProvenanceViewModelTests: XCTestCase {
    func testEmptyInstalledOriginYieldsNoProvenance() {
        let model = makeProvenanceModel()
        let versioned = Skill(name: "PDF", directoryName: "pdf")
        versioned.installedOrigin = origin(path: "skills/pdf")
        let coordinateEmpty = Skill(name: "Damaged", directoryName: "damaged")
        coordinateEmpty.installedOrigin = .empty

        XCTAssertNil(model.provenance(for: coordinateEmpty))
        XCTAssertNotNil(model.provenance(for: versioned))
    }

    func testProvenanceLinksDatesAndDrift() async throws {
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let source = InstalledOrigin(
            repo: "https://github.com/anthropics/skills",
            path: "skills/pdf",
            ref: "main",
            installedCommit: "0123456789abcdef",
            installedTree: "tree",
            contentHash: "sha256:content",
            installedAt: installedAt,
            updatedAt: updatedAt
        )

        let provenance = SkillProvenanceViewModel.provenance(
            origin: source,
            driftedLocally: true,
            checkError: "Repository unavailable"
        )

        XCTAssertEqual(provenance.installedAt, installedAt)
        XCTAssertEqual(provenance.updatedAt, updatedAt)
        XCTAssertEqual(provenance.trackedRef, "main")
        XCTAssertEqual(provenance.shortCommit, "0123456")
        XCTAssertEqual(provenance.repositoryURL?.absoluteString,
                       "https://github.com/anthropics/skills")
        XCTAssertEqual(provenance.skillURL?.absoluteString,
                       "https://github.com/anthropics/skills/tree/main/skills/pdf")
        XCTAssertEqual(provenance.localEditNote, "This copy has local edits")
        XCTAssertEqual(provenance.checkError, "Repository unavailable")

        let root = SkillProvenanceViewModel.provenance(
            origin: origin(path: ""),
            driftedLocally: false,
            checkError: nil
        )
        XCTAssertNil(root.skillURL, "a root skill must not duplicate the repository link")
        XCTAssertNil(root.localEditNote)

        let skill = Skill(name: "PDF", directoryName: "pdf")
        skill.installedOrigin = source
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(skill)
        try context.save()
        var driftRanOnMainThread = true
        let model = makeProvenanceModel(driftOperation: { _, _ in
            driftRanOnMainThread = Thread.isMainThread
            return true
        })

        await model.present(skillID: skill.id, context: context)

        XCTAssertFalse(driftRanOnMainThread)
        XCTAssertEqual(model.provenance(for: skill)?.localEditNote,
                       "This copy has local edits")
    }

    func testCheckStateAndResultReflectImmediately() async throws {
        let skill = Skill(name: "PDF", directoryName: "pdf")
        skill.installedOrigin = origin(path: "skills/pdf")
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(skill)
        try context.save()
        var checkRanOnMainThread = true
        let model = makeProvenanceModel(checkOperation: { _, _ in
            checkRanOnMainThread = Thread.isMainThread
            return SkillUpdateCheckResult(updateAvailable: true, checkError: nil)
        })

        model.checkForUpdates(skillID: skill.id, context: context)
        XCTAssertTrue(model.isChecking(skillID: skill.id))
        await TestWait.until(failureMessage: "skill provenance check did not finish") {
            !model.isChecking(skillID: skill.id)
        }

        XCTAssertFalse(checkRanOnMainThread)
        XCTAssertEqual(model.provenance(for: skill)?.updateAvailable, true)

        XCTAssertTrue(skill.updateAvailable, "the fresh persisted result must merge into the presented row")
        skill.updateAvailable = false
        skill.checkError = "A later automatic check failed"
        let refreshed = try XCTUnwrap(model.provenance(for: skill))
        XCTAssertFalse(refreshed.updateAvailable)
        XCTAssertEqual(refreshed.checkError, "A later automatic check failed")

        let failing = makeProvenanceModel(checkOperation: { _, _ in
            throw UpdateCheckError.repositoryMovedDuringCheck
        })
        failing.checkForUpdates(skillID: skill.id, context: context)
        await TestWait.until(failureMessage: "failing skill provenance check did not finish") {
            !failing.isChecking(skillID: skill.id)
        }
        XCTAssertEqual(failing.provenance(for: skill)?.checkError,
                       UpdateCheckError.repositoryMovedDuringCheck.localizedDescription)
        failing.recordCheckResult(
            SkillUpdateCheckResult(updateAvailable: true, checkError: nil),
            on: skill
        )
        XCTAssertTrue(try XCTUnwrap(failing.provenance(for: skill)).updateAvailable)
        XCTAssertNil(failing.provenance(for: skill)?.checkError)
    }

    func testSkillURLRejectsUnsafeStoredCoordinates() {
        for scalar in PathJoiningScalars.values {
            let absolute = origin(path: "/" + PathJoiningScalars.name("pdf", scalar: scalar))
            XCTAssertNil(SkillProvenanceViewModel.provenance(
                origin: absolute, driftedLocally: false, checkError: nil).skillURL)
        }
        let unsafePath = origin(path: "skills/../private")
        XCTAssertNil(SkillProvenanceViewModel.provenance(
            origin: unsafePath,
            driftedLocally: false,
            checkError: nil
        ).skillURL)

        var unsafeRef = origin(path: "skills/pdf")
        unsafeRef.ref = "release/../private"
        XCTAssertNil(SkillProvenanceViewModel.provenance(
            origin: unsafeRef,
            driftedLocally: false,
            checkError: nil
        ).skillURL)
    }

    func testAdoptModePreselectsExactlyOneCandidate() async {
        let target = Skill(name: "My Skill", directoryName: "my-skill")
        let service = AdoptionService(candidates: [candidate("upstream")])
        let model = SkillInstallViewModel(service: service)
        model.prepareAdoption(of: target)
        model.urlText = "https://github.com/anthropics/skills/tree/main/skills/upstream"

        await model.fetchAndReport()

        XCTAssertEqual(model.state, .picking)
        XCTAssertTrue(model.isAdoptMode)
        XCTAssertTrue(model.isTargetedConfirmation)
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(model.repositoryIdentity, "anthropics/skills")
        XCTAssertEqual(model.adoptTarget?.skillID, target.id)
        XCTAssertEqual(model.adoptTarget?.slug, "my-skill")
    }

    func testAdoptModeRejectsAmbiguityAndSurfacesDriftImmediately() async throws {
        let target = Skill(name: "My Skill", directoryName: "my-skill")
        let ambiguous = SkillInstallViewModel(
            service: AdoptionService(candidates: [candidate("one"), candidate("two")])
        )
        ambiguous.prepareAdoption(of: target)
        ambiguous.urlText = "https://github.com/anthropics/skills"
        await ambiguous.fetchAndReport()
        guard case let .failed(reason) = ambiguous.state else {
            return XCTFail("multiple candidates must not be silently selected")
        }
        XCTAssertTrue(reason.contains("exactly one skill"))
        XCTAssertEqual(ambiguous.selectedCount, 0)

        let service = AdoptionService(candidates: [candidate("upstream")], result: .localDrift)
        let model = SkillInstallViewModel(service: service)
        model.prepareAdoption(of: target)
        model.urlText = "https://github.com/anthropics/skills/tree/main/skills/upstream"
        await model.fetchAndReport()
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(target)
        try context.save()
        await model.confirmAndReport(context: context)

        XCTAssertEqual(model.completedAdoptions.count, 1)
        let completion = try XCTUnwrap(model.completedAdoptions.first)
        XCTAssertEqual(completion.skillID, target.id)
        XCTAssertTrue(completion.localDrift)
        XCTAssertNotNil(try? JSONDecoder().decode(InstalledOrigin.self,
                                                  from: completion.installedOriginData))
        XCTAssertEqual(model.reports.first?.result, .adopted(localDrift: true))

        let provenance = makeProvenanceModel()
        target.installedOrigin = nil
        provenance.recordAdoption(completion, on: target)
        XCTAssertEqual(target.installedOrigin?.path, "skills/upstream")
        XCTAssertEqual(provenance.provenance(for: target)?.localEditNote,
                       "This copy has local edits")
    }
}

private extension SkillProvenanceViewModelTests {
    func makeProvenanceModel(
        driftOperation: @escaping SkillProvenanceViewModel.DriftOperation = { _, _ in false },
        checkOperation: @escaping SkillProvenanceViewModel.CheckOperation = { _, _ in
            SkillUpdateCheckResult(updateAvailable: nil, checkError: nil)
        }
    ) -> SkillProvenanceViewModel {
        SkillProvenanceViewModel(
            driftOperation: driftOperation,
            checkOperation: checkOperation
        )
    }

    final class AdoptionService: SkillInstallServiceProtocol {
        let candidates: [SkillCandidate]
        let result: SkillAdoptResult

        init(candidates: [SkillCandidate], result: SkillAdoptResult = .clean) {
            self.candidates = candidates
            self.result = result
        }

        func fetch(repo: String, ref: String?, credential: GitCredential?) throws -> SkillFetchResult {
            fetchResult(repo: repo, ref: ref)
        }

        func fetch(repo: String, ref: String?, path: String,
                   credential: GitCredential?) throws -> SkillFetchResult {
            fetchResult(repo: repo, ref: ref)
        }

        func install(candidate: SkillCandidate, from source: SkillFetchResult,
                     credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                     context: ModelContext) throws -> SkillInstallResult {
            throw TestError.unexpectedMutation
        }

        func install(candidate: SkillCandidate, renamedTo slug: String, from source: SkillFetchResult,
                     credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                     context: ModelContext) throws -> SkillInstallResult {
            throw TestError.unexpectedMutation
        }

        func adopt(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                   credential: GitCredential?, context: ModelContext) throws -> SkillAdoptResult {
            guard let skill = try context.fetch(FetchDescriptor<Skill>()).first(where: {
                $0.directoryName == existingSlug
            }) else {
                throw SkillInstallError.existingSkillNotFound(existingSlug)
            }
            skill.installedOrigin = InstalledOrigin(
                repo: source.repo,
                path: candidate.path,
                ref: source.ref,
                installedCommit: source.headCommit,
                installedTree: candidate.treeHash,
                contentHash: "sha256:content",
                installedAt: Date(),
                updatedAt: Date()
            )
            try context.save()
            return result
        }

        func update(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                    credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                    context: ModelContext) throws {
            throw TestError.unexpectedMutation
        }

        private func fetchResult(repo: String, ref: String?) -> SkillFetchResult {
            SkillFetchResult(
                repo: repo,
                ref: ref ?? "main",
                headCommit: "head",
                candidates: candidates
            )
        }
    }

    enum TestError: Error {
        case unexpectedMutation
    }

    func candidate(_ slug: String) -> SkillCandidate {
        SkillCandidate(
            path: "skills/\(slug)",
            slug: slug,
            name: slug.capitalized,
            skillDescription: "Description",
            treeHash: "tree-\(slug)",
            containsSymlink: false,
            unavailableReason: nil
        )
    }

    func origin(path: String) -> InstalledOrigin {
        InstalledOrigin(
            repo: "https://github.com/anthropics/skills",
            path: path,
            ref: "main",
            installedCommit: "0123456789abcdef",
            installedTree: "tree",
            contentHash: "sha256:content",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }

    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Skill.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

}
