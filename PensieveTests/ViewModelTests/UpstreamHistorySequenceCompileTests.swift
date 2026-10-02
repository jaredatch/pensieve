import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistorySequenceCompileTests: UpstreamHistoryCacheTestCase {
    func testDetachedWorkRejectsMainActorCapture() throws {
        let fixture = try sequenceFixture(.empty)
        // Infer Operation from the real method, without converting it to a function type that
        // supplies @Sendable itself. Metatype identity includes the closure's Sendable contract.
        XCTAssertTrue(operationType(of: fixture.model.sequenceTask) == (@Sendable () -> Bool).self)
        XCTAssertFalse(operationType(of: plainTask) == (@Sendable () -> Bool).self,
                       "The probe must distinguish a plain closure from a Sendable closure")
    }

    private func operationType<Operation>(
        of factory: (UpstreamHistorySequenceHooks.Work, UUID, TaskPriority, Operation) -> Task<Bool, Never>
    ) -> Any.Type {
        Operation.self
    }

    private func plainTask(
        _ work: UpstreamHistorySequenceHooks.Work, id: UUID, priority: TaskPriority, operation: @escaping () -> Bool
    ) -> Task<Bool, Never> {
        Task { operation() }
    }
}
