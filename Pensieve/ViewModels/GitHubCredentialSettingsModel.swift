import Foundation
import Observation

@Observable
final class GitHubCredentialSettingsModel {
    var token = ""
    private(set) var hasSavedToken = false
    private(set) var isReplacingToken = false
    var errorMessage: String?

    private let credentialStore: CredentialStoreProtocol

    init(credentialStore: CredentialStoreProtocol = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
        refresh()
    }

    var canSave: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsTokenEntry: Bool {
        !hasSavedToken || isReplacingToken
    }

    func refresh() {
        let savedTokenExists = credentialStore.credential(forHost: CredentialHost.githubInstall) != nil
        guard savedTokenExists != hasSavedToken else { return }
        hasSavedToken = savedTokenExists
        isReplacingToken = false
        if savedTokenExists {
            token = ""
        }
    }

    func beginReplacing() {
        guard hasSavedToken else { return }
        token = ""
        isReplacingToken = true
    }

    func cancelReplacing() {
        token = ""
        isReplacingToken = false
    }

    func save() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentialStore.store(
                token: trimmed,
                username: "x-access-token",
                forHost: CredentialHost.githubInstall
            )
            token = ""
            hasSavedToken = true
            isReplacingToken = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove() {
        do {
            try credentialStore.delete(forHost: CredentialHost.githubInstall)
            token = ""
            hasSavedToken = false
            isReplacingToken = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
