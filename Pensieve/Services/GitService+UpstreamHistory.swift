import Foundation

extension GitService {
    static func upstreamHistoryFetchArguments(
        repositoryPath: String,
        remote: String,
        remoteRef: String,
        depth: Int
    ) -> [String] {
        [
            "-C", repositoryPath, "fetch", "--quiet", "--no-tags", "--filter=blob:none", "--depth", "\(depth)",
            "--", remote, remoteRef
        ]
    }

    static func upstreamHistoryCommitFetchArguments(
        repositoryPath: String,
        remote: String,
        commit: String
    ) -> [String] {
        [
            "-C", repositoryPath, "fetch", "--quiet", "--no-tags", "--filter=blob:none", "--depth", "1",
            "--", remote, commit
        ]
    }

    @_disfavoredOverload
    func upstreamHistory(_ request: UpstreamHistoryGitRequest) throws -> UpstreamHistoryGitSnapshot {
        try runOrThrow(["init", "--quiet", request.repositoryPath], in: nil, environment: Self.historyEnvironment)
        try fetchTrackedRef(request)
        try prefetchHistoryBlobs(tip: "FETCH_HEAD", request: request)
        try runOrThrow(
            ["-C", request.repositoryPath, "update-ref", "refs/pensieve/upstream", "FETCH_HEAD"],
            in: nil, environment: Self.historyEnvironment
        )

        let headOutput = try runOrThrow([
            "-C", request.repositoryPath, "rev-parse", "refs/pensieve/upstream^{commit}"
        ], in: nil, environment: Self.historyEnvironment)
        let head = headOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commits = try historyCommitSHAs(
            at: request.repositoryPath,
            limit: request.commitLimit + 1
        )
        let scanned = Array(commits.prefix(request.commitLimit))
        let isShallow = try isShallowRepository(at: request.repositoryPath)
        let hasMoreCommits = commits.count > request.commitLimit || isShallow
        let (rows, hasMoreRows) = try historyRows(scanned, request: request)

        let installed = try resolveInstalledPosition(
            installedCommit: request.installedCommit,
            scanned: scanned,
            hasMoreCommits: hasMoreCommits,
            request: request
        )
        let baseline = installed.baselineAvailable ? try baseline(for: installed.position, request: request) : nil
        return UpstreamHistoryGitSnapshot(
            headCommit: head,
            rows: rows,
            installedPosition: installed.position,
            hasMoreRows: hasMoreRows,
            hasMoreCommits: hasMoreCommits,
            installedBaseline: baseline
        )
    }
}

extension GitService {
    func historyRows(_ commits: [String], request: UpstreamHistoryGitRequest) throws
        -> (rows: [UpstreamHistoryGitRow], hasMoreRows: Bool) {
        let records = try historyLogRecords(
            commits: commits,
            path: request.path,
            repositoryPath: request.repositoryPath
        )
        let visible = Array(records.prefix(request.rowLimit))
        let texts = try historyRowTexts(visible.map(\.sha), request: request)
        let rows = zip(visible, texts).map { record, text in
            UpstreamHistoryGitRow(
                sha: record.sha,
                author: record.author,
                date: record.date,
                subject: record.subject,
                filesChanged: record.filesChanged,
                linesAdded: record.linesAdded,
                linesRemoved: record.linesRemoved,
                skillMarkdown: text
            )
        }
        return (rows, records.count > request.rowLimit)
    }

    @discardableResult
    func prefetchHistoryBlobs(tip: String, request: UpstreamHistoryGitRequest,
                              allowDeclined: Bool = false) throws -> Bool {
        let output = try runOrThrow([
            "-C", request.repositoryPath, "rev-list", "--objects", "--full-history", "--missing=print", "--no-object-names",
            tip, "--", Self.literalPathspec(request.path)
        ], in: nil, environment: Self.historyEnvironment)
        let objects = try output.stdout.split(whereSeparator: \Character.isNewline).compactMap { line -> String? in
            guard line.first == "?" else { return nil }
            let object = String(line.dropFirst())
            guard Self.isHistoryObjectID(object) else { throw malformedHistoryBatch() }
            return object
        }
        guard !objects.isEmpty else { return true }
        let input = try historyInput(objects, repositoryPath: request.repositoryPath)
        let args = [
            "-C", request.repositoryPath, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "--no-tags",
            "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", "--stdin", "--", request.remote
        ]
        let fetched = try runUpstreamHistoryNetwork(args, credential: request.credential, inputPath: input)
        guard fetched.exit == 0 else {
            if allowDeclined { return false }
            throw commandError(fetched, args: args, authenticationRemote: request.remote)
        }
        return true
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
        let failure = commandError(output, args: args, authenticationRemote: remote)
        if case .authenticationFailed = failure { throw failure }
        if isMissingRemoteRef(output) {
            throw UpstreamHistoryError.trackedRefNotFound(ref)
        }
        throw failure
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
        ], in: nil, environment: Self.historyEnvironment)
        return output.stdout.split(whereSeparator: \Character.isNewline).map(String.init)
    }

    func resolveInstalledPosition(
        installedCommit: String,
        scanned: [String],
        hasMoreCommits: Bool,
        request: UpstreamHistoryGitRequest
    ) throws -> (position: UpstreamHistoryGitInstalledPosition, baselineAvailable: Bool) {
        if scanned.contains(installedCommit) {
            return (.reachable(pathCommit: try firstPathCommit(
                atOrBefore: installedCommit,
                path: request.path,
                repositoryPath: request.repositoryPath
            )), true)
        }
        if !hasMoreCommits { return (.notInRefHistory, false) }
        let fetched = try fetchInstalledCommitIfAvailable(
            installedCommit,
            request: request
        )
        guard fetched else { return (.olderThanScan, false) }
        if try isAncestor(
            installedCommit,
            of: "refs/pensieve/upstream",
            at: request.repositoryPath
        ) {
            return (.reachable(pathCommit: try firstPathCommit(
                atOrBefore: installedCommit,
                path: request.path,
                repositoryPath: request.repositoryPath
            )), true)
        }
        return (.olderThanScan, true)
    }

    func fetchInstalledCommitIfAvailable(
        _ commit: String,
        request: UpstreamHistoryGitRequest
    ) throws -> Bool {
        if try objectExists(commit + "^{commit}", at: request.repositoryPath) { return true }
        let args = Self.upstreamHistoryCommitFetchArguments(
            repositoryPath: request.repositoryPath,
            remote: request.remote,
            commit: commit
        )
        let output = try runUpstreamHistoryNetwork(args, credential: request.credential)
        guard output.exit == 0 else { return false }
        // A declined object prefetch leaves the installed baseline unavailable, like a declined SHA fetch.
        return try prefetchHistoryBlobs(tip: commit, request: request, allowDeclined: true)
    }

    func firstPathCommit(atOrBefore commit: String, path: String,
                         repositoryPath: String) throws -> String? {
        let pathspec = Self.literalPathspec(path)
        let output = try runOrThrow([
            "-C", repositoryPath, "log", "--first-parent"
        ] + Self.upstreamHistoryFirstParentDiffArguments + [
            "--no-patch", "--format=%H", "-1", commit, "--", pathspec
        ], in: nil, environment: Self.historyEnvironment)
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func isAncestor(_ ancestor: String, of descendant: String, at repositoryPath: String) throws -> Bool {
        let output = try run([
            "-C", repositoryPath, "merge-base", "--is-ancestor", ancestor, descendant
        ], in: nil, environment: Self.historyEnvironment)
        if output.exit == 0 { return true }
        if output.exit == 1 { return false }
        throw commandError(output, args: ["merge-base"])
    }

    func isShallowRepository(at repositoryPath: String) throws -> Bool {
        let output = try runOrThrow([
            "-C", repositoryPath, "rev-parse", "--is-shallow-repository"
        ], in: nil, environment: Self.historyEnvironment)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func literalPathspec(_ path: String) -> String {
        path.isEmpty ? "." : ":(literal)\(path)"
    }

    static let upstreamHistoryFirstParentDiffArguments = [
        "--diff-merges=first-parent"
    ]

}
