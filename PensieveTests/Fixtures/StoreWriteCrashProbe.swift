import Darwin
import XCTest
@testable import Pensieve

/// Runs the production writers in the existing disposable helper. A dylib intercepts their real
/// write and rename syscalls, either killing the child or inserting a filesystem race. It does not
/// invent an intermediate name, replace writer logic, or intercept any other process's I/O.
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
        let process = Process()
        process.executableURL = Bundle(for: SyncBytePreservationTests.self).bundleURL
            .appendingPathComponent("Contents/MacOS/GitProcessProbe")
        process.arguments = ["store-write-" + writer, root, root + "/unused-report"]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = library
        environment["STORE_CRASH_POINT"] = point
        environment["STORE_CRASH_TRACE"] = library + ".path"
        environment["STORE_CRASH_DESTINATION"] = destination
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); XCTFail("Writer did not finish") }
        process.waitUntilExit()
        return process.terminationStatus
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
    static int swapping(const char *from, const char *to, unsigned int flags) {
        int watched = temporary(from);
        if (watched && point("before-rename")) die();
        if (watched && point("folder-after-check")) occupy(0);
        int result = renamex_np(from, to, flags);
        if (watched && point("after-rename")) die();
        return result;
    }
    INTERPOSE(writing, write)
    INTERPOSE(renaming, rename)
    INTERPOSE(swapping, renamex_np)
    """#
}
