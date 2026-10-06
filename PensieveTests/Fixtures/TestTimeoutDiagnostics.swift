import Foundation
import XCTest
@testable import Pensieve

@_cdecl("PensieveInstallTimeoutDiagnostics")
func installTimeoutDiagnostics() {
    TestTimeoutDiagnostics.install()
}

/// Bundle-load registration happens once on the main thread. Timeout paths save state and can
/// supply a thread sample taken before releasing gates. An unexpected issue publishes reports
/// to attachments and files, with output supplied by the wrapper relay or standalone host.
/// Passing/expected-failure cases discard their snapshots.
/// The deliberate History timeout tests inject a sampler double; real harnesses sample
/// at timeout, before abort. Shared waits sample during failure reporting, before caller cleanup.
final class TestTimeoutDiagnostics: NSObject, XCTestObservation {
    private static let shared = TestTimeoutDiagnostics()
    private(set) static var registrationCount = 0
    private(set) static var registeredOnMainThread = false

    static func install() {
        guard registrationCount == 0 else { return }
        registeredOnMainThread = Thread.isMainThread
        registrationCount += 1
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    private let lock = NSLock()
    private var snapshots: [String] = []
    private var samples: [String] = []
    private var publicationCount = 0
    private let environment: [String: String]
    private let fallbackDirectory: String
    private let output: (String) -> Void
    private let writeReport: (String, String) throws -> Void

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         fallbackDirectory: String = TestTemporaryDirectory.path + "PensieveTestDiagnostics",
         output: ((String) -> Void)? = nil,
         writeReport: @escaping (String, String) throws -> Void = { try FileService().writeFile(at: $0, content: $1) }) {
        self.environment = environment
        self.fallbackDirectory = fallbackDirectory
        self.output = output ?? Self.writeToStandardError
        self.writeReport = writeReport
        super.init()
    }

    static func writeToStandardError(_ message: String) {
        _ = fputs(message + "\n", stderr)
        _ = fflush(stderr)
    }

    static var publishedReportCount: Int {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.publicationCount
    }

    static func note(_ state: String, threadSample: String? = nil) {
        shared.recordSnapshot(state, threadSample: threadSample)
    }

    func recordSnapshot(_ state: String, threadSample: String? = nil) {
        lock.lock()
        if let threadSample { samples.append(threadSample) }
        snapshots.append("time=\(Date())\n\(state)")
        if snapshots.count > 16 { snapshots.removeFirst() }
        lock.unlock()
    }

    func testCaseWillStart(_ testCase: XCTestCase) { reset() }
    func testCaseDidFinish(_ testCase: XCTestCase) { reset() }

    private func reset() {
        lock.lock()
        snapshots.removeAll()
        samples.removeAll()
        lock.unlock()
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        guard issue.isFailure else { return }
        lock.lock()
        guard !snapshots.isEmpty else { lock.unlock(); return }
        let state = "test=\(testCase.name)\npid=\(ProcessInfo.processInfo.processIdentifier)\n" +
            "observerMainThread=\(Self.registeredOnMainThread); registrations=\(Self.registrationCount)\n" +
            "issue=\(issue.compactDescription)\n\n" + snapshots.joined(separator: "\n\n")
        publicationCount += 1
        let savedSamples = samples
        snapshots.removeAll()
        samples.removeAll()
        lock.unlock()

        let sample = savedSamples.isEmpty ? TestThreadSample.capture() : savedSamples.joined(separator: "\n\n")
        let identifier = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        let reports = [("\(identifier)-state.txt", state), ("\(identifier)-threads.txt", sample)]
        let directory = environment["PENSIEVE_TEST_DIAGNOSTICS_DIR"] ?? fallbackDirectory
        let files = FileService()
        var writtenReports = Set<String>()
        for (name, content) in reports {
            do {
                try files.createDirectory(at: directory)
                try writeReport(directory + "/" + name, content)
                writtenReports.insert(name)
            } catch {
                // Attachments remain available even when the upload directory cannot be written.
                output("Timeout diagnostics could not write \(name): \(error)")
            }
        }
        // Publish both files before interacting with XCTest's stdout/attachment transport.
        for (name, content) in reports {
            // The relay owns successfully written reports; failed writes fall back to stderr.
            if environment["PENSIEVE_TEST_DIAGNOSTICS_DIR"] == nil || !writtenReports.contains(name) {
                output("BEGIN TIMEOUT DIAGNOSTIC \(name)\n\(content)\nEND TIMEOUT DIAGNOSTIC \(name)")
            }
            let attachment = XCTAttachment(string: content)
            attachment.name = name
            attachment.lifetime = .deleteOnSuccess
            testCase.add(attachment)
        }
    }
}
