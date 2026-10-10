import Foundation
@testable import Pensieve

final class RecordingUpdateGitService: UpdateCheckGitServing {
    var confirmsHints = false
    var usability: GitUsability = .usable
    var onProbe: (() throws -> GitUsability)?
    var cloneErrors: [String: GitError] = [:]
    private(set) var probeCalls = 0
    func probeUsability() throws -> GitUsability { probeCalls += 1; return try onProbe?() ?? usability }
    var heads: [String: String] = [:]
    var trees: [String: String] = [:]
    var failingRemotes: Set<String> = []
    var remoteHeadErrors: [String: GitError] = [:]
    var clonedHeadOverride: String?
    var onTreeHash: ((String) throws -> Void)?
    private(set) var remoteHeadCalls: [(remote: String, ref: String)] = []
    private(set) var cloneCalls: [(remote: String, ref: String?)] = []
    private(set) var treeHashCalls: [String] = []
    var receivedCredentials: [GitCredential?] = []
    private var lastClonedRemote: String?
    func remoteHead(remote: String, ref: String,
                    credential: GitCredential?) throws -> String? {
        remoteHeadCalls.append((remote, ref))
        receivedCredentials.append(credential)
        if let error = remoteHeadErrors[remote] { throw error }
        if failingRemotes.contains(remote) {
            throw GitError.commandFailed(args: ["ls-remote"], exitCode: 128, stderr: "dead remote")
        }
        return heads[remote]
    }

    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?) throws {
        cloneCalls.append((remote, branch))
        if let error = cloneErrors[remote] { throw try confirmed(error) }
        receivedCredentials.append(credential)
        lastClonedRemote = remote
    }

    func commitSHA(at path: String) throws -> String {
        if let clonedHeadOverride { return clonedHeadOverride }
        return lastClonedRemote.flatMap { heads[$0] } ?? "missing-head"
    }

    func commitDate(at repositoryPath: String) throws -> Date {
        Date(timeIntervalSince1970: 1_750_000_000)
    }

    func treeHash(at repositoryPath: String, path: String) throws -> String {
        treeHashCalls.append(path)
        do { try onTreeHash?(path) } catch let error as GitError { throw try confirmed(error) }
        guard let tree = trees[path] else {
            throw GitError.commandFailed(args: ["rev-parse"], exitCode: 128, stderr: "missing tree")
        }
        return tree
    }

    /// Models only the runner's confirming probe when requested by the hint tests.
    private func confirmed(_ error: GitError) throws -> GitError {
        guard confirmsHints, case let .commandFailed(args, exit, detail, _) = error,
              GitUsability.environmentFailure(exit: exit, output: detail) != nil else { return error }
        let answer = try probeUsability()
        try answer.requireUsable()
        return .commandFailed(args: args, exitCode: exit, stderr: detail, confirmingProbe: answer)
    }

}
