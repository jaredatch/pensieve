import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testLocalCommitComparisonWorkDoesNotGrowWithManifestSize() throws {
        try NativeTestWork.run { [self] in
            for format in ["sha1", "sha256"] {
                let base = tempDir + "/cost-" + format
                let root = base + "/repository"
                let files = FileService(), native = TestPaths.git
                try files.createDirectory(at: root)
                _ = try native.runOrThrow(["init", "--object-format=" + format, root], in: nil)
                try files.writeFile(at: root + "/base", content: "base")
                _ = try native.stageAllAndCommit(at: root, message: "base")
                let (git, trace) = try comparisonRecordingGit(base: base)
                for count in [1, 128] {
                    let parent = try XCTUnwrap(native.headSHA(at: root))
                    for index in 0..<count {
                        try files.writeFile(at: root + "/manifest/value-\(index)", content: "count \(count), row \(index)\n")
                    }
                    let capture = try SyncLocalCommit(root: root, files: files)
                    _ = try native.stageAllAndCommit(at: root, message: "manifest \(count)")
                    let head = try XCTUnwrap(native.headSHA(at: root))
                    try files.writeFile(at: trace, content: "")
                    let state = StoreIngestState()
                    state.seedHead(parent)
                    capture.record(from: parent, to: head, root: root, git: git, state: state)
                    XCTAssertFalse(state.requiresRebuild(at: .resolved(head)), format)
                    let calls = try files.readFile(at: trace).split(separator: "\n")
                    XCTAssertLessThanOrEqual(calls.count, 2, "Comparing known bytes must not spawn once per manifest file")
                }
            }
        }
    }

    func testIdleSyncAndInspectionDoNotCaptureOrCompareTheManifest() throws {
        for operation in ["sync", "inspect"] {
            let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/idle-" + operation) }
            let context = try damageContext(f)
            try NativeTestWork.run(container: context.container) { worker in
                let (git, trace) = try self.comparisonRecordingGit(base: f.base)
                let files = RebuildReadFileService()
                let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git),
                    fileService: files, lockPath: f.base + "/sync.lock")
                guard case .synced = try engine.sync(root: f.app, message: "seed", credential: nil,
                                                     context: worker) else { return XCTFail("Seed sync must finish") }
                try f.files.writeFile(at: trace, content: "")
                let reads = files.containedRegularReadPaths.count
                let before = try XCTUnwrap(f.git.headSHA(at: f.app))
                if operation == "sync" {
                    _ = try engine.sync(root: f.app, message: "idle", credential: nil, context: worker)
                } else {
                    _ = try engine.inspectConflicts(root: f.app, credential: nil, context: worker)
                }
                XCTAssertEqual(try f.git.headSHA(at: f.app), before)
                let readPaths = files.containedRegularReadPaths.dropFirst(reads)
                XCTAssertFalse(readPaths.contains { $0.hasPrefix(f.app + "/manifest/") },
                               "An idle cycle must not capture manifest bytes: \(readPaths)")
                let calls = try f.files.readFile(at: trace).split(separator: "\n")
                XCTAssertFalse(calls.contains { $0.contains("diff-tree") }, "An unchanged HEAD needs no comparison")
                let state = StoreIngestState.shared(for: worker.container)
                XCTAssertFalse(state.needsRebuild)
                XCTAssertFalse(state.requiresRebuild(at: .resolved(before)))
            }
        }
    }

    private func comparisonRecordingGit(base: String) throws -> (GitService, String) {
        let files = FileService(), executable = base + "/recording-git", trace = base + "/git-calls"
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(trace)'
            exec /usr/bin/git "$@"
            """ + "\n")
        return (GitService(askpassHelperPath: base + "/askpass", executablePath: executable), trace)
    }
}
