import XCTest
@testable import Pensieve

@MainActor
final class SyncFailureAuditTests: XCTestCase {
    private let credentialedURL = "https://kept:tok-SECRET-215@fixture.test/store.git"
    // The fixed test URL is the single source of its synthetic credential; it contains a password by construction.
    private var token: String { URLComponents(string: credentialedURL)!.password! }

    func testEveryFailedCycleLogsItsReasonOnOneLine() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let gitError = GitError.commandFailed(args: ["push", "origin", "main"], exitCode: 1,
            stderr: "rejected push\nfatal: try again")
        let errors: [Error] = [gitError, SyncError.ingestIncomplete,
            SyncError.storeUnreadable(["manifest/skills/example.yaml is newer"]), ManifestError.damaged,
            ManifestError.corruptManifestFile("manifest/skills/example.yaml"),
            GitError.authenticationFailed(remote: "origin", detail: "refused"),
            ManifestRecoveryFailure(underlying: gitError)]
        for error in errors {
            _ = await h.run(error)
            let underlying = (error as? ManifestRecoveryFailure)?.underlying ?? error
            var expected = DisplayTextSanitizer.singleLine(underlying.localizedDescription)
            if case let SyncError.storeUnreadable(warnings) = underlying { expected += " " + warnings.joined(separator: " ") }
            let status = try h.status()
            XCTAssertEqual(status.result, "failed")
            XCTAssertEqual(status.detail, expected)
            XCTAssertFalse(["syncError", "storeUnreadable", "Sync failed."].contains(status.detail))
            XCTAssertEqual(status.detail.components(separatedBy: .newlines).count, 1)
            XCTAssertTrue(try h.log().hasSuffix("\(status.timestamp) failed \(status.detail)\n"))
            try await h.assertCommandReads(status)
        }
        let unusable = try await SyncFailureAuditFixture(usability: .licenseNotAccepted)
        defer { try? unusable.disk.remove() }
        _ = await unusable.run(SyncError.ingestIncomplete)
        let status = try unusable.status()
        XCTAssertEqual(status.detail, GitUsability.licenseNotAccepted.message)
        XCTAssertEqual(status.result, "failed")
        XCTAssertTrue(try unusable.log().hasSuffix("\(status.timestamp) failed \(status.detail)\n"))
        try await unusable.assertCommandReads(status)
    }

    func testAFailureWithNoMessageOfItsOwnLogsItsTypeAndTheWindowShowsWhatItSays() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let errors: [(Error, [String])] = [
            (NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSFilePathErrorKey: h.disk.root]),
             ["NSError", "NSPOSIXErrorDomain", "28", "No space left on device"]),
            (UnlocalizedAuditFailure.broken("disk vanished"), ["UnlocalizedAuditFailure", "broken", "disk vanished"])
        ]
        for (error, words) in errors {
            let result = await h.run(error)
            XCTAssertEqual(result, .failed(error.localizedDescription))
            let model = SyncModel(git: h.disk.paths.makeGitService(), root: h.disk.root)
            model.apply(result)
            XCTAssertEqual(model.state, .error(DisplayTextSanitizer.singleLine(error.localizedDescription)))
            let status = try h.status()
            for word in words { XCTAssertTrue(status.detail.contains(word), "Missing \(word) in fallback diagnosis") }
            XCTAssertTrue(try h.log().hasSuffix("\(status.timestamp) failed \(status.detail)\n"))
        }
    }

    func testFailedCycleLogKeepsTokensAndCredentialedURLsOut() async throws {
        let h = try await SyncFailureAuditFixture(token: token)
        defer { try? h.disk.remove() }
        let errors: [Error] = [
            GitError.commandFailed(args: ["push", credentialedURL], exitCode: 1,
                stderr: "rejected \(credentialedURL) fatal: retry"),
            GitError.commandFailed(args: ["fetch"], exitCode: 3,
                stderr: "\(token) fixture.test/store.git fatal: retry"),
            UnlocalizedAuditFailure.broken(credentialedURL), SyncError.rejectedRemote(credentialedURL)
        ]
        var details: [String] = []
        for error in errors {
            _ = await h.run(error)
            let detail = try h.status().detail
            details.append(detail)
            try h.assertNoSecrets([token, "kept:"])
        }
        for detail in details.prefix(3) { XCTAssertTrue(detail.contains("fixture.test/store.git")) }
        XCTAssertTrue(details[0].contains("git push https://fixture.test/store.git failed (exit 1): rejected"))
        XCTAssertTrue(details[0].contains("fatal: retry"))
        XCTAssertTrue(details[1].contains("git fetch failed (exit 3):"))
        XCTAssertTrue(details[1].contains("fatal: retry"))
        XCTAssertTrue(details[2].contains("UnlocalizedAuditFailure"))
        XCTAssertEqual(details[3], SyncError.rejectedRemote(credentialedURL).localizedDescription)
        h.rotate()
        let rotated = try h.log(".1")
        for detail in details { XCTAssertTrue(rotated.contains(detail)) }
        try h.assertNoSecrets([token, "kept:"])
        let runs = (0...(token.count - 5)).map { String(token.dropFirst($0).prefix(5)) }
        for filler in 0...14 {
            let reason = String(repeating: "x", count: filler) + String(repeating: token, count: 600)
            _ = await h.run(LiteralAuditFailure(text: reason))
            try h.assertNoSecrets(runs)
        }
        h.rotate()
        try h.assertNoSecrets(runs)
        let blank = try await SyncFailureAuditFixture(token: " \t\n")
        defer { try? blank.disk.remove() }
        let absent = try await SyncFailureAuditFixture()
        defer { try? absent.disk.remove() }
        let ordinary = LiteralAuditFailure(text: "words with spaces and tabs\tend")
        _ = await blank.run(ordinary)
        _ = await absent.run(ordinary)
        XCTAssertEqual(try blank.status().detail, try absent.status().detail)
    }

    func testSignInFailureLogKeepsTokensAndCredentialedURLsOut() async throws {
        let h = try await SyncFailureAuditFixture(token: token)
        defer { try? h.disk.remove() }
        let errors = [
            GitError.authenticationFailed(remote: credentialedURL, detail: "refused \(credentialedURL) retry"),
            GitError.authenticationFailed(remote: "https://fixture.test/store.git", detail: "refused \(token) retry"),
            GitError.authenticationFailed(remote: "git@example.com:store.git", detail: "refused retry")
        ]
        var details: [String] = []
        for (index, error) in errors.enumerated() {
            let remote = index == 2 ? "git@example.com:store.git" : "https://fixture.test/store.git"
            try NativeTestWork.run { try h.disk.paths.makeGitService().setRemote(remote, at: h.disk.root) }
            let result = await h.run(error)
            let auth = SyncAuthentication(remote: RemoteURLPolicy.parse(remote),
                credential: index == 2 ? .sshAgent : .httpsToken(username: "kept", token: token, host: "fixture.test"))
            XCTAssertEqual(result, .failed(try XCTUnwrap(auth.message())))
            details.append(try h.status().detail)
            try h.assertNoSecrets([token, "kept:"])
        }
        for detail in details.prefix(2) {
            XCTAssertTrue(detail.hasPrefix("Authentication to https://fixture.test/store.git failed: refused"))
            XCTAssertTrue(detail.hasSuffix("retry"))
        }
        XCTAssertTrue(details[2].contains("git@example.com:store.git"))
        h.rotate()
        for detail in details { XCTAssertTrue(try h.log(".1").contains(detail)) }
        try h.assertNoSecrets([token, "kept:"])
    }

    func testRepairFailureLogKeepsTokensAndCredentialedURLsOut() async throws {
        let h = try await SyncFailureAuditFixture(token: token)
        defer { try? h.disk.remove() }
        let errors: [Error] = [
            GitError.commandFailed(args: ["fetch", credentialedURL], exitCode: 4,
                stderr: "refused \(credentialedURL) retry"),
            GitError.authenticationFailed(remote: credentialedURL, detail: "refused \(credentialedURL) retry"),
            UnlocalizedAuditFailure.broken(credentialedURL)
        ]
        var details: [String] = []
        for error in errors {
            let result = await h.run(ManifestRecoveryFailure(underlying: error))
            var expected = ManifestError.damaged.localizedDescription
            if case GitError.authenticationFailed = error {
                expected += ". " + (SyncAuthentication(remote: RemoteURLPolicy.parse("https://fixture.test/store.git"),
                    credential: .httpsToken(username: "kept", token: token, host: "fixture.test")).message() ?? "")
            }
            XCTAssertEqual(result, .manifestDamaged(expected))
            details.append(try h.status().detail)
            try h.assertNoSecrets([token, "kept:"])
        }
        for detail in details { XCTAssertTrue(detail.contains("fixture.test/store.git")) }
        XCTAssertTrue(details[0].contains("git fetch https://fixture.test/store.git failed (exit 4): refused"))
        XCTAssertTrue(details[0].hasSuffix("retry"))
        XCTAssertTrue(details[1].hasPrefix("Authentication to https://fixture.test/store.git failed: refused"))
        XCTAssertTrue(details[1].hasSuffix("retry"))
        XCTAssertTrue(details[2].contains("UnlocalizedAuditFailure"))
        XCTAssertTrue(details[2].contains("broken"))
        h.rotate()
        for detail in details { XCTAssertTrue(try h.log(".1").contains(detail)) }
        try h.assertNoSecrets([token, "kept:"])
    }

    func testAHugeFailureIsCutToABoundedLineTheCommandCanStillRead() async throws {
        let h = try await SyncFailureAuditFixture()
        defer { try? h.disk.remove() }
        let huge = GitError.commandFailed(args: ["push", "origin", "main"], exitCode: 7,
            stderr: "HEAD-MARK\n" + String(repeating: "x", count: CLIProtocol.replyLimit + 1) + "\nfatal: TAIL-MARK")
        _ = await h.run(huge)
        let status = try h.status()
        XCTAssertLessThanOrEqual(status.detail.utf8.count, 4096)
        XCTAssertTrue(status.detail.hasPrefix("git push origin main failed (exit 7): HEAD-MARK"))
        XCTAssertTrue(status.detail.hasSuffix("fatal: TAIL-MARK"))
        XCTAssertEqual(status.detail.components(separatedBy: " [... cut ...] ").count, 2)
        XCTAssertTrue(try h.log().hasSuffix("\(status.timestamp) failed \(status.detail)\n"))
        try await h.assertCommandReads(status)
        for size in [4096, 4097] {
            let reason = String(repeating: "q", count: size)
            _ = await h.run(LiteralAuditFailure(text: reason))
            let bounded = try h.status().detail
            XCTAssertLessThanOrEqual(bounded.utf8.count, 4096)
            if size == 4096 { XCTAssertEqual(bounded, reason) } else { XCTAssertTrue(bounded.contains(" [... cut ...] ")) }
        }
        _ = await h.run(LiteralAuditFailure(text: String(repeating: "é", count: 3000)))
        let unicode = try h.status().detail
        XCTAssertLessThanOrEqual(unicode.utf8.count, 4096)
        XCTAssertFalse(unicode.contains("\u{FFFD}"))
        XCTAssertTrue(unicode.hasPrefix("é"))
        XCTAssertTrue(unicode.hasSuffix("é"))
        for _ in 0..<140 { _ = await h.run(LiteralAuditFailure(text: String(repeating: "y", count: 4097))) }
        h.audit.append(category: "fixture", detail: String(repeating: "z", count: 6000))
        XCTAssertLessThanOrEqual(try h.log().split(separator: "\n").last?.utf8.count ?? Int.max, 4200)
        for suffix in ["", ".1"] {
            XCTAssertLessThanOrEqual(try h.log(suffix).utf8.count, SyncAudit.logRotateThreshold + 4200)
        }
    }
}
