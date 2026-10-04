import Foundation

extension GitService {
    func installedBaseline(
        commit: String,
        path: String,
        repositoryPath: String,
        textByteLimit: Int,
        fileLimit: Int,
        byteLimit: Int
    ) throws -> UpstreamHistoryBaseline? {
        let pathspec = Self.literalPathspec(path)
        let args = ["-C", repositoryPath, "ls-tree", "-r", "-z", "-l", commit, "--", pathspec]
        let output = try runData(args, in: nil)
        guard output.exit == 0 else { return nil }
        let records = output.stdout.split(separator: 0)
        guard records.count <= fileLimit else { return .tooLarge }
        var files: [UpstreamHistoryBaselineFile] = []
        var totalBytes = 0
        for record in records {
            guard let tab = record.firstIndex(of: 9) else { continue }
            let header = record[..<tab].split(separator: 32, omittingEmptySubsequences: true)
            guard header.count == 4, header[1] == Data("blob".utf8) else { continue }
            guard let rawPath = String(
                bytes: record[record.index(after: tab)...],
                encoding: .utf8
            ) else { continue }
            guard let relative = relativeTreePath(rawPath, root: path) else { continue }
            guard let object = String(bytes: header[2], encoding: .utf8),
                  let sizeText = String(bytes: header[3], encoding: .utf8) else { continue }
            let size = Int(sizeText) ?? Int.max
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, nextTotal <= byteLimit else { return .tooLarge }
            totalBytes = nextTotal
            files.append(UpstreamHistoryBaselineFile(
                path: relative,
                content: try historicalContent(
                    object: object,
                    size: size,
                    repositoryPath: repositoryPath,
                    textByteLimit: textByteLimit
                ),
                fingerprint: object,
                isExecutable: header[0] == Data("100755".utf8)
            ))
        }
        return .files(files.sorted {
            Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8))
        })
    }

    func historicalContent(object: String, size: Int, repositoryPath: String,
                           textByteLimit: Int) throws -> UpstreamHistoryFileContent {
        guard size <= textByteLimit else { return .tooLarge }
        let data = try blob(object, at: repositoryPath)
        guard !data.contains(0), let text = UpstreamHistoryFileContent.utf8PreservingBOM(data) else { return .binary }
        return .text(text)
    }

    func relativeTreePath(_ value: String, root: String) -> String? {
        guard !root.isEmpty else { return value }
        let prefix = root + "/"
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    func objectExists(_ revision: String, at repositoryPath: String) throws -> Bool {
        try run(["-C", repositoryPath, "cat-file", "-e", revision], in: nil).exit == 0
    }

    func objectSize(_ revision: String, at repositoryPath: String) throws -> Int {
        let output = try runOrThrow(["-C", repositoryPath, "cat-file", "-s", revision], in: nil)
        return Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int.max
    }

    func blob(_ revision: String, at repositoryPath: String) throws -> Data {
        let args = ["-C", repositoryPath, "cat-file", "blob", revision]
        let output = try runData(args, in: nil)
        guard output.exit == 0 else { throw dataCommandError(output, args: args) }
        return output.stdout
    }
}
