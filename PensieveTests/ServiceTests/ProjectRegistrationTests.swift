import XCTest
@testable import Pensieve

final class ProjectRegistrationTests: XCTestCase {
    func testMakeProjectStoresRemoteIdentity() {
        let project = ProjectRegistration.makeProject(
            name: "Pensieve",
            path: "/tmp/pensieve",
            using: StubProjectIdentityService(result: .success(ProjectIdentity(kind: .remote, key: "github.com/owner/repo")))
        )

        XCTAssertEqual(project.identityKey, "github.com/owner/repo")
        XCTAssertEqual(project.identityKind, "remote")
    }

    func testMakeProjectStoresMarkerIdentity() {
        let uuid = "11111111-2222-3333-4444-555555555555"

        let project = ProjectRegistration.makeProject(
            name: "Local Project",
            path: "/tmp/local-project",
            using: StubProjectIdentityService(result: .success(ProjectIdentity(kind: .marker, key: uuid)))
        )

        XCTAssertEqual(project.identityKey, uuid)
        XCTAssertEqual(project.identityKind, "marker")
    }

    func testMakeProjectLeavesIdentityPendingWhenServiceThrows() {
        let project = ProjectRegistration.makeProject(
            name: "Pending Project",
            path: "/tmp/pending-project",
            using: StubProjectIdentityService(result: .failure(StubError.identityUnavailable))
        )

        XCTAssertNil(project.identityKey)
        XCTAssertNil(project.identityKind)
    }
}

private struct StubProjectIdentityService: ProjectIdentityServiceProtocol {
    let result: Result<ProjectIdentity, Error>

    func identity(forProjectAt path: String) throws -> ProjectIdentity {
        try result.get()
    }

    func peekIdentity(forProjectAt path: String) -> ProjectIdentity? {
        try? result.get()
    }
}

private enum StubError: Error {
    case identityUnavailable
}
