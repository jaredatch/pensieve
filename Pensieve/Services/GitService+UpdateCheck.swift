import Foundation

extension GitService {
    /// Resolves a tracked branch or tag without fetching objects. Branch precedence matches
    /// `clone --branch`; annotated tags use their peeled commit rather than the tag object.
    @_disfavoredOverload
    func remoteHead(remote: String, ref: String,
                    credential: GitCredential?) throws -> String? {
        let branch = "refs/heads/\(ref)"
        let tag = "refs/tags/\(ref)"
        let peeledTag = tag + "^{}"
        let args = ["ls-remote", "--", remote, branch, tag, peeledTag]
        let output = try runUpstreamHistoryNetwork(args, credential: credential)
        guard output.exit == 0 else {
            throw commandError(output, args: args, authenticationRemote: remote)
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

    @_disfavoredOverload
    func commitDate(at repositoryPath: String) throws -> Date {
        let args = ["-C", repositoryPath, "show", "-s", "--format=%cI", "HEAD"]
        let output = try runOrThrow(args, in: nil)
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw commandError(args: args, exitCode: output.exit,
                               detail: "git returned an invalid commit date", confirmingProbe: output.confirmingProbe)
        }
        return date
    }
}
