import Foundation

/// The PLAN-39 table's finite two-request cases. Decisions before the intervening event own
/// old work; removal and a hidden check during a first read retire its unclaimed outcome.
/// Expectations use request/completion order and fixture inputs, never the observed call counts.
@MainActor
struct HistorySequenceExpectations {
    let reads: Int
    let probes: Int
    let persists: Int
    let readPublications: [String: Int]

    init(_ scenario: UpstreamHistorySequenceEnumerationTests.Scenario, events: [String]) {
        func before(_ event: String, _ boundary: String) -> Bool {
            guard let first = events.firstIndex(of: event), let last = events.firstIndex(of: boundary) else { return false }
            return first < last
        }
        let probeDecision: String
        switch scenario.seed {
        case .empty: probeDecision = "no-probe"
        case .disk: probeDecision = "disk1.resume"
        case .memory: probeDecision = scenario.changed ? "localEdits1.resume" : "A.request"
        }
        let movedProbe = scenario.moved && !scenario.fails
        let initialRead = scenario.seed == .empty || movedProbe
        var retiredRead = false
        switch scenario.intervening {
        case .none, .skillSwitch:
            reads = initialRead ? 1 : 0
            probes = scenario.seed == .empty ? 0 : 1
        case .manual:
            probes = before(probeDecision, "event.request") ? 1 : 0
            if scenario.seed == .empty {
                // A's disk miss starts a first read. A later check retires that read or asks
                // again after its outcome; either case gives B one replacement read.
                let earlierRead = before("disk1.resume", "event.request")
                reads = earlierRead ? 2 : 1
                retiredRead = earlierRead && !before("read1.resume", "event.request")
            } else {
                // Only a full read started after the ask spends it. A moved probe
                // already applied before the ask owns an older refresh, joined or finished.
                let earlierRead = probes == 1 && movedProbe && before("probe1.resume", "event.request")
                reads = earlierRead ? 2 : 1
            }
        case .remove:
            probes = before(probeDecision, "event.request") ? 1 : 0
            let earlierRead = scenario.seed == .empty ? before("disk1.resume", "event.request")
                : movedProbe && before("probe1.resume", "event.request")
            reads = earlierRead ? 2 : 1 // B always starts cold after removal.
            retiredRead = earlierRead && !before("read1.resume", "event.request")
        }
        persists = scenario.fails ? 0 : reads - (retiredRead ? 1 : 0)
        var publications: [String: Int] = [:]
        for number in 0..<reads {
            let event = "read\(number + 1).resume"
            let away = scenario.intervening == .skillSwitch
                && before("event.request", event) && before(event, "B.request")
            publications[event] = (number == 0 && retiredRead) || away ? 0 : 1
        }
        readPublications = publications
    }
}
