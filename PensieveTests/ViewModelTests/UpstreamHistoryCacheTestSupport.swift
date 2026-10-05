import Foundation
import XCTest
@testable import Pensieve

class UpstreamHistoryCacheTestCase: XCTestCase {
    var tempRoot = ""
    var appSupport = ""
    var storeRoot = ""
    var scratchRoot = ""
    var cacheDirectory = ""
    let fileService = FileService()

    override func setUpWithError() throws {
        tempRoot = TestTemporaryDirectory.path + "PensieveHistoryCacheTests-" + UUID().uuidString
        appSupport = tempRoot + "/app-support"
        storeRoot = tempRoot + "/store"
        scratchRoot = appSupport + "/upstream-history-scratch"
        cacheDirectory = appSupport + "/upstream-history-cache"
        try fileService.createDirectory(at: appSupport)
        try fileService.createDirectory(at: storeRoot)
    }

    override func tearDownWithError() throws {
        if fileService.directoryExists(at: tempRoot) || fileService.isSymlink(at: tempRoot) {
            try fileService.deleteDirectory(at: tempRoot)
        }
    }

    func cache(
        entryLimit: Int = UpstreamHistoryCache.defaultEntryByteLimit,
        totalLimit: Int = UpstreamHistoryCache.defaultTotalByteLimit,
        now: (@Sendable () -> Date)? = nil,
        fileService override: FileServiceProtocol? = nil
    ) -> UpstreamHistoryCache {
        UpstreamHistoryCache(
            directory: cacheDirectory,
            fileService: override ?? fileService,
            entryByteLimit: entryLimit,
            totalByteLimit: totalLimit,
            now: now
        )
    }

    func cachePath(_ skillID: UUID) -> String {
        cacheDirectory + "/" + skillID.uuidString.lowercased() + ".json"
    }

    func origin(for skill: Skill) throws -> InstalledOrigin {
        try XCTUnwrap(skill.installedOrigin)
    }

    func result(
        head: String = String(repeating: "b", count: 40),
        window: Int = 1,
        rows: [UpstreamHistoryRow]? = nil,
        position: UpstreamHistoryInstalledPosition? = nil,
        baseline: UpstreamHistoryBaseline? = .files([]),
        subject: String = "Subject"
    ) -> UpstreamHistoryResult {
        let actualRows = rows ?? [row(sha: head, subject: subject)]
        return UpstreamHistoryResult(
            headCommit: head,
            rows: actualRows,
            installedPosition: position ?? .at(sha: head),
            hasOlderHistory: window > 1,
            installedBaseline: baseline,
            localEdits: .none,
            windowCount: window
        )
    }

    func row(
        sha: String = String(repeating: "b", count: 40),
        author: String = "Author",
        subject: String = "Subject",
        text: UpstreamHistoryText? = .text("# Demo")
    ) -> UpstreamHistoryRow {
        UpstreamHistoryRow(
            sha: sha,
            author: author,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            subject: subject,
            filesChanged: 1,
            linesAdded: 2,
            linesRemoved: 1,
            skillMarkdown: text
        )
    }

    func envelope(
        skill: Skill,
        result: UpstreamHistoryResult,
        schemaVersion: Int = UpstreamHistoryCache.schemaVersion,
        recordedHead: String? = nil,
        origin override: InstalledOrigin? = nil
    ) throws -> UpstreamHistoryCache.Envelope {
        UpstreamHistoryCache.Envelope(
            schemaVersion: schemaVersion,
            origin: try override ?? origin(for: skill),
            recordedHeadAtRead: recordedHead,
            readHead: result.headCommit,
            result: UpstreamHistoryCache.CachedResult(result)
        )
    }

    func writeEnvelope(_ envelope: UpstreamHistoryCache.Envelope, skillID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try fileService.writeFile(at: cachePath(skillID), content: try XCTUnwrap(String(data: data, encoding: .utf8)))
    }

    func storedEnvelope(_ skillID: UUID) throws -> UpstreamHistoryCache.Envelope {
        let data = try fileService.readData(at: cachePath(skillID))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(UpstreamHistoryCache.Envelope.self, from: data)
    }

    @MainActor
    func owner(
        cache: UpstreamHistoryCache,
        read: @escaping UpstreamHistoryViewModel.ReadOperation,
        head: UpstreamHistoryViewModel.HeadOperation? = nil,
        localEdits: @escaping UpstreamHistoryViewModel.LocalEditsOperation = { _, _, _ in .none },
        localDirectory: String? = nil
    ) -> UpstreamHistoryViewModel {
        historyOwner(
            read: read,
            head: head,
            localEdits: localEdits,
            localDirectory: { _ in localDirectory ?? self.tempRoot + "/local-skill" },
            cache: cache
        )
    }
}

class CountingHistoryFileService: FileServiceProtocol {
    let base: FileService
    private let lock = NSLock()
    private var regularReadCount = 0

    init(base: FileService) { self.base = base }

    var regularReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return regularReadCount
    }

    func resetRegularReads() {
        lock.lock()
        regularReadCount = 0
        lock.unlock()
    }

    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        lock.lock()
        regularReadCount += 1
        lock.unlock()
        return try base.readRegularFileData(at: path, maximumBytes: maximumBytes)
    }

    func readFile(at path: String) throws -> String { try base.readFile(at: path) }
    func writeFile(at path: String, content: String) throws { try base.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try base.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { base.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try base.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try base.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try base.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { base.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { base.isRegularFile(at: path) }
    func listDirectory(at path: String) throws -> [String] { try base.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try base.contentsHash(at: path) }
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        base.fileIdentity(at: path, followingLinks: followingLinks)
    }
    func realPath(at path: String) -> String { base.realPath(at: path) }
    func regularFileMetadata(at path: String) -> RegularFileMetadata? {
        base.regularFileMetadata(at: path)
    }
    func touchRegularFile(at path: String, date: Date) throws {
        try base.touchRegularFile(at: path, date: date)
    }
}

final class RecordingTouchHistoryFileService: CountingHistoryFileService {
    private let touchLock = NSLock()
    private var recordedDates: [Date] = []

    var touchDates: [Date] {
        touchLock.lock()
        defer { touchLock.unlock() }
        return recordedDates
    }

    override func touchRegularFile(at path: String, date: Date) throws {
        touchLock.lock()
        recordedDates.append(date)
        touchLock.unlock()
        try super.touchRegularFile(at: path, date: date)
    }
}

final class MetadataCountingHistoryFileService: CountingHistoryFileService {
    private let countLock = NSLock()
    private var metadataCount = 0
    private var regularCount = 0

    var metadataCalls: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return metadataCount
    }

    var regularFileCalls: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return regularCount
    }

    override func regularFileMetadata(at path: String) -> RegularFileMetadata? {
        countLock.lock()
        metadataCount += 1
        countLock.unlock()
        return super.regularFileMetadata(at: path)
    }

    override func isRegularFile(at path: String) -> Bool {
        countLock.lock()
        regularCount += 1
        countLock.unlock()
        return super.isRegularFile(at: path)
    }
}

final class UnknownMetadataHistoryFileService: CountingHistoryFileService {
    override func regularFileMetadata(at path: String) -> RegularFileMetadata? { nil }
}

final class BlockingDeleteHistoryFileService: CountingHistoryFileService {
    let deleteStarted = DispatchSemaphore(value: 0)
    let releaseDelete: TestWait.Gate
    private let blockLock = NSLock()
    private var blockedPath: String?

    init(base: FileService, owner: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        releaseDelete = TestWait.Gate(owner: owner, file: file, line: line)
        super.init(base: base)
    }

    func blockNextDelete(at path: String) {
        blockLock.lock()
        blockedPath = path
        blockLock.unlock()
    }

    override func deleteFile(at path: String) throws {
        blockLock.lock()
        let shouldBlock = blockedPath == path
        if shouldBlock { blockedPath = nil }
        blockLock.unlock()
        if shouldBlock {
            deleteStarted.signal()
            try releaseDelete.wait()
        }
        try base.deleteFile(at: path)
    }
}

final class BlockingReadHistoryFileService: CountingHistoryFileService {
    let readStarted = DispatchSemaphore(value: 0)
    let releaseRead: TestWait.Gate
    private let blockLock = NSLock()
    private var blockedPath: String?

    init(base: FileService, owner: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        releaseRead = TestWait.Gate(owner: owner, file: file, line: line)
        super.init(base: base)
    }

    func blockNextRead(at path: String) {
        blockLock.lock()
        blockedPath = path
        blockLock.unlock()
    }

    override func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        blockLock.lock()
        let shouldBlock = blockedPath == path
        if shouldBlock { blockedPath = nil }
        blockLock.unlock()
        if shouldBlock {
            readStarted.signal()
            try releaseRead.wait()
        }
        return try super.readRegularFileData(at: path, maximumBytes: maximumBytes)
    }
}
