import SwiftData

/// Throwing reads shared by the ledger reconcilers. A failed read must end a reconcile before it
/// computes a removal from an empty fallback (PLAN-36 / 36.2).
protocol ReconcilerStateFetching {
    func deployIntents(context: ModelContext) throws -> [MachineDeployIntent]
    func skills(context: ModelContext) throws -> [Skill]
    func intentAssignments(context: ModelContext) throws -> [IntentAssignment]
    func categoryAssignments(context: ModelContext) throws -> [SkillProjectAssignment]
    func projects(context: ModelContext) throws -> [Project]
}

struct ReconcilerStateFetcher: ReconcilerStateFetching {
    func deployIntents(context: ModelContext) throws -> [MachineDeployIntent] {
        try context.fetch(FetchDescriptor<MachineDeployIntent>())
    }

    func skills(context: ModelContext) throws -> [Skill] {
        try context.fetch(FetchDescriptor<Skill>())
    }

    func intentAssignments(context: ModelContext) throws -> [IntentAssignment] {
        try context.fetch(FetchDescriptor<IntentAssignment>())
    }

    func categoryAssignments(context: ModelContext) throws -> [SkillProjectAssignment] {
        try context.fetch(FetchDescriptor<SkillProjectAssignment>())
    }

    func projects(context: ModelContext) throws -> [Project] {
        try context.fetch(FetchDescriptor<Project>())
    }
}
