import CryptoKit
import Foundation

extension UpstreamHistoryService {
    func localEdits(
        localDirectory: String,
        installedContentHash: String,
        baseline: UpstreamHistoryBaseline?
    ) throws -> UpstreamHistoryLocalEdits {
        let currentHash: String
        do {
            currentHash = try contentHasher.stableContentHash(
                at: localDirectory,
                excludingTopLevelGitMetadata: false
            )
        } catch {
            return .countsUnknown
        }
        guard UpdateCheckService.driftedLocally(
            currentContentHash: currentHash,
            installedContentHash: installedContentHash
        ) else { return .none }
        guard case let .files(baseline)? = baseline else { return .countsUnknown }

        let current = try localFiles(at: localDirectory)
        let installedByPath = Dictionary(uniqueKeysWithValues: baseline.map { ($0.path, $0) })
        let allPaths = Set(installedByPath.keys).union(current.keys).sorted(by: bytewiseLess)
        let changes = allPaths.compactMap { path -> UpstreamHistoryLocalChange? in
            let installed = installedByPath[path]
            let local = current[path]
            guard filesDiffer(installed, local) else { return nil }
            let counts = lineCounts(installed: installed?.content, current: local?.content)
            return UpstreamHistoryLocalChange(
                path: Self.safeDisplay(path, limit: Self.subjectLimit),
                linesAdded: counts?.added,
                linesRemoved: counts?.removed,
                installedText: text(from: installed?.content),
                currentText: text(from: local?.content)
            )
        }
        return changes.isEmpty ? .countsUnknown : .changed(changes)
    }
}

private extension UpstreamHistoryService {
    struct LocalFile {
        let content: UpstreamHistoryFileContent
        let fingerprint: String
        let isExecutable: Bool
    }

    func localFiles(at root: String) throws -> [String: LocalFile] {
        var files: [String: LocalFile] = [:]
        try collectLocalFiles(root: root, relativeDirectory: "", into: &files)
        return files
    }

    func collectLocalFiles(
        root: String,
        relativeDirectory: String,
        into files: inout [String: LocalFile]
    ) throws {
        let directory = relativeDirectory.isEmpty ? root : root + "/" + relativeDirectory
        for name in try fileService.listDirectory(at: directory) {
            let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
            let path = root + "/" + relative
            if fileService.isSymlink(at: path) {
                files[relative] = LocalFile(
                    content: .binary,
                    fingerprint: "symlink",
                    isExecutable: false
                )
            } else if fileService.directoryExists(at: path) {
                try collectLocalFiles(root: root, relativeDirectory: relative, into: &files)
            } else if fileService.isRegularFile(at: path) {
                let data = try fileService.readData(at: path)
                files[relative] = LocalFile(
                    content: localContent(data),
                    fingerprint: Self.gitBlobFingerprint(data),
                    isExecutable: fileService.isUserExecutableFile(at: path)
                )
            } else {
                files[relative] = LocalFile(
                    content: .binary,
                    fingerprint: "special",
                    isExecutable: false
                )
            }
        }
    }

    func localContent(_ data: Data) -> UpstreamHistoryFileContent {
        guard data.count <= Self.textByteLimit else { return .tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .binary
        }
        return .text(text)
    }

    func filesDiffer(_ installed: UpstreamHistoryBaselineFile?,
                     _ current: LocalFile?) -> Bool {
        switch (installed, current) {
        case (nil, nil):
            false
        case let (installed?, current?):
            installed.fingerprint != current.fingerprint
                || installed.isExecutable != current.isExecutable
        default:
            true
        }
    }

    func lineCounts(
        installed: UpstreamHistoryFileContent?,
        current: UpstreamHistoryFileContent?
    ) -> (added: Int, removed: Int)? {
        let before: [String]
        let after: [String]
        switch installed {
        case let .text(text): before = lines(in: text)
        case nil: before = []
        case .binary, .tooLarge: return nil
        }
        switch current {
        case let .text(text): after = lines(in: text)
        case nil: after = []
        case .binary, .tooLarge: return nil
        }
        var added = 0
        var removed = 0
        for change in after.difference(from: before) {
            switch change {
            case .insert: added += 1
            case .remove: removed += 1
            }
        }
        return (added, removed)
    }

    func lines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map(String.init)
        if text.last?.isNewline == true { lines.removeLast() }
        return lines
    }

    func text(from content: UpstreamHistoryFileContent?) -> String? {
        guard case let .text(text) = content else { return nil }
        return text
    }

    func bytewiseLess(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
    }
}

extension UpstreamHistoryService {
    static func gitBlobFingerprint(_ data: Data) -> String {
        var framed = Data("blob \(data.count)\u{0}".utf8)
        framed.append(data)
        return Insecure.SHA1.hash(data: framed).map { String(format: "%02x", $0) }.joined()
    }
}
