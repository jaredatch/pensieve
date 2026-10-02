import Foundation

extension GitService {
    /// Resolves a tracked branch or tag without fetching objects. Branch precedence matches
    /// `clone --branch`; annotated tags use their peeled commit rather than the tag object.
    func remoteHead(remote: String, ref: String,
                    credential: GitCredential?) throws -> String? {
        let branch = "refs/heads/\(ref)"
        let tag = "refs/tags/\(ref)"
        let peeledTag = tag + "^{}"
        let args = Self.installCredentialIsolationArgs
            + ["ls-remote", "--", remote, branch, tag, peeledTag]
        let output = try runUpstreamHistoryNetwork(args, credential: credential)
        guard output.exit == 0 else {
            let combined = output.stdout + output.stderr
            if isAuthFailure(combined) {
                throw GitError.authenticationFailed(remote: remote, detail: combined)
            }
            throw GitError.commandFailed(
                args: args,
                exitCode: output.exit,
                stderr: output.stderr.isEmpty ? output.stdout : output.stderr, confirmingProbe: output.confirmingProbe)
        }

        var revisions: [String: String] = [:]
        for line in output.stdout.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if fields.count == 2 {
                revisions[fields[1]] = fields[0]
            }
        }
        return revisions[branch] ?? revisions[peeledTag] ?? revisions[tag]
    }

    func commitDate(at repositoryPath: String) throws -> Date {
        let args = ["-C", repositoryPath, "show", "-s", "--format=%cI", "HEAD"]
        let output = try runOrThrow(args, in: nil)
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw GitError.commandFailed(
                args: args,
                exitCode: output.exit,
                stderr: "git returned an invalid commit date", confirmingProbe: output.confirmingProbe)
        }
        return date
    }
}
