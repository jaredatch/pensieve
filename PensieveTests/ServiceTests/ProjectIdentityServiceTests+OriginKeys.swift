import XCTest
@testable import Pensieve

extension ProjectIdentityServiceTests {
    func testProjectsKeyedByTheirOriginKeepTheirIdentityKey() throws {
        try NativeTestWork.run {
            let files = FileService()
            let service = ProjectIdentityService(fileService: files)
            let root = TestTemporaryDirectory.path + "OriginKeys-" + UUID().uuidString
            try files.createDirectory(at: root)
            defer { try? files.deleteDirectory(at: root) }
            for (index, fixture) in Self.originKeyFixtures.enumerated() {
                let path = root + "/project-\(index)"
                try files.createDirectory(at: path)
                var commands = [["init", "--quiet"],
                                ["remote", "add", "upstream", "https://upstream.example/other/repo.git"],
                                ["remote", "add", "origin", fixture.url]]
                commands += fixture.extra
                for command in commands {
                    let result = try TestPaths.git.run(command, in: path)
                    XCTAssertEqual(result.exit, 0, result.stderr)
                }
                let expected = ProjectIdentity(kind: .remote, key: fixture.key)
                XCTAssertEqual(service.peekIdentity(forProjectAt: path), expected, fixture.url)
                let saved = try service.withIdentity(forProjectAt: path) { identity in
                    XCTAssertEqual(identity, expected, fixture.url)
                    return identity
                }
                XCTAssertEqual(saved.key, fixture.key)
                XCTAssertFalse(files.fileExists(at: path + "/.pensieve-project"), fixture.url)
            }

            // Pair the stable-key guard with the new registration behavior: git refuses the
            // whole config, so even an earlier valid origin must fall through to a marker.
            let path = root + "/corrupt-config"
            try files.createDirectory(at: path)
            for command in [["init", "--quiet"], ["remote", "add", "origin", "https://github.com/owner/repo.git"]] {
                let result = try TestPaths.git.run(command, in: path)
                XCTAssertEqual(result.exit, 0, result.stderr)
            }
            let config = try files.readFile(at: path + "/.git/config")
            try files.writeFile(at: path + "/.git/config", content: config + "\n[broken header]\n")
            XCTAssertNil(service.peekIdentity(forProjectAt: path))
            let saved = try service.withIdentity(forProjectAt: path) { $0 }
            XCTAssertEqual(saved.kind, .marker)
            XCTAssertNotNil(UUID(uuidString: saved.key))
            let marker = try files.readFile(at: path + "/.pensieve-project")
            XCTAssertEqual(ProjectIdentityService.parseMarkerID(from: marker), saved.key)
            XCTAssertEqual(service.peekIdentity(forProjectAt: path), saved)
        }
    }

    private static let originKeyFixtures: [OriginKeyFixture] = [
        OriginKeyFixture(url: "git@github.com:owner/repo.git", key: "github.com/owner/repo", extra: []),
        OriginKeyFixture(url: "https://GitHub.com/owner/repo.git", key: "github.com/owner/repo", extra: []),
        OriginKeyFixture(url: "ssh://git@github.com/owner/repo.git", key: "github.com/owner/repo", extra: []),
        OriginKeyFixture(url: "https://user@github.com/owner/repo.git", key: "github.com/owner/repo", extra: []),
        OriginKeyFixture(url: "https://github.com/owner/repo/", key: "github.com/owner/repo", extra: []),
        OriginKeyFixture(url: "git@github.com:owner/repo.git", key: "github.com/owner/repo", extra:
         [["remote", "set-url", "--add", "origin", "https://other.example/other/repo.git"]]),
        OriginKeyFixture(url: "https://github.com/owner/repo.git", key: "github.com/owner/repo", extra:
         [["remote", "set-url", "--push", "origin", "git@push.example:other/repo.git"]]),
        OriginKeyFixture(url: "https://github.com/owner/repo.git", key: "github.com/owner/repo", extra:
         [["config", "url.ssh://git@rewritten.example/.insteadOf", "https://github.com/"]])
    ]
}

private struct OriginKeyFixture {
    let url: String
    let key: String
    let extra: [[String]]
}
