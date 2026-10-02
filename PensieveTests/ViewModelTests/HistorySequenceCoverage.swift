import Foundation

struct HistorySequenceFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum HistorySequenceCoverage {
    static let expected: [String: (complete: Int, excluded: Int)] = [
        "disk-false-false-false": (123, 0),
        "disk-false-false-false.manual": (546, 0),
        "disk-false-false-false.remove": (727, 0),
        "disk-false-false-false.skillSwitch": (174, 0),
        "disk-false-true-false": (123, 0),
        "disk-false-true-false.manual": (229, 0),
        "disk-false-true-false.remove": (329, 0),
        "disk-false-true-false.skillSwitch": (174, 0),
        "disk-true-false-false": (569, 0),
        "disk-true-false-false.manual": (1592, 0),
        "disk-true-false-false.remove": (1453, 0),
        "disk-true-false-false.skillSwitch": (716, 0),
        "empty-false-false-false": (464, 0),
        "empty-false-false-false.manual": (1425, 0),
        "empty-false-false-false.remove": (1090, 0),
        "empty-false-false-false.skillSwitch": (686, 0),
        "empty-false-true-false": (154, 0),
        "empty-false-true-false.manual": (431, 0),
        "empty-false-true-false.remove": (329, 0),
        "empty-false-true-false.skillSwitch": (220, 0),
        "memory-false-false-false": (4, 0),
        "memory-false-false-false.manual": (165, 0),
        "memory-false-false-false.remove": (364, 0),
        "memory-false-false-false.skillSwitch": (10, 0),
        "memory-false-false-true": (7, 0),
        "memory-false-false-true.manual": (192, 0),
        "memory-false-false-true.remove": (727, 0),
        "memory-false-false-true.skillSwitch": (19, 0),
        "memory-false-true-false": (4, 0),
        "memory-false-true-false.manual": (56, 0),
        "memory-false-true-false.remove": (165, 0),
        "memory-false-true-false.skillSwitch": (10, 0),
        "memory-false-true-true": (7, 0),
        "memory-false-true-true.manual": (74, 0),
        "memory-false-true-true.remove": (329, 0),
        "memory-false-true-true.skillSwitch": (19, 0),
        "memory-true-false-false": (10, 0),
        "memory-true-false-false.manual": (1211, 0),
        "memory-true-false-false.remove": (1090, 0),
        "memory-true-false-false.skillSwitch": (37, 0),
        "memory-true-false-true": (13, 0),
        "memory-true-false-true.manual": (1238, 0),
        "memory-true-false-true.remove": (1453, 0),
        "memory-true-false-true.skillSwitch": (46, 0)
    ]

    static func validateAll(_ results: [String: (complete: Int, excluded: Int)], report: (String) -> Void) throws {
        var failures: [String] = []
        for name in Set(expected.keys).union(results.keys).sorted() {
            guard let count = results[name] else {
                let missing = "Missing scenario: \(name)"
                report(missing)
                failures.append(missing)
                continue
            }
            report("HISTORY_SEQUENCE_ORDERS \(name) passed=\(count.complete) excludedPrefixes=\(count.excluded)")
            do { try validate(name, complete: count.complete, excluded: count.excluded) } catch {
                failures.append(String(describing: error))
            }
        }
        if !failures.isEmpty { throw HistorySequenceFailure(failures.joined(separator: "\n")) }
    }

    static func validate(_ scenario: String, complete: Int, excluded: Int) throws {
        guard let counts = expected[scenario], counts.complete == complete, counts.excluded == excluded else {
            throw HistorySequenceFailure("Coverage changed: \(scenario), complete=\(complete), excluded=\(excluded)")
        }
    }
}
