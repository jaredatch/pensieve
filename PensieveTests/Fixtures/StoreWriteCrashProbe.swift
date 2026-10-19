import Darwin
import XCTest
@testable import Pensieve

/// Runs the production writers in the existing disposable helper. A dylib intercepts their real
/// write, rename, lock and flush syscalls to kill the child, refuse optional work or insert a race.
/// Namespace races launch one more disposable writer. Directory creation can be observed for volume
/// probes. It invents no intermediate name and intercepts no process outside these helper children.
struct StoreWriteCrashProbe {
    let library: String

    func intermediate() throws -> String { try FileService().readFile(at: library + ".path") }

    init(directory: String) throws {
        library = directory + "/crash.dylib"
        let source = directory + "/crash.c"
        try FileService().writeFile(at: source, content: Self.source)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-dynamiclib", "-o", library, source]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
    }

    func run(root: String, writer: String, point: String, destination: String = "") throws -> Int32 {
        for suffix in [".path", ".locations"] { try? FileService().deleteFile(at: library + suffix) }
        let process = Process()
        process.executableURL = Bundle(for: SyncBytePreservationTests.self).bundleURL
            .appendingPathComponent("Contents/MacOS/GitProcessProbe")
        process.arguments = ["store-write-" + writer, root, root + "/unused-report"]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = library
        environment["STORE_CRASH_POINT"] = point
        environment["STORE_CRASH_TRACE"] = library + ".path"
        environment["STORE_LOCATION_TRACE"] = library + ".locations"
        environment["STORE_CRASH_DESTINATION"] = destination
        environment["STORE_PROBE_EXECUTABLE"] = process.executableURL?.path
        environment["STORE_PROBE_ROOT"] = root
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); XCTFail("Writer did not finish") }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Mounts only a new fixture image beside this probe; the real system allocator chooses its temp location.
    func withVolume(_ body: (String) throws -> Void) throws {
        let volume = try attachVolume()
        defer { detachVolume(volume) }
        try body(volume)
    }

    func withVolume(_ body: (String) async throws -> Void) async throws {
        let volume = try attachVolume()
        defer { detachVolume(volume) }
        try await body(volume)
    }

    private func attachVolume() throws -> String {
        let volume = library + ".volume"
        let disk = library + ".sparseimage"
        try FileService().createDirectory(at: volume)
        try diskTool(["create", "-size", "64m", "-fs", "APFS", "-type", "SPARSE", "-volname", "WriterFixture", disk])
        try diskTool(["attach", "-nobrowse", "-mountpoint", volume, disk])
        return volume
    }

    private func detachVolume(_ volume: String) {
        do { try diskTool(["detach", volume]) } catch { XCTFail("Fixture detach failed: \(error)") }
    }

    private func diskTool(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static let source = #"""
    #include <unistd.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <fcntl.h>
    #include <signal.h>
    #include <sys/stat.h>
    #include <sys/param.h>
    #include <sys/file.h>
    #include <sys/wait.h>
    #include <errno.h>
    #define INTERPOSE(new, old) __attribute__((used)) static struct { const void *a; const void *b; } i_##old \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&new, (const void *)&old };
    static int point(const char *p) { const char *v = getenv("STORE_CRASH_POINT"); return v && !strcmp(v,p); }
    static void die(void) { kill(getpid(), SIGKILL); _exit(99); }
    static int temporary(const char *p) { return strstr(p, "/.pensieve-write-") != NULL; }
    static void occupy(int link) {
        const char *p = getenv("STORE_CRASH_DESTINATION");
        if (!p || !*p) _exit(98);
        unlink(p);
        if (link) { if (symlink("../outside", p)) _exit(97); }
        else {
            if (mkdir(p, 0700)) _exit(96);
            char keep[MAXPATHLEN]; snprintf(keep, sizeof(keep), "%s/keep", p);
            int fd = open(keep, O_CREAT|O_WRONLY|O_EXCL, 0600);
            if (fd < 0 || write(fd, "keep", 4) != 4) _exit(95);
            close(fd);
        }
    }
    static void location(const char *path) {
        const char *trace = getenv("STORE_LOCATION_TRACE");
        if (!trace || !strstr(path, "NSIRD_")) return;
        int fd = open(trace, O_CREAT|O_APPEND|O_WRONLY, 0600);
        if (fd >= 0) { write(fd, path, strlen(path)); write(fd, "\n", 1); close(fd); }
    }
    static int making(const char *path, mode_t mode) { location(path); return mkdir(path, mode); }
    static int makingat(int dir, const char *path, mode_t mode) { location(path); return mkdirat(dir, path, mode); }
    static int locking(int fd, int operation) {
        char path[MAXPATHLEN];
        int watched = !fcntl(fd, F_GETPATH, path) &&
            (strstr(path, ".pensieve-store-writes-") || strstr(path, "/.git"));
        if (watched && point("unsupported-lock")) { errno = ENOTSUP; return -1; }
        int result = flock(fd, operation);
        if (watched && result == 0 && point("namespace-race")) {
            char moved[MAXPATHLEN]; snprintf(moved, sizeof(moved), "%s.held", path);
            if (rename(path, moved) || mkdir(path, 0700)) _exit(93);
        }
        return result;
    }
    static char resolved_temporary[MAXPATHLEN];
    static char *resolving(const char *path, char *output) {
        char *result = realpath(path, output);
        if (result && strstr(result, "/TemporaryItems")) strlcpy(resolved_temporary, result, sizeof(resolved_temporary));
        return result;
    }
    static int stating(const char *path, struct stat *status) {
        int result = stat(path, status);
        if (result == 0 && point("wrong-device") && !strcmp(path, resolved_temporary)) status->st_dev ^= 1;
        return result;
    }
    static int syncing(int fd) {
        char path[MAXPATHLEN];
        if (!fcntl(fd, F_GETPATH, path) && temporary(path) && point("failed-sync")) { errno = EIO; return -1; }
        return fsync(fd);
    }
    static ssize_t writing(int fd, const void *bytes, size_t count) {
        char path[MAXPATHLEN];
        int watched = !fcntl(fd, F_GETPATH, path) && temporary(path);
        if (watched) {
            const char *report = getenv("STORE_CRASH_TRACE");
            int out = open(report, O_CREAT|O_TRUNC|O_WRONLY, 0600);
            if (out < 0 || write(out, path, strlen(path)) != strlen(path)) _exit(94);
            close(out);
        }
        if (watched && point("before-write")) die();
        if (watched && point("partial-write")) { write(fd, bytes, count > 7 ? 7 : count); die(); }
        if (watched && point("namespace-race")) {
            pid_t child = fork();
            if (child == 0) {
                setenv("STORE_CRASH_POINT", "complete", 1);
                execl(getenv("STORE_PROBE_EXECUTABLE"), "GitProcessProbe", "store-write-create",
                      getenv("STORE_PROBE_ROOT"), "unused", NULL);
                _exit(92);
            }
            int status; if (waitpid(child, &status, 0) != child || status != 0) _exit(91);
        }
        ssize_t result = write(fd, bytes, count);
        if (watched && point("after-write")) die();
        if (watched && point("link-before-check")) occupy(1);
        if (watched && point("folder-before-check")) occupy(0);
        return result;
    }
    static int renaming(const char *from, const char *to) {
        int watched = temporary(from);
        if (watched && point("before-rename")) die();
        if (watched && point("folder-after-check")) occupy(0);
        int result = rename(from, to);
        if (watched && point("after-rename")) die();
        return result;
    }
    static int renamingat(int dir, const char *from, int target, const char *to) {
        int watched = strstr(from, ".pensieve-write-") != NULL;
        if (watched && point("before-rename")) die();
        if (watched && point("folder-after-check")) occupy(0);
        int result = renameat(dir, from, target, to);
        if (watched && point("after-rename")) die();
        return result;
    }
    static int swapping(const char *from, const char *to, unsigned int flags) {
        int watched = temporary(from);
        if (watched && point("before-rename")) die();
        if (watched && point("folder-after-check")) occupy(0);
        int result = renamex_np(from, to, flags);
        if (watched && point("after-rename")) die();
        return result;
    }
    INTERPOSE(resolving, realpath)
    INTERPOSE(stating, stat)
    INTERPOSE(making, mkdir)
    INTERPOSE(makingat, mkdirat)
    INTERPOSE(locking, flock)
    INTERPOSE(syncing, fsync)
    INTERPOSE(renamingat, renameat)
    INTERPOSE(writing, write)
    INTERPOSE(renaming, rename)
    INTERPOSE(swapping, renamex_np)
    """#
}
