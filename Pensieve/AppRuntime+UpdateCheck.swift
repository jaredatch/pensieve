import Foundation
import SwiftData

extension AppRuntime {
    func executeUpdateCheck(_ operation: @escaping UpdateCheckOperation,
                            container: ModelContainer,
                            classifyFailure: @escaping (Error) -> ClassifiedUpdateFailure,
                            apply: (([UUID: SkillUpdateCheckResult]) throws -> Void)? = nil) async -> UpdateCheckCompletion {
        let result = await BlockingWork.task(priority: .utility) {
            Result { try operation(container) }
        }.value
        switch result {
        case let .success(result):
            do {
                try (apply ?? applyUpdateCheckResults)(result.skills)
                return UpdateCheckCompletion(report: result.report,
                    errors: [result.report.environmentError].compactMap { $0 })
            } catch {
                return UpdateCheckCompletion(report: result.report,
                    errors: [result.report.environmentError, error].compactMap { $0 })
            }
        case let .failure(error):
            if let failure = error as? UpdateCheckExecutionFailure {
                return UpdateCheckCompletion(report: failure.report,
                    errors: [failure.report.environmentError, failure.underlying].compactMap { $0 })
            }
            let classified = await BlockingWork.task(priority: .utility) { classifyFailure(error) }.value
            let report = UpdateCheckReport(
                environmentError: classified.environment ? classified.error : nil, gitUsability: classified.usability)
            return UpdateCheckCompletion(report: report, errors: [classified.error])
        }
    }

    func applyUpdateCheckResults(_ results: [UUID: SkillUpdateCheckResult]) throws {
        let skills = try container.mainContext.fetch(FetchDescriptor<Skill>())
        for skill in skills {
            if let result = results[skill.id] {
                provenanceVM.recordCheckResult(result, on: skill)
            }
        }
    }
}
