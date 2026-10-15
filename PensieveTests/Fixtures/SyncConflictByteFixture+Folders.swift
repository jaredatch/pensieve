import XCTest
@testable import Pensieve

extension SyncConflictByteFixture {
    /// Runs native git without rewriting its index. Only an armed resolve changes
    /// the worktree after rebase; snapshots bracket Pensieve's resolution before git aborts.
    /// Neither wrapper supplies conflict versions, comparison answers or resolution results.
    func folderObservationEngine(change: String, lockAbort: Bool = false,
                                 warnOnAbort: Bool = false, failIndexRemoval: Bool = false,
                                 afterRemovalChange: String? = nil) throws -> SyncEngine {
        let executable = root + "/folder-observer-git"
        try writeFolderSnapshotScript()
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            before() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = rebase ] && [ "$2" = --abort ] && [ -f '\(root)/folder-armed' ] && \
                   /usr/bin/git -C '\(storeB)' rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
                    observed_abort=1
                    \(warnOnAbort ? "echo 'warning: fixture diagnostic before native abort' >&2" : ":")
                    \(lockAbort ? "touch '\(storeB)/.git/index.lock'" : ":")
                    if [ ! -f '\(root)/before-abort.json' ]; then
                        /usr/bin/python3 '\(root)/snapshot.py' '\(storeB)/\(path)' > '\(root)/before-abort.json' || exit 1
                    fi
                fi
            }
            before "$@"
            /usr/bin/git "$@"
            result=$?
            if [ "$observed_abort" = 1 ]; then printf '%s\\n' "$result" >> '\(root)/abort-results'; fi
            after() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = update-index ] && [ "$2" = --force-remove ] && \
                   [ -f '\(root)/folder-armed' ] && [ ! -f '\(root)/index-changed' ]; then
                    \(afterRemovalChange ?? ":")
                    touch '\(root)/index-changed'
                fi
                if [ "$1" = update-index ] && [ "$2" = --force-remove ] && \
                   [ -f '\(root)/folder-armed' ] && [ \(failIndexRemoval ? "1" : "0") = 1 ]; then
                    echo 'fixture failure after native index removal' >&2
                    result=1
                fi
                if [ "$1" = rebase ] && [ "$2" != --abort ] && [ "$2" != --continue ] && \
                   [ -f '\(root)/folder-armed' ] && \
                   /usr/bin/git -C '\(storeB)' rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
                    \(change)
                    /usr/bin/python3 '\(root)/snapshot.py' '\(storeB)/\(path)' > '\(root)/after-change.json' || exit 1
                fi
            }
            after "$@"
            exit "$result"
            """ + "\n")
        let observed = GitService(askpassHelperPath: root + "/askpass", executablePath: executable)
        return SyncEngine(gitService: AllowlistedRemoteGit(wrapping: observed), lockPath: root + "/sync.lock")
    }

    func freshClone() throws -> String {
        let fresh = root + "/fresh-" + UUID().uuidString
        try NativeTestWork.run { try git.clone(remote: "file://" + remote, into: fresh, credential: nil) }
        return fresh
    }

    private func writeFolderSnapshotScript() throws {
        try files.writeFile(at: root + "/snapshot.py", content: """
            import base64, json, os, stat, sys
            result = {}
            def visit(path, relative):
                try:
                    info = os.lstat(path)
                except FileNotFoundError:
                    result[relative] = {'missing': True}
                    return
                record = {'mode': stat.S_IMODE(info.st_mode)}
                if stat.S_ISLNK(info.st_mode):
                    record['link'] = os.readlink(path)
                elif stat.S_ISDIR(info.st_mode):
                    record['directory'] = True
                    for name in sorted(os.listdir(path)):
                        visit(path + '/' + name, relative + '/' + name)
                elif stat.S_ISREG(info.st_mode):
                    try:
                        with open(path, 'rb') as stream:
                            record['bytes'] = base64.b64encode(stream.read()).decode('ascii')
                    except OSError as error:
                        record['unreadable'] = error.errno
                else:
                    record['special'] = stat.S_IFMT(info.st_mode)
                result[relative] = record
            visit(sys.argv[1], '')
            print(json.dumps(result, sort_keys=True))
            """ + "\n")
    }

    func writeFolderEntries(_ entries: [String: Entry], at full: String) throws {
        for (relative, child) in entries {
            switch child {
            case let .file(bytes): try files.writeData(at: full + "/" + relative, data: bytes)
            case let .executable(bytes):
                try files.writeExecutableFile(at: full + "/" + relative,
                                              content: XCTUnwrap(String(data: bytes, encoding: .utf8)))
            case let .symlink(target):
                try files.createSymlink(at: full + "/" + relative, pointingTo: target)
            default: throw CocoaError(.featureUnsupported)
            }
        }
    }
    func change(_ entry: Entry, at store: String) throws {
        let full = store + "/" + path
        switch entry {
        case let .file(bytes):
            try removeFolder(at: full)
            try files.writeData(at: full, data: bytes)
        case let .executable(bytes):
            try files.writeExecutableFile(at: full, content: XCTUnwrap(String(bytes: bytes, encoding: .utf8)))
        case let .symlink(target):
            try removeEntry(at: full)
            try files.createSymlink(at: full, pointingTo: target)
        case let .gitlink(object):
            if try files.entryTypeWithoutFollowingLinks(at: full) == .regular { try files.deleteFile(at: full) }
            try files.createDirectory(at: full)
            try git.runOrThrow(["-C", store, "update-index", "--add", "--cacheinfo", "160000," + object + "," + path], in: nil)
        case .folder:
            if try files.entryExistsWithoutFollowingLinks(at: full) { try files.deleteFile(at: full) }
            try files.writeFile(at: full + "/keep", content: "chosen folder bytes")
        case let .folderWith(entries):
            try removeEntry(at: full)
            try files.createDirectory(at: full)
            try writeFolderEntries(entries, at: full)
        case .deleted:
            if files.directoryExists(at: full) { try files.deleteDirectory(at: full) } else { try files.deleteFile(at: full) }
        }
    }

    private func removeFolder(at path: String) throws {
        if try files.entryTypeWithoutFollowingLinks(at: path) == .directory { try files.deleteDirectory(at: path) }
    }

    private func removeEntry(at path: String) throws {
        if try files.entryTypeWithoutFollowingLinks(at: path) == .directory {
            try files.deleteDirectory(at: path)
        } else if try files.entryExistsWithoutFollowingLinks(at: path) { try files.deleteFile(at: path) }
    }

}
