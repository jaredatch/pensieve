import Foundation

/// A partial run can both reach a remote and report one environment failure.
struct UpdateCheckReport {
    var reachedRemote = false
    var environmentError: Error?
    var gitUsability: GitUsability?

    var countsAsRun: Bool { environmentError == nil || reachedRemote }
}

struct RuntimeUpdateCheckResult {
    let report: UpdateCheckReport
    let skills: [UUID: SkillUpdateCheckResult]
}

struct ClassifiedUpdateFailure {
    let error: Error
    let environment: Bool
    let usability: GitUsability?

    static func classify(_ failure: Error, probe: () throws -> GitUsability? = { nil }) -> Self {
        if case GitError.outputReadFailed = failure {
            return Self(error: failure, environment: false, usability: nil)
        }
        if case let GitError.unusable(value) = failure {
            return Self(error: failure, environment: true, usability: value)
        }
        let confirmation: GitUsability?
        if case let GitError.commandFailed(_, _, _, answer) = failure { confirmation = answer } else { confirmation = nil }
        let mapped = SkillInstallService.mappedRepositoryError(failure)
        if let install = mapped as? SkillInstallError {
            switch install {
            case .networkUnavailable: return Self(error: install, environment: true, usability: confirmation)
            case .authenticationFailed, .repositoryNotFound:
                return Self(error: install, environment: false, usability: confirmation)
            default: break
            }
        }
        // A carried answer came from the runner. Otherwise the batch diagnostic must establish usability.
        let value: GitUsability?
        do { value = try confirmation ?? probe() } catch {
            return Self(error: failure, environment: false, usability: nil)
        }
        if let value, value != .usable {
            return Self(error: GitError.unusable(value), environment: true, usability: value)
        }
        return Self(error: mapped, environment: false, usability: value)
    }
}

/// One diagnostic probe per batch, in addition to the run's preflight.
final class UpdateBatchDiagnostics {
    private var cached: Result<GitUsability, Error>?
    private(set) var evidence: GitUsability?
    private let probe: () throws -> GitUsability

    init(probe: @escaping () throws -> GitUsability) { self.probe = probe }

    func recordUsable() {
        cached = .success(.usable)
        evidence = .usable
    }

    /// A subsequent git operation may fail after a successful head read (for example after an Xcode update).
    func beginNextGitOperation() { cached = nil }

    func classify(_ error: Error) -> ClassifiedUpdateFailure {
        let result = ClassifiedUpdateFailure.classify(error) {
            if self.cached == nil { self.cached = Result { try self.probe() } }
            return try self.cached?.get()
        }
        if let value = result.usability { evidence = value }
        return result
    }
}

struct UpdateCheckCompletion {
    let report: UpdateCheckReport?
    let errors: [Error]

    var countsAsRun: Bool { report?.countsAsRun ?? true }
    var defersAutomaticRetry: Bool { report?.environmentError != nil && report?.reachedRemote == false }
    var error: Error? {
        if errors.count > 1 { return CombinedUpdateError(errors: errors) }
        return errors.first
    }
}

private struct CombinedUpdateError: LocalizedError {
    let errors: [Error]
    var errorDescription: String? {
        errors.map(\.localizedDescription).joined(separator: "\n")
    }
}

/// Keeps observed git evidence when a later local read or save throws.
struct UpdateCheckExecutionFailure: LocalizedError {
    let report: UpdateCheckReport
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }

    static func preservingReport<T>(_ report: UpdateCheckReport, operation: () throws -> T) throws -> T {
        do { return try operation() } catch { throw Self(report: report, underlying: error) }
    }
}
