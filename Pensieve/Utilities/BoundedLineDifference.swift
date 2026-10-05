import Foundation

/// Myers' bidirectional middle-snake search. Frontiers are released before splitting children.
/// Work counts frontier visits and matching line advances, with no line or edit-distance cap.
enum BoundedLineDifference {
    static let maximumWork = 16 * 1_024 * 1_024
    static let checkpointInterval = 1_024

    struct Edits {
        var removed: Set<Int> = []
        var added: Set<Int> = []
    }

    static func compute(before: [String], after: [String], checkpoint: (Int) throws -> Void) throws -> Edits? {
        // Data equality preserves exact UTF-8 bytes, including Unicode spelling and line endings.
        var identities: [Data: Int] = [:]
        func keys(_ lines: [String]) throws -> [Int] {
            try lines.enumerated().map { index, line in
                if index % checkpointInterval == 0 { try checkpoint(0) }
                let bytes = Data(line.utf8)
                if let identity = identities[bytes] { return identity }
                let identity = identities.count
                identities[bytes] = identity
                return identity
            }
        }
        let old = try keys(before)
        let new = try keys(after)
        return try withoutActuallyEscaping(checkpoint) { callback in
            let search = Search(old: old, new: new, checkpoint: callback)
            do {
                try search.match(old.indices, new.indices)
                try checkpoint(search.work)
                return search.edits
            } catch Failure.workExceeded {
                try checkpoint(search.work)
                return nil
            }
        }
    }

    private enum Failure: Error { case workExceeded }

    private final class Search {
        let old: [Int]
        let new: [Int]
        let checkpoint: (Int) throws -> Void
        var edits = Edits()
        var work = 0

        init(old: [Int], new: [Int], checkpoint: @escaping (Int) throws -> Void) {
            self.old = old
            self.new = new
            self.checkpoint = checkpoint
        }

        func charge() throws {
            guard work < maximumWork else { throw Failure.workExceeded }
            work += 1
            if work % checkpointInterval == 0 { try checkpoint(work) }
        }

        func match(_ before: Range<Int>, _ after: Range<Int>) throws {
            var left = before
            var right = after
            while !left.isEmpty && !right.isEmpty {
                try charge()
                guard old[left.lowerBound] == new[right.lowerBound] else { break }
                left = (left.lowerBound + 1)..<left.upperBound
                right = (right.lowerBound + 1)..<right.upperBound
            }
            while !left.isEmpty && !right.isEmpty {
                try charge()
                guard old[left.upperBound - 1] == new[right.upperBound - 1] else { break }
                left = left.lowerBound..<(left.upperBound - 1)
                right = right.lowerBound..<(right.upperBound - 1)
            }
            if left.isEmpty { edits.added.formUnion(right); return }
            if right.isEmpty { edits.removed.formUnion(left); return }
            let point = try middle(left, right)
            try match(left.lowerBound..<point.0, right.lowerBound..<point.1)
            try match(point.0..<left.upperBound, point.1..<right.upperBound)
        }

        func middle(_ before: Range<Int>, _ after: Range<Int>) throws -> (Int, Int) {
            let length = (before.count + after.count + 1) / 2
            var forward = [Int](repeating: -1, count: 2 * length + 3)
            var reverse = forward
            forward[length + 2] = 0
            reverse[length + 2] = 0
            return try old.withUnsafeBufferPointer { old in
                try new.withUnsafeBufferPointer { new in
                    try forward.withUnsafeMutableBufferPointer { forward in
                        try reverse.withUnsafeMutableBufferPointer { reverse in
                            // Nonempty ranges and allocated frontiers prove these four pointers exist.
                            var search = MiddleSnake(old: old.baseAddress!, new: new.baseAddress!,
                                                     forward: forward.baseAddress!, backward: reverse.baseAddress!,
                                                     before: before, after: after, length: length,
                                                     work: work, checkpoint: checkpoint)
                            defer { work = search.work }
                            return try search.find()
                        }
                    }
                }
            }
        }
    }

    private struct MiddleSnake {
        let old: UnsafePointer<Int>
        let new: UnsafePointer<Int>
        let forward: UnsafeMutablePointer<Int>
        let backward: UnsafeMutablePointer<Int>
        let before: Range<Int>
        let after: Range<Int>
        let length: Int
        var work: Int
        let checkpoint: (Int) throws -> Void
        var starts = [0, 0]
        var ends = [0, 0]

        mutating func find() throws -> (Int, Int) {
            for depth in 0...length {
                if let point = try scan(depth: depth, reversed: false) { return point }
                if let point = try scan(depth: depth, reversed: true) { return point }
            }
            preconditionFailure("Myers frontiers must meet")
        }

        func check(_ spent: Int) throws {
            try checkpoint(spent)
            guard spent < maximumWork else { throw Failure.workExceeded }
        }

        mutating func scan(depth: Int, reversed: Bool) throws -> (Int, Int)? {
            let vector = reversed ? backward : forward
            let other = reversed ? forward : backward
            let side = reversed ? 1 : 0
            let offset = length + 1
            let oldCount = before.count
            let newCount = after.count
            let delta = oldCount - newCount
            let overlap = (delta % 2 != 0) != reversed
            var spent = work
            defer { work = spent }
            var diagonal = -depth + starts[side]
            while diagonal <= depth - ends[side] {
                defer { diagonal += 2 }
                spent += 1
                if spent % checkpointInterval == 0 { try check(spent) }
                let index = offset + diagonal
                var x = diagonal == -depth || (diagonal != depth && vector[index - 1] < vector[index + 1])
                    ? vector[index + 1] : vector[index - 1] + 1
                var y = x - diagonal
                while x < oldCount && y < newCount && old[reversed ? before.upperBound - x - 1 : before.lowerBound + x]
                    == new[reversed ? after.upperBound - y - 1 : after.lowerBound + y] {
                    spent += 1
                    if spent % checkpointInterval == 0 { try check(spent) }
                    x += 1
                    y += 1
                }
                vector[index] = x
                if x > oldCount { ends[side] += 2; continue }
                if y > newCount { starts[side] += 2; continue }
                let opposite = offset + delta - diagonal
                guard overlap, opposite >= 0, opposite < 2 * length + 3, other[opposite] != -1 else { continue }
                if x >= oldCount - other[opposite] {
                    let splitX = reversed ? other[opposite] : x
                    let splitY = reversed ? splitX - (delta - diagonal) : y
                    return (before.lowerBound + splitX, after.lowerBound + splitY)
                }
            }
            return nil
        }
    }
}
