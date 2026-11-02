import Foundation

extension GitService {
    struct HistoryBlob {
        let object: String
        let size: Int
    }

    private struct HistoryTreeFile {
        let path: String
        let blob: HistoryBlob
        let isExecutable: Bool
    }

    func installedBaseline(
        commit: String,
        path: String,
        repositoryPath: String,
        textByteLimit: Int,
        fileLimit: Int,
        byteLimit: Int
    ) throws -> UpstreamHistoryBaseline? {
        let args = ["-C", repositoryPath, "ls-tree", "-r", "-z", "-l", commit, "--", Self.literalPathspec(path)]
        let output = try runData(args, in: nil, environment: Self.historyEnvironment)
        guard output.exit == 0 else { return nil }
        let records = output.stdout.split(separator: 0)
        guard records.count <= fileLimit else { return .tooLarge }
        var listing: [HistoryTreeFile] = []
        var totalBytes = 0
        for record in records {
            guard let file = try historyTreeFile(record, root: path) else { continue }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(file.blob.size)
            guard !overflow, nextTotal <= byteLimit else { return .tooLarge }
            totalBytes = nextTotal
            listing.append(file)
        }
        let contents = try historyBlobs(listing.map(\.blob).filter { $0.size <= textByteLimit },
                                        repositoryPath: repositoryPath)
        let files = try listing.map { file in
            UpstreamHistoryBaselineFile(
                path: file.path,
                content: try historicalContent(file.blob, contents: contents, textByteLimit: textByteLimit),
                fingerprint: file.blob.object,
                isExecutable: file.isExecutable
            )
        }
        return .files(files.sorted {
            Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8))
        })
    }

    private func historyTreeFile(_ record: Data.SubSequence, root: String) throws -> HistoryTreeFile? {
        guard let tab = record.firstIndex(of: 9) else { return nil }
        let header = record[..<tab].split(separator: 32, omittingEmptySubsequences: true)
        guard header.count == 4, header[1] == Data("blob".utf8),
              let rawPath = String(bytes: record[record.index(after: tab)...], encoding: .utf8),
              let relative = relativeTreePath(rawPath, root: root),
              let object = String(bytes: header[2], encoding: .utf8),
              Self.isHistoryObjectID(object),
              let sizeText = String(bytes: header[3], encoding: .utf8) else { return nil }
        guard let size = Int(sizeText), size >= 0 else {
            throw commandError(args: ["ls-tree"], exitCode: 0, detail: "git returned an invalid upstream history blob size")
        }
        return HistoryTreeFile(path: relative, blob: HistoryBlob(object: object, size: size),
                               isExecutable: header[0] == Data("100755".utf8))
    }

    private func historicalContent(_ blob: HistoryBlob, contents: [String: Data],
                                   textByteLimit: Int) throws -> UpstreamHistoryFileContent {
        guard blob.size <= textByteLimit else { return .tooLarge }
        guard let data = contents[blob.object] else { throw malformedHistoryBatch() }
        guard !data.contains(0), let text = UpstreamHistoryFileContent.utf8PreservingBOM(data) else { return .binary }
        return .text(text)
    }

    func historyRowTexts(_ commits: [String], request: UpstreamHistoryGitRequest) throws -> [UpstreamHistoryText?] {
        guard !commits.isEmpty else { return [] }
        let relative = request.path.isEmpty ? "SKILL.md" : request.path + "/SKILL.md"
        let revisions = commits.map { $0 + ":" + relative }
        let input = try historyInput(revisions, repositoryPath: request.repositoryPath)
        let args = ["-C", request.repositoryPath, "cat-file", "--batch-check"]
        let output = try runOrThrow(args, in: nil, inputPath: input, environment: Self.historyEnvironment)
        let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == revisions.count + 1, lines.last == "" else { throw malformedHistoryBatch() }
        let blobs = try zip(revisions, lines).map { revision, line -> HistoryBlob? in
            if line == revision + " missing" { return nil }
            return try historyBlobHeader(String(line))
        }
        let contents = try historyBlobs(blobs.compactMap { $0 }.filter { $0.size <= request.textByteLimit },
                                        repositoryPath: request.repositoryPath)
        return try blobs.map { blob in
            guard let blob else { return nil }
            guard blob.size <= request.textByteLimit else { return .tooLarge }
            guard let data = contents[blob.object] else { throw malformedHistoryBatch() }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
            return .text(text)
        }
    }

    func historyInput(_ lines: [String], repositoryPath: String) throws -> String {
        let path = repositoryPath + "/.git/history-input-" + UUID().uuidString
        try fileService.writeFile(at: path, content: lines.joined(separator: "\n") + "\n")
        return path
    }

    func historyBlobs(_ blobs: [HistoryBlob], repositoryPath: String) throws -> [String: Data] {
        guard !blobs.isEmpty else { return [:] }
        let input = try historyInput(blobs.map(\.object), repositoryPath: repositoryPath)
        let args = ["-C", repositoryPath, "cat-file", "--batch"]
        let output = try runData(args, in: nil, inputPath: input, environment: Self.historyEnvironment)
        guard output.exit == 0 else { throw dataCommandError(output, args: args) }
        return try parseHistoryBlobs(output.stdout, expected: blobs)
    }

    private func parseHistoryBlobs(_ data: Data, expected: [HistoryBlob]) throws -> [String: Data] {
        var offset = data.startIndex
        var contents: [String: Data] = [:]
        for blob in expected {
            guard let newline = data[offset...].firstIndex(of: 10),
                  let header = String(data: data[offset ..< newline], encoding: .utf8) else {
                throw malformedHistoryBatch()
            }
            let parsed = try historyBlobHeader(header)
            guard parsed.object == blob.object, parsed.size == blob.size else { throw malformedHistoryBatch() }
            let start = data.index(after: newline)
            // Subtraction bounds the addition, including for an attacker-controlled Int.max size.
            guard blob.size < data.endIndex - start else { throw malformedHistoryBatch() }
            let end = start + blob.size
            guard data[end] == 10 else { throw malformedHistoryBatch() }
            contents[blob.object] = data[start ..< end]
            offset = data.index(after: end)
        }
        guard offset == data.endIndex else { throw malformedHistoryBatch() }
        return contents
    }

    private func historyBlobHeader(_ header: String) throws -> HistoryBlob {
        let fields = header.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, Self.isHistoryObjectID(String(fields[0])), fields[1] == "blob",
              let size = Int(fields[2]), size >= 0 else { throw malformedHistoryBatch() }
        return HistoryBlob(object: String(fields[0]), size: size)
    }

    static func isHistoryObjectID(_ object: String) -> Bool {
        object.utf8.count == 40 && object.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    func malformedHistoryBatch() -> GitError {
        commandError(args: ["cat-file", "--batch"], exitCode: 0, detail: "git returned malformed upstream history objects")
    }

    func relativeTreePath(_ value: String, root: String) -> String? {
        guard !root.isEmpty else { return value }
        guard let relative = PathSyntax.relativePath(value, under: root), !relative.isEmpty else { return nil }
        return relative
    }

    func objectExists(_ revision: String, at repositoryPath: String) throws -> Bool {
        try run(["-C", repositoryPath, "cat-file", "-e", revision], in: nil, environment: Self.historyEnvironment).exit == 0
    }
}
