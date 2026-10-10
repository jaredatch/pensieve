import Foundation

extension GitService {
    struct UpstreamHistoryLogRecord {
        let sha: String
        let author: String
        let date: Date
        let subject: String
        let filesChanged: Int
        let linesAdded: Int?
        let linesRemoved: Int?
    }

    func historyLogRecords(
        commits: [String],
        path: String,
        repositoryPath: String
    ) throws -> [UpstreamHistoryLogRecord] {
        guard !commits.isEmpty else { return [] }
        let format = "%H%x00%an%x00%aI%x00%s%x00"
        let args = ["-C", repositoryPath, "log", "--no-walk=unsorted"]
            + Self.upstreamHistoryFirstParentDiffArguments
            + ["--no-renames", "--numstat", "-z", "--format=\(format)"]
            + commits
            + ["--", Self.literalPathspec(path)]
        let output = try runData(args, in: nil)
        guard output.exit == 0 else { throw dataCommandError(output, args: args) }
        return try parseHistoryLog(output.stdout, args: args)
    }

    private func parseHistoryLog(_ data: Data, args: [String]) throws
        -> [UpstreamHistoryLogRecord] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        var records: [UpstreamHistoryLogRecord] = []
        while index < fields.count {
            while index < fields.count, normalizedLogField(fields[index]).isEmpty { index += 1 }
            guard index < fields.count else { break }
            guard index + 3 < fields.count,
                  let sha = utf8(fields[index]), isFullSHA(sha),
                  let author = utf8(fields[index + 1]),
                  let dateText = utf8(fields[index + 2]),
                  let date = Self.isoDate(dateText),
                  let subject = utf8(fields[index + 3]) else {
                throw malformedHistoryLog(args)
            }
            index += 4

            var files = 0
            var added = 0
            var removed = 0
            var hasTextCounts = false
            while index < fields.count {
                let field = normalizedLogField(fields[index])
                if let value = utf8(field), isFullSHA(value) { break }
                index += 1
                guard !field.isEmpty else { continue }
                let stats = field.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
                guard stats.count == 3 else { throw malformedHistoryLog(args) }
                files += 1
                if let plusText = utf8(stats[0]), let minusText = utf8(stats[1]),
                   let plus = Int(plusText), let minus = Int(minusText) {
                    added += plus
                    removed += minus
                    hasTextCounts = true
                }
            }
            guard files > 0 else { continue }
            records.append(UpstreamHistoryLogRecord(
                sha: sha,
                author: author,
                date: date,
                subject: subject,
                filesChanged: files,
                linesAdded: hasTextCounts ? added : nil,
                linesRemoved: hasTextCounts ? removed : nil
            ))
        }
        return records
    }

    private func normalizedLogField(_ field: Data.SubSequence) -> Data.SubSequence {
        var normalized = field
        while normalized.first == 10 { normalized = normalized.dropFirst() }
        return normalized
    }

    private func utf8(_ data: Data.SubSequence) -> String? {
        String(bytes: data, encoding: .utf8)
    }

    private func isFullSHA(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0)
        }
    }

    private func malformedHistoryLog(_ args: [String]) -> GitError {
        GitError.commandFailed(
            args: args,
            exitCode: 0,
            stderr: "git returned malformed upstream history"
        )
    }
}
