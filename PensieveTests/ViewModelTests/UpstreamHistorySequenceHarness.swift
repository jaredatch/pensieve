import XCTest
@testable import Pensieve

/// Gates control scheduling. Separate callbacks from the VM record what actually passed and what
/// outcome it applied. A frontier is notified only when a released segment changes scheduling state.
/// Detached service closures remain real work; the cache's internal queue is not scheduled here.
@MainActor
final class UpstreamHistorySequenceHarness {
    enum Lane: Equatable {
        case dormant, running, waiting(UUID), parked, done
    }
    enum Phase { case registered, entering, running, finishing, finished }
    struct Work {
        let name: String
        let kind: UpstreamHistorySequenceHooks.Work
        var phase: Phase
    }
    struct Publication: Equatable {
        let skillID: UUID?
        let visibleSkillID: UUID?
        let state: UpstreamHistoryLoadState
        let event: String
    }

    let frontier = TestWait.Signal()
    var work: [UUID: Work] = [:] { didSet { frontier.notify() } }
    var lanes: [String: Lane] = [:] { didSet { frontier.notify() } }
    var gates: [String: CheckedContinuation<Void, Never>] = [:] { didSet { frontier.notify() } }
    var acknowledgements = 0 { didSet { frontier.notify() } }
    var failure: HistorySequenceFailure? { didSet { frontier.notify() } }
    var tasks: [Task<Void, Never>] = []
    var scheduled: [String] = []
    var observed: [String] = []
    var publications: [Publication] = []
    var currentSkill: () -> UUID? = { nil }
    var workers: Set<UUID> = [] { didSet { frontier.notify() } }
    var discarded: Set<UUID> = []
    var applications: [UUID: Int] = [:]
    var dependencies: [String: String] = [:]
    var cleanupReport: (String, StaticString, UInt) -> Void = { message, file, line in
        XCTFail(message, file: file, line: line)
    }
    var timeoutThreadSample: () -> String? = { TestThreadSample.capture() }
    var cleanupFailed = false
    var scenario = "unnamed"
    var cleanupTimeout: Duration = .seconds(TestWait.hostedActionTimeoutSeconds)
    var frontierTimeout: Duration = .seconds(TestWait.timeoutSeconds)
    var frontierChecks = 0
    var frontierWaits = 0
    var gateAttempts = 0
    var draining = false
    private var counts: [String: Int] = [:]

    var hooks: UpstreamHistorySequenceHooks {
        UpstreamHistorySequenceHooks(
            started: { [unowned self] kind, id in
                counts[kind.rawValue, default: 0] += 1
                work[id] = Work(name: "\(kind.rawValue)\(counts[kind.rawValue, default: 0])", kind: kind, phase: .registered)
            },
            enter: { [unowned self] id in
                work[id]?.phase = .entering
                await gate("\(name(id)).start")
                work[id]?.phase = .running
            },
            finish: { [unowned self] id in
                work[id]?.phase = .finishing
                await gate("\(name(id)).finish")
                work[id]?.phase = .finished
            },
            waiting: { [unowned self] id in lanes[lane(id)] = .waiting(id) },
            resume: { [unowned self] id in
                let label = lane(id)
                lanes[label] = .parked
                let event = request.isEmpty ? "\(name(id)).resume" : "\(request).\(name(id)).resume"
                await gate(event)
                lanes[label] = .running
            },
            published: { [unowned self] state, id in
                publications.append(Publication(skillID: id, visibleSkillID: currentSkill(),
                                                state: state, event: observed.last ?? "initial"))
            },
            passed: { [unowned self] point, id, lane in record(point, id: id, lane: lane) },
            workerStarted: { [unowned self] id in workers.insert(id) },
            discarded: { [unowned self] id in discarded.insert(id) },
            requestFinished: { [unowned self] label in lanes[label] = .running },
            requestWaiting: { [unowned self] _ in lanes[request] = .parked },
            workEnded: { [unowned self] id in
                lanes[name(id)] = .done
                workers.remove(id)
            },
            applied: { [unowned self] id in applications[id, default: 0] += 1 }
        )
    }

    private func lane(_ id: UUID) -> String { request.isEmpty ? name(id) : request }

    private var request: String { UpstreamHistorySequenceContext.request }
    func name(_ id: UUID?) -> String { id.flatMap { work[$0]?.name } ?? "unregistered" }

    func enqueue(_ label: String, after: String? = nil, action: @escaping @MainActor () async -> Void) {
        dependencies[label] = after
        lanes[label] = .dormant
        tasks.append(Task {
            await UpstreamHistorySequenceContext.$request.withValue(label) {
                await gate("\(label).request")
                lanes[label] = .running
                await action()
                lanes[label] = .done
            }
        })
    }

    private func gate(_ event: String) async {
        gateAttempts += 1
        guard !draining else { return }
        await withCheckedContinuation { continuation in
            guard gates[event] == nil else {
                continuation.resume()
                stop("Duplicate gate: \(event)")
                return
            }
            gates[event] = continuation
        }
    }

    private func record(_ point: UpstreamHistorySequenceHooks.Point, id: UUID?, lane: String) {
        guard !draining else { return }
        let event: String
        switch point {
        case .request: event = "\(lane).request"
        case .start: event = "\(name(id)).start"
        case .finish: event = "\(name(id)).finish"
        case .resume: event = lane.isEmpty ? "\(name(id)).resume" : "\(lane).\(name(id)).resume"
        }
        observed.append(event)
        // This identity comes from the VM's continuation, never the released gate's key.
        if observed != scheduled { stop("Event order mismatch: observed \(observed)") }
        acknowledgements -= 1
    }

    func stop(_ message: String) {
        guard failure == nil else { return }
        failure = HistorySequenceFailure("\(message); schedule: \(scheduled)")
        abort()
    }

    func abort() {
        draining = true
        let pending = Array(gates.values)
        gates.removeAll()
        pending.forEach { $0.resume() }
    }

    func validateCompletedApplications() throws {
        for (id, count) in applications where count > 1 {
            throw HistorySequenceFailure("Outcome applied \(count) times: \(name(id))")
        }
    }

    func validateApplications() throws {
        for (id, item) in work {
            let expected = discarded.contains(id) ? 0 : 1
            guard applications[id, default: 0] == expected else {
                throw HistorySequenceFailure("Outcome applied \(applications[id, default: 0]) times: \(item.name); \(scheduled)")
            }
        }
    }
}

/// Records calls at the injected service boundary, independently of scheduler events.
final class HistorySequenceCalls {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ call: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
