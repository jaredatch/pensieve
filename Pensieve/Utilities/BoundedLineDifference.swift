import Foundation

/// Hirschberg's shortest edit script: two score rows per split, released before recursion.
/// Work counts line comparisons and score cells, independently of edit distance.
enum BoundedLineDifference {
    // Two 2,500-line sides need fewer than 2 * 2,500² cells, plus linear trimming.
    static let maximumWork = 16 * 1_024 * 1_024
    static let checkpointInterval = 1_024

    struct Edits {
        var removed: Set<Int> = []
        var added: Set<Int> = []
    }

    static func compute(before: [String], after: [String], checkpoint: (Int) throws -> Void) throws -> Edits? {
        // Data equality is byte-exact, unlike String's canonical Unicode equality.
        // Interning scans the bounded input once; subsequent score cells compare integer identities.
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
                return search.edits
            } catch Failure.workExceeded { return nil }
        }
    }

    private enum Failure: Error { case workExceeded }

    private final class Search {
        let old: [Int]
        let new: [Int]
        let checkpoint: (Int) throws -> Void
        var edits: Edits
        var work = 0
        var nextCheckpoint = checkpointInterval

        init(old: [Int], new: [Int], checkpoint: @escaping (Int) throws -> Void) {
            self.old = old
            self.new = new
            self.checkpoint = checkpoint
            edits = Edits(removed: Set(old.indices), added: Set(new.indices))
        }

        func charge() throws {
            guard work < maximumWork else { throw Failure.workExceeded }
            work += 1
            if work >= nextCheckpoint {
                try checkpoint(work)
                nextCheckpoint = work + checkpointInterval
            }
        }

        func keep(_ before: Int, _ after: Int) {
            edits.removed.remove(before)
            edits.added.remove(after)
        }

        func match(_ before: Range<Int>, _ after: Range<Int>) throws {
            var left = before
            var right = after
            while !left.isEmpty && !right.isEmpty {
                try charge()
                guard old[left.lowerBound] == new[right.lowerBound] else { break }
                keep(left.lowerBound, right.lowerBound)
                left = (left.lowerBound + 1)..<left.upperBound
                right = (right.lowerBound + 1)..<right.upperBound
            }
            while !left.isEmpty && !right.isEmpty {
                try charge()
                guard old[left.upperBound - 1] == new[right.upperBound - 1] else { break }
                keep(left.upperBound - 1, right.upperBound - 1)
                left = left.lowerBound..<(left.upperBound - 1)
                right = right.lowerBound..<(right.upperBound - 1)
            }
            guard !left.isEmpty && !right.isEmpty else { return }
            if left.count == 1 {
                for index in right {
                    try charge()
                    if old[left.lowerBound] == new[index] { keep(left.lowerBound, index); break }
                }
                return
            }
            let middle = left.lowerBound + left.count / 2
            let boundary = try split(left, right, middle: middle)
            try match(left.lowerBound..<middle, right.lowerBound..<boundary)
            try match(middle..<left.upperBound, boundary..<right.upperBound)
        }

        func split(_ before: Range<Int>, _ after: Range<Int>, middle: Int) throws -> Int {
            // This split necessarily evaluates count(old) * count(new) score cells.
            // Refuse work that cannot fit before starting it (also avoids multiplying large counts).
            guard before.count <= (maximumWork - work) / after.count else { throw Failure.workExceeded }
            let forward = try scores(before.lowerBound..<middle, after, reversed: false)
            let backward = try scores(middle..<before.upperBound, after, reversed: true)
            var best = -1
            var boundary = 0
            for index in 0...after.count {
                let score = forward[index] + backward[after.count - index]
                if score > best { best = score; boundary = index }
            }
            return after.lowerBound + boundary
        }

        func scores(_ before: Range<Int>, _ after: Range<Int>, reversed: Bool) throws -> [Int] {
            var row = [Int](repeating: 0, count: after.count + 1)
            for offset in 0..<before.count {
                let oldIndex = reversed ? before.upperBound - 1 - offset : before.lowerBound + offset
                var diagonal = 0
                for column in 1...after.count {
                    try charge()
                    let above = row[column]
                    let newIndex = reversed ? after.upperBound - column : after.lowerBound + column - 1
                    row[column] = old[oldIndex] == new[newIndex] ? diagonal + 1 : max(above, row[column - 1])
                    diagonal = above
                }
            }
            return row
        }
    }
}
