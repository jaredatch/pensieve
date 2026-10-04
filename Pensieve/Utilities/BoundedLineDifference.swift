import Foundation

/// Myers' shortest edit path, with a bounded frontier and charged byte comparisons.
/// Hash mismatches avoid rescanning long lines; matching hashes still compare exact UTF-8 bytes.
enum BoundedLineDifference {
    static let maximumEditDistance = 256
    static let maximumWork = 4 * 1_024 * 1_024
    static let checkpointInterval = 1_024

    struct Edits {
        var removed: Set<Int> = []
        var added: Set<Int> = []
    }

    struct Key {
        let hash: UInt64
        let count: Int
        init(_ line: String) {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in line.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            self.hash = hash
            count = line.utf8.count
        }
    }

    static func compute(before: [String], after: [String], checkpoint: (Int) throws -> Void) throws -> Edits? {
        let oldKeys = before.map(Key.init)
        let newKeys = after.map(Key.init)
        let offset = maximumEditDistance + 1
        var frontier = [Int](repeating: 0, count: 2 * maximumEditDistance + 3)
        var trace: [[Int]] = []
        var work = 0
        var nextCheckpoint = checkpointInterval
        for depth in 0...maximumEditDistance {
            trace.append(frontier)
            for diagonal in stride(from: -depth, through: depth, by: 2) {
                work += 1
                var x = diagonal == -depth || (diagonal != depth && frontier[offset + diagonal - 1]
                    < frontier[offset + diagonal + 1])
                    ? frontier[offset + diagonal + 1] : frontier[offset + diagonal - 1] + 1
                var y = x - diagonal
                while x < before.count && y < after.count {
                    let sameHash = oldKeys[x].hash == newKeys[y].hash && oldKeys[x].count == newKeys[y].count
                    work += sameHash ? oldKeys[x].count + 1 : 1
                    if work > maximumWork { return nil }
                    if work >= nextCheckpoint {
                        try checkpoint(work)
                        nextCheckpoint = work + checkpointInterval
                    }
                    guard sameHash && before[x].utf8.elementsEqual(after[y].utf8) else { break }
                    x += 1
                    y += 1
                }
                if work > maximumWork { return nil }
                if work >= nextCheckpoint {
                    try checkpoint(work)
                    nextCheckpoint = work + checkpointInterval
                }
                frontier[offset + diagonal] = x
                if x >= before.count && y >= after.count {
                    return backtrack(trace: trace, depth: depth, oldCount: before.count, newCount: after.count, offset: offset)
                }
            }
        }
        return nil
    }

    private static func backtrack(trace: [[Int]], depth: Int, oldCount: Int, newCount: Int, offset: Int) -> Edits {
        var x = oldCount
        var y = newCount
        var edits = Edits()
        for distance in stride(from: depth, through: 1, by: -1) {
            let frontier = trace[distance]
            let diagonal = x - y
            let previous = diagonal == -distance || (diagonal != distance && frontier[offset + diagonal - 1]
                < frontier[offset + diagonal + 1]) ? diagonal + 1 : diagonal - 1
            let previousX = frontier[offset + previous]
            let previousY = previousX - previous
            while x > previousX && y > previousY { x -= 1; y -= 1 }
            if x == previousX { y -= 1; edits.added.insert(y) } else { x -= 1; edits.removed.insert(x) }
        }
        return edits
    }
}
