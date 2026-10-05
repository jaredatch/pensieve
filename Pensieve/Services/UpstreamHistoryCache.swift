import Foundation

/// Disposable, versioned storage for parsed History reads. Callers invoke synchronous disk work from
/// detached tasks. The state lock orders generations; the serial maintenance queue orders filesystem work.
final class UpstreamHistoryCache: @unchecked Sendable {
    static let schemaVersion = 3
    static let defaultEntryByteLimit = 96 * 1_024 * 1_024
    static let defaultTotalByteLimit = 256 * 1_024 * 1_024
    static let staleTemporaryAge: TimeInterval = 60 * 60
    static let maximumAdmittedWindow = min(
        (Int.max - 1) / UpstreamHistoryService.commitWindow,
        (Int.max - 1) / UpstreamHistoryService.rowWindow
    ) - 1

    struct Entry: Equatable {
        let origin: InstalledOrigin
        let recordedHeadAtRead: String?
        let readHead: String
        let result: UpstreamHistoryResult
    }

    struct Envelope: Codable {
        let schemaVersion: Int
        let origin: InstalledOrigin
        let recordedHeadAtRead: String?
        let readHead: String
        let result: CachedResult
    }

    struct CachedResult: Codable {
        let headCommit: String
        let rows: [UpstreamHistoryRow]
        let installedPosition: UpstreamHistoryInstalledPosition
        let hasOlderHistory: Bool
        let installedBaseline: UpstreamHistoryBaseline?
        let windowCount: Int

        init(_ result: UpstreamHistoryResult) {
            headCommit = result.headCommit
            rows = result.rows
            installedPosition = result.installedPosition
            hasOlderHistory = result.hasOlderHistory
            installedBaseline = result.installedBaseline
            windowCount = result.windowCount
        }

    }

    private struct SkillState {
        var generation: UInt64 = 0
        var blocked = false
        var latestStoredOrdinal: UInt64 = 0
    }

    let directory: String
    let entryByteLimit: Int
    let totalByteLimit: Int
    let fileService: FileServiceProtocol
    let now: @Sendable () -> Date
    let datePublishedFile: (String) -> Void
    private let stateLock = NSLock()
    private var states: [UUID: SkillState] = [:]
    let maintenanceQueue = DispatchQueue(label: "com.jaredatch.pensieve.upstream-history-cache")

    init(
        directory: String,
        fileService: FileServiceProtocol = FileService(),
        entryByteLimit: Int = UpstreamHistoryCache.defaultEntryByteLimit,
        totalByteLimit: Int = UpstreamHistoryCache.defaultTotalByteLimit,
        now: (@Sendable () -> Date)? = nil
    ) {
        self.directory = directory
        self.fileService = fileService
        self.entryByteLimit = max(entryByteLimit, 0)
        self.totalByteLimit = max(totalByteLimit, 0)
        self.now = now ?? { Date() }
        if let now {
            datePublishedFile = { path in
                try? fileService.touchRegularFile(at: path, date: now())
            }
        } else {
            datePublishedFile = { _ in }
        }
    }

    func beginRequest(skillID: UUID, superseding: Bool) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        var state = states[skillID] ?? SkillState()
        if superseding || state.blocked {
            state.generation &+= 1
            state.latestStoredOrdinal = 0
        }
        state.blocked = false
        states[skillID] = state
        return state.generation
    }

    func remove(skillID: UUID) {
        stateLock.lock()
        var state = states[skillID] ?? SkillState()
        state.generation &+= 1
        state.blocked = true
        state.latestStoredOrdinal = 0
        states[skillID] = state
        stateLock.unlock()
        maintenanceQueue.async { [self] in removeEntryIfSafe(skillID: skillID) }
    }

    func retain(skillIDs: Set<UUID>) {
        stateLock.lock()
        for skillID in states.keys where !skillIDs.contains(skillID) {
            var state = states[skillID] ?? SkillState()
            state.generation &+= 1
            state.blocked = true
            state.latestStoredOrdinal = 0
            states[skillID] = state
        }
        stateLock.unlock()
        maintenanceQueue.async { [self] in removeEntriesNotIn(skillIDs) }
    }

    func load(
        skillID: UUID,
        origin: InstalledOrigin,
        minimumWindow: Int,
        generation: UInt64
    ) -> Entry? {
        guard generationIsCurrent(skillID: skillID, generation: generation) else { return nil }
        let loaded: Entry? = withOrderedDiskAccess { [self] in
            guard generationIsCurrent(skillID: skillID, generation: generation),
                  let envelope = readEnvelope(skillID: skillID),
                  envelope.origin.hasSameHistoryIdentity(as: origin),
                  envelope.result.windowCount >= minimumWindow,
                  validate(envelope) else { return nil }
            return Entry(
                origin: envelope.origin,
                recordedHeadAtRead: envelope.recordedHeadAtRead,
                readHead: envelope.readHead,
                result: sanitizedResult(envelope.result)
            )
        }
        if loaded != nil {
            maintenanceQueue.async { [self] in
                touch(skillID: skillID, generation: generation)
            }
        }
        return loaded
    }

    func store(
        skillID: UUID,
        origin: InstalledOrigin,
        recordedHeadAtRead: String?,
        result: UpstreamHistoryResult,
        generation: UInt64,
        ordinal: UInt64
    ) {
        guard generationIsCurrent(skillID: skillID, generation: generation) else { return }
        withOrderedDiskAccess { [self] in
            guard generationIsCurrent(skillID: skillID, generation: generation) else { return }
            let envelope = Envelope(
                schemaVersion: Self.schemaVersion,
                origin: origin,
                recordedHeadAtRead: recordedHeadAtRead,
                readHead: result.headCommit,
                result: CachedResult(result)
            )
            let existing = readEnvelope(skillID: skillID)
            guard ordinalMayStore(
                skillID: skillID,
                generation: generation,
                ordinal: ordinal,
                candidate: envelope,
                existing: existing
            ), validate(envelope), shouldReplace(envelope, existing: existing),
                  writeEnvelope(envelope, skillID: skillID, generation: generation) else { return }
            recordStoredOrdinal(skillID: skillID, generation: generation, ordinal: ordinal)
            pruneToTotalLimit()
        }
    }

}

extension UpstreamHistoryCache {
    func generationIsCurrent(skillID: UUID, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let state = states[skillID] ?? SkillState()
        return !state.blocked && state.generation == generation
    }

    func ordinalMayStore(
        skillID: UUID,
        generation: UInt64,
        ordinal: UInt64,
        candidate: Envelope,
        existing: Envelope?
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let state = states[skillID] ?? SkillState()
        guard !state.blocked && state.generation == generation else { return false }
        if ordinal >= state.latestStoredOrdinal { return true }
        guard let existing else { return false }
        return existing.origin.hasSameHistoryIdentity(as: candidate.origin)
            && existing.readHead == candidate.readHead
            && candidate.result.windowCount > existing.result.windowCount
    }

    func recordStoredOrdinal(skillID: UUID, generation: UInt64, ordinal: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var state = states[skillID], !state.blocked, state.generation == generation else { return }
        state.latestStoredOrdinal = max(state.latestStoredOrdinal, ordinal)
        states[skillID] = state
    }

    func publishIfCurrent(
        temporary: String,
        destination: String,
        skillID: UUID,
        generation: UInt64
    ) -> Bool {
        guard generationIsCurrent(skillID: skillID, generation: generation),
              safeReplacementTarget(destination) else { return false }
        do {
            try fileService.replaceItem(at: destination, with: temporary)
            guard generationIsCurrent(skillID: skillID, generation: generation) else {
                removeTemporaryIfSafe(destination)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    func shouldReplace(_ candidate: Envelope, existing: Envelope?) -> Bool {
        guard let existing, validate(existing) else { return true }
        guard existing.origin.hasSameHistoryIdentity(as: candidate.origin) else { return true }
        guard existing.readHead == candidate.readHead,
              candidate.recordedHeadAtRead == existing.recordedHeadAtRead
                || candidate.recordedHeadAtRead == existing.readHead else { return true }
        return candidate.result.windowCount >= existing.result.windowCount
    }

    func sanitizedResult(_ cached: CachedResult) -> UpstreamHistoryResult {
        let rows = cached.rows.map(UpstreamHistoryService.safeRow)
        return UpstreamHistoryResult(
            headCommit: cached.headCommit,
            rows: rows,
            installedPosition: cached.installedPosition,
            hasOlderHistory: cached.hasOlderHistory,
            installedBaseline: cached.installedBaseline,
            localEdits: .none,
            windowCount: cached.windowCount
        )
    }

    func withOrderedDiskAccess<T>(_ action: () -> T) -> T {
        maintenanceQueue.sync(execute: action)
    }
}

private extension InstalledOrigin {
    func hasSameHistoryIdentity(as other: InstalledOrigin) -> Bool {
        repo == other.repo
            && path == other.path
            && ref == other.ref
            && installedCommit == other.installedCommit
            && installedTree == other.installedTree
            && contentHash == other.contentHash
    }
}
