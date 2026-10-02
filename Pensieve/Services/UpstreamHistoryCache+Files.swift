import Foundation

extension UpstreamHistoryCache {
    struct FileRecord {
        let path: String
        let bytes: Int
        let accessedAt: Date
    }

    func readEnvelope(skillID: UUID) -> Envelope? {
        guard usableDirectory(createIfMissing: false) else { return nil }
        let path = entryPath(skillID)
        guard let data = try? fileService.readRegularFileData(at: path, maximumBytes: entryByteLimit) else {
            return nil
        }
        return try? decoder.decode(Envelope.self, from: data)
    }

    @discardableResult
    func writeEnvelope(_ envelope: Envelope, skillID: UUID, generation: UInt64) -> Bool {
        guard usableDirectory(createIfMissing: true),
              let data = try? encoder.encode(envelope),
              data.count <= entryByteLimit,
              let content = String(data: data, encoding: .utf8) else { return false }
        let path = entryPath(skillID)
        guard safeReplacementTarget(path) else { return false }
        let temporary = directory + "/." + UUID().uuidString + ".tmp"
        do {
            try fileService.writeFile(at: temporary, content: content)
            guard fileService.isRegularFile(at: temporary),
                  publishIfCurrent(
                    temporary: temporary,
                    destination: path,
                    skillID: skillID,
                    generation: generation
                  ) else {
                removeTemporaryIfSafe(temporary)
                return false
            }
            datePublishedFile(path)
            return true
        } catch {
            removeTemporaryIfSafe(temporary)
            return false
        }
    }

    func touch(skillID: UUID, generation: UInt64) {
        guard generationIsCurrent(skillID: skillID, generation: generation) else { return }
        try? fileService.touchRegularFile(at: entryPath(skillID), date: now())
    }

    func pruneToTotalLimit() {
        guard usableDirectory(createIfMissing: false),
              let names = try? fileService.listDirectory(at: directory) else { return }
        var entries: [FileRecord] = []
        var total = 0
        for name in names {
            let path = directory + "/" + name
            if isTemporaryName(name) {
                removeStaleTemporaryIfSafe(path)
                continue
            }
            guard skillID(from: name) != nil else { continue }
            guard let entry = capacityRecord(path: path) else { continue }
            let (next, overflow) = total.addingReportingOverflow(entry.bytes)
            total = overflow ? Int.max : next
            entries.append(entry)
        }
        guard total > totalByteLimit else { return }
        entries.sort {
            if $0.accessedAt == $1.accessedAt { return $0.path < $1.path }
            return $0.accessedAt < $1.accessedAt
        }
        for entry in entries where total > totalByteLimit {
            guard fileService.isRegularFile(at: entry.path) else { continue }
            if (try? fileService.deleteFile(at: entry.path)) != nil { total -= entry.bytes }
        }
    }

    func removeEntryIfSafe(skillID: UUID) {
        guard usableDirectory(createIfMissing: false) else { return }
        removeEntryIfSafe(path: entryPath(skillID))
    }

    func removeEntryIfSafe(path: String) {
        guard fileService.isRegularFile(at: path) else { return }
        try? fileService.deleteFile(at: path)
    }

    func capacityRecord(path: String) -> FileRecord? {
        guard let metadata = fileService.regularFileMetadata(at: path) else {
            guard fileService.isRegularFile(at: path) else { return nil }
            return FileRecord(path: path, bytes: entryByteLimit, accessedAt: .distantPast)
        }
        guard metadata.byteCount <= entryByteLimit else {
            try? fileService.deleteFile(at: path)
            return nil
        }
        return FileRecord(
            path: path,
            bytes: metadata.byteCount,
            accessedAt: metadata.modificationDate
        )
    }

    func removeEntriesNotIn(_ retained: Set<UUID>) {
        guard usableDirectory(createIfMissing: false),
              let names = try? fileService.listDirectory(at: directory) else { return }
        for name in names {
            guard let skillID = skillID(from: name), !retained.contains(skillID) else { continue }
            removeEntryIfSafe(skillID: skillID)
        }
    }
}

extension UpstreamHistoryCache {
    var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    func usableDirectory(createIfMissing: Bool) -> Bool {
        guard !fileService.isSymlink(at: directory) else { return false }
        if fileService.directoryExists(at: directory) { return true }
        guard fileService.fileIdentity(at: directory, followingLinks: false) == nil,
              createIfMissing else { return false }
        do {
            try fileService.createDirectory(at: directory)
            return !fileService.isSymlink(at: directory) && fileService.directoryExists(at: directory)
        } catch {
            return false
        }
    }

    func safeReplacementTarget(_ path: String) -> Bool {
        if fileService.isSymlink(at: path) { return false }
        if fileService.fileIdentity(at: path, followingLinks: false) == nil { return true }
        return fileService.isRegularFile(at: path)
    }

    func entryPath(_ skillID: UUID) -> String {
        directory + "/" + skillID.uuidString.lowercased() + ".json"
    }

    func skillID(from name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        return UUID(uuidString: String(name.dropLast(5)))
    }

    func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(name.dropFirst().dropLast(4))) != nil
    }

    func removeTemporaryIfSafe(_ path: String) {
        guard fileService.isRegularFile(at: path) else { return }
        try? fileService.deleteFile(at: path)
    }

    func removeStaleTemporaryIfSafe(_ path: String) {
        guard let metadata = fileService.regularFileMetadata(at: path),
              metadata.modificationDate <= now().addingTimeInterval(-Self.staleTemporaryAge) else { return }
        try? fileService.deleteFile(at: path)
    }
}
