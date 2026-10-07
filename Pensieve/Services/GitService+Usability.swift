import Foundation

/// The only construction path for a failed-git detail prepares its display text and equality value together.
struct GitFailureDetail: Equatable, Sendable {
    let text: String
    init(_ text: String) { self.text = DisplayTextSanitizer.singleLine(text) }
}

enum GitUsability: Equatable, Sendable {
    case usable
    case licenseNotAccepted
    case developerToolsMissing
    case failed(GitFailureDetail)

    var message: String? {
        switch self {
        case .usable: return nil
        case .licenseNotAccepted:
            return "Git isn't working on this Mac. Accept the Xcode license by running sudo xcodebuild -license in Terminal."
        case .developerToolsMissing:
            return "Git isn't working on this Mac. Install the Command Line Tools by running xcode-select --install in Terminal."
        case let .failed(detail):
            return "Git isn't working on this Mac. \(detail.text)"
        }
    }

    func requireUsable() throws {
        guard self == .usable else { throw GitError.unusable(self) }
    }

    static func environmentFailure(exit: Int32, output: String) -> GitUsability? {
        guard exit != 0 else { return nil }
        let normalized = output.lowercased()
        if exit == 69, normalized.contains("license") { return .licenseNotAccepted }
        if normalized.contains("xcrun:"), normalized.contains("invalid active developer path") {
            return .developerToolsMissing
        }
        if normalized.contains("xcode-select:"), normalized.contains("no developer tools were found") {
            return .developerToolsMissing
        }
        return nil
    }
}

extension GitService {
    /// This is only an error label. An unknown label must not replace an established auth failure.
    func authenticationRemoteLabel(at path: String) -> String {
        (try? remoteURL(at: path)) ?? "origin"
    }

    func probeUsability() -> GitUsability {
        do {
            let result = try run(["--version"], in: nil)
            guard result.exit != 0 else { return .usable }
            let detail = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return GitUsability.environmentFailure(exit: result.exit, output: detail)
                ?? .failed(GitFailureDetail(detail.isEmpty ? "git --version exited \(result.exit)." : detail))
        } catch {
            return .failed(GitFailureDetail(error.localizedDescription))
        }
    }

    /// Filesystem absence is known only below a root that resolves to an existing directory.
    /// The `.git` lookup observes the entry itself, including dangling links; lookup failures throw.
    func remoteURL(at path: String) throws -> String? {
        do {
            guard try fileService.entryExistsWithoutFollowingLinks(at: path + "/.git") else {
                guard fileService.directoryExists(at: path) else {
                    throw GitError.repositoryUnreadable(
                        path: path, detail: "The store folder can't be found. Check that its volume is connected."
                    )
                }
                return nil
            }
            let result = try run(["-C", path, "remote", "get-url", "origin"], in: nil)
            switch result.exit {
            case 0:
                let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return url.isEmpty ? nil : url
            case 2:
                try runOrThrow(["-C", path, "rev-parse", "--git-dir"], in: nil)
                return nil
            default:
                throw GitError.commandFailed(args: ["remote", "get-url", "origin"],
                                             exitCode: result.exit, stderr: result.stderr,
                                                 confirmingProbe: result.confirmingProbe)
            }
        } catch {
            if case GitError.unusable = error { throw error }
            if case GitError.outputReadFailed = error { throw error }
            try probeUsability().requireUsable()
            if case GitError.repositoryUnreadable = error { throw error }
            throw GitError.repositoryUnreadable(path: path, detail: error.localizedDescription)
        }
    }
}
