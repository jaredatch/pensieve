import Darwin
import Foundation

extension FileService {
    enum ComparisonCheckpoint {
        case directory(String)
        case opened(String)
        case read(path: String, bytes: Int, retained: Int)
    }

    func compareFileTrees(local: String, upstream: String, excludingUpstreamGit: Bool,
                          limits: FileTreeComparisonLimits, beforeReading: () throws -> Int) throws -> FileTreeComparison {
        try compareFileTrees(local: local, upstream: upstream, excludingUpstreamGit: excludingUpstreamGit,
                             limits: limits, beforeReading: beforeReading, checkpoint: { _ in })
    }

    /// Checkpoints exercise races after directory/leaf admission and report actual bytes and retained content.
    /// No content is read until both inventories have refused every link and special entry.
    func compareFileTrees(local: String, upstream: String, excludingUpstreamGit: Bool,
                          limits: FileTreeComparisonLimits, beforeReading: () throws -> Int = { 0 },
                          checkpoint: @escaping (ComparisonCheckpoint) throws -> Void) throws -> FileTreeComparison {
        guard limits.maximumFileBytes >= 0, limits.maximumFiles >= 0, limits.maximumTotalBytes >= 0,
              limits.maximumEntries >= 0, limits.maximumDepth >= 0 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let budget = ComparisonInventoryBudget(limits: limits)
        let before = try comparisonInventory(at: local, excludingGit: false, budget: budget) { try checkpoint(.directory($0)) }
        let after = try comparisonInventory(at: upstream, excludingGit: excludingUpstreamGit, budget: budget) {
            try checkpoint(.directory($0))
        }
        let admissionBytes = try beforeReading()
        let paths = Set(before.keys).union(after.keys).sorted {
            let left = max(before[$0]?.status.st_size ?? 0, after[$0]?.status.st_size ?? 0)
            let right = max(before[$1]?.status.st_size ?? 0, after[$1]?.status.st_size ?? 0)
            let leftSkill = $0 == "SKILL.md" && left <= limits.maximumFileBytes
            let rightSkill = $1 == "SKILL.md" && right <= limits.maximumFileBytes
            if leftSkill != rightSkill { return leftSkill }
            return left == right ? $0.utf8.lexicographicallyPrecedes($1.utf8) : left < right
        }
        var changes: [FileTreeChange] = []
        var processed = 0
        guard (0...limits.maximumTotalBytes).contains(admissionBytes) else {
            throw CocoaError(.fileReadTooLarge)
        }
        let reader = ComparisonReader(limits: limits, admissionBytes: admissionBytes, checkpoint: checkpoint)
        for path in paths {
            if processed == limits.maximumFiles || reader.bytesRead == limits.maximumTotalBytes { break }
            do {
                let kind: FileTreeChange.Kind = before[path] == nil ? .added : (after[path] == nil ? .removed : .modified)
                if let change = try reader.compare(before[path], after[path], path: path, kind: kind) {
                    changes.append(change)
                }
                processed += 1
            } catch ComparisonReader.Failure.budgetExceeded {
                break
            }
        }
        return FileTreeComparison(changes: changes.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
                                  unreadFileCount: paths.count - processed, bytesRead: reader.bytesRead)
    }
}

private final class ComparisonReader {
    enum Failure: Error { case budgetExceeded }
    let limits: FileTreeComparisonLimits
    let checkpoint: (FileService.ComparisonCheckpoint) throws -> Void
    var bytesRead = 0
    var remaining: Int { limits.maximumTotalBytes - bytesRead }

    init(limits: FileTreeComparisonLimits, admissionBytes: Int,
         checkpoint: @escaping (FileService.ComparisonCheckpoint) throws -> Void) {
        self.limits = limits
        self.checkpoint = checkpoint
        bytesRead = admissionBytes
    }

    func compare(_ old: ComparisonFile?, _ new: ComparisonFile?, path: String,
                 kind: FileTreeChange.Kind) throws -> FileTreeChange? {
        let before = try old?.open()
        let after = try new?.open()
        if let before { try checkpoint(.opened(before.entry.path)) }
        if let after { try checkpoint(.opened(after.entry.path)) }
        guard let content = try compareContent(before, after) else { return nil }
        return FileTreeChange(path: path, kind: kind, content: content, permissions: permissions(before, after))
    }

    private func compareContent(_ before: ComparisonOpenedFile?,
                                _ after: ComparisonOpenedFile?) throws -> FileTreeChange.Content? {
        let oversized = (before?.initial.st_size ?? 0) > limits.maximumFileBytes
            || (after?.initial.st_size ?? 0) > limits.maximumFileBytes
        if oversized {
            let equal = try oversizedEqual(before, after)
            let unstable = try changed(before, after)
            if unstable || !equal { return .tooLarge }
            return modeChange(before, after)
        }
        let oldData = try data(before)
        let newData = try data(after)
        if try changed(before, after) { return .tooLarge }
        if before != nil && after != nil && oldData == newData { return modeChange(before, after) }
        guard let oldText = String(validating: oldData, as: UTF8.self), let newText = String(validating: newData, as: UTF8.self),
              !oldData.contains(0), !newData.contains(0) else { return .binary }
        return .text(old: oldText, new: newText)
    }

    private func permissions(_ old: ComparisonOpenedFile?, _ new: ComparisonOpenedFile?) -> FileTreeChange.Permissions? {
        guard let old, let new else { return nil }
        let before = UInt32(old.initial.st_mode & 0o777)
        let after = UInt32(new.initial.st_mode & 0o777)
        return before == after ? nil : .init(old: before, new: after)
    }

    private func modeChange(_ old: ComparisonOpenedFile?, _ new: ComparisonOpenedFile?) -> FileTreeChange.Content? {
        permissions(old, new) == nil ? nil : .modeOnly
    }

    private func changed(_ old: ComparisonOpenedFile?, _ new: ComparisonOpenedFile?) throws -> Bool {
        // Evaluate both validations even when the first already changed.
        let before = try old?.changed() ?? false
        let after = try new?.changed() ?? false
        return before || after
    }

    private func data(_ file: ComparisonOpenedFile?) throws -> Data {
        guard let file else { return Data() }
        guard file.initial.st_size >= 0 else { throw DescriptorFileCopy.error("negative size", path: file.entry.path, code: EIO) }
        let target = Int(file.initial.st_size)
        var result = Data(count: target)
        var offset = 0
        while offset < target {
            let count = try read(file, into: &result, offset: offset, maximum: min(64 * 1_024, target - offset))
            if count == 0 { break }
            offset += count
        }
        result.count = offset
        return result
    }

    private func oversizedEqual(_ old: ComparisonOpenedFile?, _ new: ComparisonOpenedFile?) throws -> Bool {
        guard let old, let new, old.initial.st_size == new.initial.st_size,
              old.initial.st_size >= 0 else { return false }
        var offset: off_t = 0
        while offset < old.initial.st_size {
            guard remaining >= 2 else { throw Failure.budgetExceeded }
            let count = min(64 * 1_024, min(Int(old.initial.st_size - offset), remaining / 2))
            let left = try chunk(old, maximum: count)
            let right = try chunk(new, maximum: count)
            if left != right || left.isEmpty { return false }
            offset += off_t(left.count)
        }
        return true
    }

    private func chunk(_ file: ComparisonOpenedFile, maximum: Int) throws -> Data {
        guard remaining > 0 else { throw Failure.budgetExceeded }
        var buffer = Data(count: min(maximum, remaining))
        var offset = 0
        while offset < buffer.count {
            let count = try read(file, into: &buffer, offset: offset, maximum: buffer.count - offset)
            offset += count
            if count == 0 { break }
        }
        buffer.count = offset
        return buffer
    }

    /// Read directly into the retained buffer; appending a copied chunk would briefly hold extra file bytes.
    private func read(_ file: ComparisonOpenedFile, into buffer: inout Data, offset: Int,
                      maximum: Int) throws -> Int {
        guard remaining > 0 else { throw Failure.budgetExceeded }
        while true {
            try Task.checkCancellation()
            let request = min(maximum, remaining)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(file.descriptor, $0.baseAddress?.advanced(by: offset), request)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DescriptorFileCopy.error("read", path: file.entry.path, code: errno) }
            bytesRead += count
            try checkpoint(.read(path: file.entry.path, bytes: count, retained: offset + count))
            return count
        }
    }
}
