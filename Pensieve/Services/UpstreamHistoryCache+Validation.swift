import Foundation

extension UpstreamHistoryCache {
    func validate(_ envelope: Envelope) -> Bool {
        guard envelope.schemaVersion == Self.schemaVersion,
              UpstreamHistoryService.isFullObjectID(envelope.origin.installedCommit),
              UpstreamHistoryService.isSafeRef(envelope.origin.ref),
              UpstreamHistoryService.isSafePath(envelope.origin.path),
              InstallRemotePolicy.validateGitHubRepository(envelope.origin.repo) != nil,
              UpstreamHistoryService.isFullObjectID(envelope.readHead),
              envelope.result.headCommit == envelope.readHead,
              validWindow(envelope.result),
              validRows(envelope.result.rows),
              validPosition(
                envelope.result.installedPosition,
                rows: envelope.result.rows,
                installedCommit: envelope.origin.installedCommit
              ),
              validBaseline(envelope.result.installedBaseline) else { return false }
        if case .notInRefHistory = envelope.result.installedPosition,
           envelope.result.installedBaseline != nil { return false }
        if let recorded = envelope.recordedHeadAtRead,
           !UpstreamHistoryService.isFullObjectID(recorded) { return false }
        return true
    }
}

private extension UpstreamHistoryCache {
    func validWindow(_ result: CachedResult) -> Bool {
        guard result.windowCount > 0,
              result.windowCount <= Self.maximumAdmittedWindow else { return false }
        let (maximumRows, overflow) = UpstreamHistoryService.rowWindow
            .multipliedReportingOverflow(by: result.windowCount)
        return !overflow && result.rows.count <= maximumRows
    }

    func validRows(_ rows: [UpstreamHistoryRow]) -> Bool {
        rows.allSatisfy { row in
            UpstreamHistoryService.isFullObjectID(row.sha)
                && row.filesChanged >= 0
                && row.linesAdded.map { $0 >= 0 } != false
                && row.linesRemoved.map { $0 >= 0 } != false
                && validText(row.skillMarkdown)
        }
    }

    func validText(_ value: UpstreamHistoryText?) -> Bool {
        guard case let .text(text)? = value else { return true }
        return text.utf8.count <= UpstreamHistoryService.textByteLimit
    }

    func validPosition(
        _ position: UpstreamHistoryInstalledPosition,
        rows: [UpstreamHistoryRow],
        installedCommit: String
    ) -> Bool {
        let containsInstalledCommit = rows.contains { $0.sha == installedCommit }
        switch position {
        case let .at(sha):
            guard UpstreamHistoryService.isFullObjectID(sha), rows.contains(where: { $0.sha == sha }) else {
                return false
            }
            return !containsInstalledCommit || sha == installedCommit
        case .olderThanRowsRead, .notInRefHistory:
            return !containsInstalledCommit
        }
    }

    func validBaseline(_ baseline: UpstreamHistoryBaseline?) -> Bool {
        guard case let .files(files)? = baseline else { return true }
        guard files.count <= UpstreamHistoryService.baselineFileLimit,
              Set(files.map(\.path)).count == files.count else { return false }
        var totalBytes = 0
        for file in files {
            guard UpstreamHistoryService.isFullObjectID(file.fingerprint) else { return false }
            let byteCount: Int
            switch file.content {
            case let .text(text):
                byteCount = text.utf8.count
                guard byteCount <= UpstreamHistoryService.textByteLimit else { return false }
            case .binary, .tooLarge:
                byteCount = 0
            }
            let (next, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow, next <= UpstreamHistoryService.baselineByteLimit else { return false }
            totalBytes = next
        }
        return true
    }
}
