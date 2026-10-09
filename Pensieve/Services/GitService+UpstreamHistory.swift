import Foundation

extension GitService {
    static func upstreamHistoryFetchArguments(
        repositoryPath: String,
        remote: String,
        remoteRef: String,
        depth: Int
    ) -> [String] {
        installCredentialIsolationArgs + [
            "-C", repositoryPath, "fetch", "--quiet", "--no-tags", "--depth", "\(depth)",
            "--", remote, remoteRef
        ]
    }

    static func upstreamHistoryCommitFetchArguments(
        repositoryPath: String,
        remote: String,
        commit: String
    ) -> [String] {
        installCredentialIsolationArgs + [
            "-C", repositoryPath, "fetch", "--quiet", "--no-tags", "--depth", "1",
            "--", remote, commit
        ]
    }

    func upstreamHistory(_ request: UpstreamHistoryGitRequest) throws -> UpstreamHistoryGitSnapshot {
        try runOrThrow(["init", "--quiet", request.repositoryPath], in: nil)
        try fetchTrackedRef(request)
        try runOrThrow(
            ["-C", request.repositoryPath, "update-ref", "refs/pensieve/upstream", "FETCH_HEAD"],
            in: nil
        )

        let headOutput = try runOrThrow([
            "-C", request.repositoryPath, "rev-parse", "refs/pensieve/upstream^{commit}"
        ], in: nil)
        let head = headOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commits = try historyCommitSHAs(
            at: request.repositoryPath,
            limit: request.commitLimit + 1
        )
        let scanned = Array(commits.prefix(request.commitLimit))
        let isShallow = try isShallowRepository(at: request.repositoryPath)
        let hasMoreCommits = commits.count > request.commitLimit || isShallow
        let rows = try historyRows(scanned, request: request)

        let installed = try resolveInstalledPosition(
            installedCommit: request.installedCommit,
            scanned: scanned,
            hasMoreCommits: hasMoreCommits,
            request: request
        )
        let baseline = try baseline(for: installed, request: request)
        return UpstreamHistoryGitSnapshot(
            headCommit: head,
            rows: rows,
            installedPosition: installed,
            hasMoreCommits: hasMoreCommits,
            installedBaseline: baseline
        )
    }
}

extension GitService {
    func historyRows(_ commits: [String], request: UpstreamHistoryGitRequest) throws
        -> [UpstreamHistoryGitRow] {
        try historyLogRecords(
            commits: commits,
            path: request.path,
            repositoryPath: request.repositoryPath
        ).prefix(request.rowLimit).map { record in
            UpstreamHistoryGitRow(
                sha: record.sha,
                author: record.author,
                date: record.date,
                subject: record.subject,
                filesChanged: record.filesChanged,
                linesAdded: record.linesAdded,
                linesRemoved: record.linesRemoved,
                skillMarkdown: try skillMarkdown(
                    sha: record.sha,
                    path: request.path,
                    repositoryPath: request.repositoryPath,
                    textByteLimit: request.textByteLimit
                )
            )
        }
    }

    func baseline(
        for position: UpstreamHistoryGitInstalledPosition,
        request: UpstreamHistoryGitRequest
    ) throws -> UpstreamHistoryBaseline? {
        guard case .notInRefHistory = position else {
            return try installedBaseline(
                commit: request.installedCommit,
                path: request.path,
                repositoryPath: request.repositoryPath,
                textByteLimit: request.textByteLimit,
                fileLimit: request.baselineFileLimit,
                byteLimit: request.baselineByteLimit
            )
        }
        return nil
    }

    func throwHistoryFetchError(
        _ output: GitOutput,
        args: [String],
        remote: String,
        ref: String
    ) throws -> Never {
        let combined = output.stdout + output.stderr
        if isAuthFailure(combined) {
            throw GitError.authenticationFailed(remote: remote, detail: combined)
        }
        let lower = combined.lowercased()
        if lower.contains("couldn't find remote ref") || lower.contains("remote ref does not exist") {
            throw UpstreamHistoryError.trackedRefNotFound(ref)
        }
        throw GitError.commandFailed(
            args: args,
            exitCode: output.exit,
            stderr: output.stderr.isEmpty ? output.stdout : output.stderr, confirmingProbe: output.confirmingProbe)
    }

    func fetchTrackedRef(_ request: UpstreamHistoryGitRequest) throws {
        let branch = "refs/heads/\(request.ref)"
        let branchArgs = Self.upstreamHistoryFetchArguments(
            repositoryPath: request.repositoryPath,
            remote: request.remote,
            remoteRef: branch,
            depth: request.commitLimit + 1
        )
        let branchFetch = try runUpstreamHistoryNetwork(branchArgs, credential: request.credential)
        if branchFetch.exit == 0 { return }
        guard isMissingRemoteRef(branchFetch) else {
            try throwHistoryFetchError(
                branchFetch,
                args: branchArgs,
                remote: request.remote,
                ref: request.ref
            )
        }

        let tagArgs = Self.upstreamHistoryFetchArguments(
            repositoryPath: request.repositoryPath,
            remote: request.remote,
            remoteRef: "refs/tags/\(request.ref)",
            depth: request.commitLimit + 1
        )
        let tagFetch = try runUpstreamHistoryNetwork(tagArgs, credential: request.credential)
        guard tagFetch.exit == 0 else {
            try throwHistoryFetchError(
                tagFetch,
                args: tagArgs,
                remote: request.remote,
                ref: request.ref
            )
        }
    }

    func isMissingRemoteRef(_ output: GitOutput) -> Bool {
        let message = (output.stdout + output.stderr).lowercased()
        return message.contains("couldn't find remote ref")
            || message.contains("remote ref does not exist")
    }

    func historyCommitSHAs(at repositoryPath: String, limit: Int) throws -> [String] {
        let output = try runOrThrow([
            "-C", repositoryPath, "rev-list", "--max-count", "\(limit)",
            "refs/pensieve/upstream"
        ], in: nil)
        return output.stdout.split(whereSeparator: \Character.isNewline).map(String.init)
    }

    func skillMarkdown(
        sha: String,
        path: String,
        repositoryPath: String,
        textByteLimit: Int
    ) throws -> UpstreamHistoryText? {
        let relative = path.isEmpty ? "SKILL.md" : path + "/SKILL.md"
        let revision = sha + ":" + relative
        guard try objectExists(revision, at: repositoryPath) else { return nil }
        let size = try objectSize(revision, at: repositoryPath)
        guard size <= textByteLimit else { return .tooLarge }
        let data = try blob(revision, at: repositoryPath)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return .text(text)
    }

    func resolveInstalledPosition(
        installedCommit: String,
        scanned: [String],
        hasMoreCommits: Bool,
        request: UpstreamHistoryGitRequest
    ) throws -> UpstreamHistoryGitInstalledPosition {
        if scanned.contains(installedCommit) {
            return .reachable(pathCommit: try firstPathCommit(
                atOrBefore: installedCommit,
                path: request.path,
                repositoryPath: request.repositoryPath
            ))
        }
        if !hasMoreCommits { return .notInRefHistory }
        let fetched = try fetchInstalledCommitIfAvailable(
            installedCommit,
            remote: request.remote,
            repositoryPath: request.repositoryPath,
            credential: request.credential
        )
        guard fetched else { return .olderThanScan }
        if try isAncestor(
            installedCommit,
            of: "refs/pensieve/upstream",
            at: request.repositoryPath
        ) {
            return .reachable(pathCommit: try firstPathCommit(
                atOrBefore: installedCommit,
                path: request.path,
                repositoryPath: request.repositoryPath
            ))
        }
        return .olderThanScan
    }

    func fetchInstalledCommitIfAvailable(
        _ commit: String,
        remote: String,
        repositoryPath: String,
        credential: GitCredential?
    ) throws -> Bool {
        if try objectExists(commit + "^{commit}", at: repositoryPath) { return true }
        let args = Self.upstreamHistoryCommitFetchArguments(
            repositoryPath: repositoryPath,
            remote: remote,
            commit: commit
        )
        let output = try runUpstreamHistoryNetwork(args, credential: credential)
        if output.exit == 0 { return true }
        return false
    }

    func firstPathCommit(atOrBefore commit: String, path: String,
                         repositoryPath: String) throws -> String? {
        let pathspec = Self.literalPathspec(path)
        let output = try runOrThrow([
            "-C", repositoryPath, "log", "--first-parent"
        ] + Self.upstreamHistoryFirstParentDiffArguments + [
            "--no-patch", "--format=%H", "-1", commit, "--", pathspec
        ], in: nil)
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func isAncestor(_ ancestor: String, of descendant: String, at repositoryPath: String) throws -> Bool {
        let output = try run([
            "-C", repositoryPath, "merge-base", "--is-ancestor", ancestor, descendant
        ], in: nil)
        if output.exit == 0 { return true }
        if output.exit == 1 { return false }
        throw GitError.commandFailed(args: ["merge-base"], exitCode: output.exit, stderr: output.stderr,
            confirmingProbe: output.confirmingProbe)
    }

    func isShallowRepository(at repositoryPath: String) throws -> Bool {
        let output = try runOrThrow([
            "-C", repositoryPath, "rev-parse", "--is-shallow-repository"
        ], in: nil)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func literalPathspec(_ path: String) -> String {
        path.isEmpty ? "." : ":(literal)\(path)"
    }

    static let upstreamHistoryFirstParentDiffArguments = [
        "--diff-merges=first-parent"
    ]

}
