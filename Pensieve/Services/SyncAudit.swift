import Foundation

/// The status payload shared by the resident coordinator and the SSH-compatible daemon CLI.
struct DaemonStatus: Codable, Equatable {
    let timestamp: String
    let result: String
    let detail: String
}

protocol SyncAuditWriting {
    func record(category: String, detail: String)
}

/// Writes the CLI-compatible status snapshot and bounded cycle log through the FileService boundary.
struct SyncAudit: SyncAuditWriting {
    static let logRotateThreshold = 256 * 1024

    private let appSupport: String
    private let fileService: FileServiceProtocol
    private let now: () -> Date

    init(
        appSupport: String,
        fileService: FileServiceProtocol = FileService(),
        now: @escaping () -> Date = Date.init
    ) {
        self.appSupport = appSupport
        self.fileService = fileService
        self.now = now
    }

    func record(category: String, detail: String) {
        let category = DisplayTextSanitizer.singleLine(category)
        let detail = Self.boundedDetail(DisplayTextSanitizer.singleLine(detail))
        try? fileService.createDirectory(at: appSupport)
        guard let lock = SyncLock.acquire(at: appSupport + "/daemon-audit.lock") else { return }
        defer { lock.release() }
        let timestamp = iso(now())
        writeStatus(category: category, detail: detail, timestamp: timestamp)
        appendLog(category: category, detail: detail, timestamp: timestamp)
    }

    /// Append supporting detail without replacing the CLI-compatible last-cycle status snapshot.
    func append(category: String, detail: String) {
        let category = DisplayTextSanitizer.singleLine(category)
        let detail = Self.boundedDetail(DisplayTextSanitizer.singleLine(detail))
        try? fileService.createDirectory(at: appSupport)
        guard let lock = SyncLock.acquire(at: appSupport + "/daemon-audit.lock") else { return }
        defer { lock.release() }
        appendLog(category: category, detail: detail, timestamp: iso(now()))
    }

    /// Keep git's command and final fatal line while bounding both the status and rotated logs.
    private static func boundedDetail(_ detail: String) -> String {
        let limit = 4096
        guard detail.utf8.count > limit else { return detail }
        let marker = " [... cut ...] "
        let available = limit - marker.utf8.count
        let headBudget = available * 3 / 4
        var head = "", tail = "", bytes = 0
        for character in detail {
            let count = character.utf8.count
            guard bytes + count <= headBudget else { break }
            head.append(character)
            bytes += count
        }
        bytes = 0
        for character in detail.reversed() {
            let count = character.utf8.count
            guard bytes + count <= available - headBudget else { break }
            tail.append(character)
            bytes += count
        }
        return head + marker + String(tail.reversed())
    }

    private func writeStatus(category: String, detail: String, timestamp: String) {
        let status = DaemonStatus(timestamp: timestamp, result: category, detail: detail)
        guard let data = try? JSONEncoder().encode(status),
              let text = String(data: data, encoding: .utf8) else { return }
        try? fileService.writeFile(at: appSupport + "/daemon-status.json", content: text)
    }

    private func appendLog(category: String, detail: String, timestamp: String) {
        let path = appSupport + "/daemon.log"
        let existing = (try? fileService.readFile(at: path)) ?? ""
        let line = "\(timestamp) \(category) \(detail)\n"
        if existing.utf8.count > Self.logRotateThreshold {
            try? fileService.writeFile(at: path + ".1", content: existing)
            try? fileService.writeFile(at: path, content: line)
        } else {
            try? fileService.writeFile(at: path, content: existing + line)
        }
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
