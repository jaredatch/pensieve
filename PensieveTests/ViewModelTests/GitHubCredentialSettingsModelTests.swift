import XCTest
@testable import Pensieve

final class GitHubCredentialSettingsModelTests: XCTestCase {
    func testSaveAndRemoveExposePresenceWithoutEchoingToken() throws {
        let credentials = InMemoryCredentialStore()
        let model = GitHubCredentialSettingsModel(credentialStore: credentials)
        XCTAssertTrue(model.showsTokenEntry)
        model.token = "  github_pat_secret  "

        model.save()

        XCTAssertTrue(model.hasSavedToken)
        XCTAssertFalse(model.showsTokenEntry)
        XCTAssertEqual(model.token, "")
        XCTAssertEqual(
            credentials.credential(forHost: CredentialHost.githubInstall),
            .httpsToken(username: "x-access-token", token: "github_pat_secret")
        )

        model.remove()

        XCTAssertFalse(model.hasSavedToken)
        XCTAssertTrue(model.showsTokenEntry)
        XCTAssertNil(credentials.credential(forHost: CredentialHost.githubInstall))
    }

    func testExistingTokenHidesEntryWithoutEchoingToken() throws {
        let model = GitHubCredentialSettingsModel(credentialStore: try savedCredentials())

        XCTAssertTrue(model.hasSavedToken)
        XCTAssertFalse(model.showsTokenEntry)
        XCTAssertFalse(model.isReplacingToken)
        XCTAssertEqual(model.token, "")
    }

    func testReplaceShowsEntryWithoutChangingSavedToken() throws {
        let credentials = try savedCredentials()
        let model = GitHubCredentialSettingsModel(credentialStore: credentials)

        model.beginReplacing()

        XCTAssertTrue(model.showsTokenEntry)
        XCTAssertTrue(model.isReplacingToken)
        XCTAssertTrue(model.hasSavedToken)
        XCTAssertEqual(model.token, "")
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(credentials.credential(forHost: CredentialHost.githubInstall),
                       .httpsToken(username: "x-access-token", token: "original-token"))
    }

    func testCancelReplacementHidesEntryAndClearsTypedText() throws {
        let credentials = try savedCredentials()
        let model = GitHubCredentialSettingsModel(credentialStore: credentials)
        model.beginReplacing()
        model.token = "discarded-token"

        model.cancelReplacing()

        XCTAssertFalse(model.showsTokenEntry)
        XCTAssertFalse(model.isReplacingToken)
        XCTAssertEqual(model.token, "")
        XCTAssertEqual(credentials.credential(forHost: CredentialHost.githubInstall),
                       .httpsToken(username: "x-access-token", token: "original-token"))
    }

    func testSaveReplacementStoresNewTokenAndHidesEntry() throws {
        let credentials = try savedCredentials()
        let model = GitHubCredentialSettingsModel(credentialStore: credentials)
        model.beginReplacing()
        model.token = "  replacement-token  "

        model.save()

        XCTAssertTrue(model.hasSavedToken)
        XCTAssertFalse(model.showsTokenEntry)
        XCTAssertFalse(model.isReplacingToken)
        XCTAssertEqual(model.token, "")
        XCTAssertEqual(credentials.credential(forHost: CredentialHost.githubInstall),
                       .httpsToken(username: "x-access-token", token: "replacement-token"))
    }

    func testRemoveWhileReplacingShowsEmptyEntry() throws {
        let credentials = try savedCredentials()
        let model = GitHubCredentialSettingsModel(credentialStore: credentials)
        model.beginReplacing()
        model.token = "discarded-token"

        model.remove()

        XCTAssertTrue(model.showsTokenEntry)
        XCTAssertFalse(model.hasSavedToken)
        XCTAssertFalse(model.isReplacingToken)
        XCTAssertEqual(model.token, "")
        XCTAssertNil(credentials.credential(forHost: CredentialHost.githubInstall))
    }

    func testRefreshEndsReplacementAndUsesCurrentCredentialPresence() throws {
        let credentials = try savedCredentials()
        let model = GitHubCredentialSettingsModel(credentialStore: credentials)
        model.beginReplacing()
        model.token = "draft-token"

        try credentials.delete(forHost: CredentialHost.githubInstall)
        model.refresh()

        XCTAssertFalse(model.hasSavedToken)
        XCTAssertTrue(model.showsTokenEntry)
        XCTAssertFalse(model.isReplacingToken)
        XCTAssertEqual(model.token, "draft-token")
        XCTAssertTrue(model.canSave)
    }

    func testRefreshFindsNewlySavedTokenAndClearsDraft() throws {
        let credentials = InMemoryCredentialStore()
        let model = GitHubCredentialSettingsModel(credentialStore: credentials)
        model.token = "discarded-token"
        try credentials.store(token: "original-token", username: "x-access-token", forHost: CredentialHost.githubInstall)

        model.refresh()

        XCTAssertTrue(model.hasSavedToken)
        XCTAssertFalse(model.showsTokenEntry)
        XCTAssertFalse(model.isReplacingToken)
        XCTAssertEqual(model.token, "")
        XCTAssertFalse(model.canSave)
    }

    func testRefreshPreservesDraftWithNoSavedToken() {
        let model = GitHubCredentialSettingsModel(credentialStore: InMemoryCredentialStore())
        model.token = "draft-token"

        model.refresh()

        XCTAssertFalse(model.hasSavedToken)
        XCTAssertTrue(model.showsTokenEntry)
        XCTAssertFalse(model.isReplacingToken)
        XCTAssertEqual(model.token, "draft-token")
        XCTAssertTrue(model.canSave)
    }

    func testRefreshPreservesReplacementInProgress() throws {
        let model = GitHubCredentialSettingsModel(credentialStore: try savedCredentials())
        model.beginReplacing()
        model.token = "replacement-draft"

        model.refresh()

        XCTAssertTrue(model.hasSavedToken)
        XCTAssertTrue(model.showsTokenEntry)
        XCTAssertTrue(model.isReplacingToken)
        XCTAssertEqual(model.token, "replacement-draft")
        XCTAssertTrue(model.canSave)
    }

    private func savedCredentials() throws -> InMemoryCredentialStore {
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "original-token", username: "x-access-token", forHost: CredentialHost.githubInstall)
        return credentials
    }
}
