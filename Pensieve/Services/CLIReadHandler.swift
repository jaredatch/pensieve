import Foundation
import SwiftData

protocol CLIReadHandling {
    @MainActor func handle(_ request: CLIRequest, context: ModelContext) -> CLIReply
}

struct CLIReadHandler: CLIReadHandling {
    let store: SkillStoreProtocol
    let installedAgents: () -> [PlatformTarget]
    let machines: MachineStateServicing
    let storeRoot: String

    @MainActor
    func handle(_ request: CLIRequest, context: ModelContext) -> CLIReply {
        do {
            switch request.command {
            case "skill list":
                return .success(.array(try skills(in: context).map { skillValue($0) }))
            case "skill show":
                guard request.arguments.count == 1, let slug = request.arguments.first else {
                    return .failure("usage", "skill show needs one slug", hint: "Run pensieve skill show --help.", exit: 64)
                }
                guard let skill = try skills(in: context).first(where: { $0.directoryName == slug }) else {
                    return .failure("skill_not_found", "No skill named \(slug)", hint: "Run pensieve skill list.", exit: 4)
                }
                var value = skillFields(skill)
                if request.content { value["content"] = .string(try store.readBody(directoryName: slug)) }
                return .success(.object(value))
            case "agent list":
                return .success(.array(PlatformTarget.allCases.map {
                    .object(["id": .string($0.cliID), "name": .string($0.displayName),
                             "installed": .bool(installedAgents().contains($0)),
                             "projectScope": .bool($0.supportsProjectScope)])
                }))
            case "machine list":
                return .success(.array(machines.readAll(fromRoot: storeRoot).map {
                    .object(["id": .string($0.machineID), "name": .string($0.name),
                             "agents": .array($0.agents.map { .string(PlatformTarget.cliID(for: $0)) })])
                }))
            case "project list":
                let projects = try context.fetch(FetchDescriptor<Project>()).sorted { ($0.name, $0.path) < ($1.name, $1.path) }
                return .success(.array(projects.map {
                    .object(["id": .string($0.id.uuidString), "name": .string($0.name), "path": .string($0.path),
                             "identityKey": $0.identityKey.map(CLIValue.string) ?? .null])
                }))
            default:
                return .failure("usage", "Unknown command: \(request.command)", hint: "Run pensieve commands.", exit: 64)
            }
        } catch {
            return .failure("store_unreadable", error.localizedDescription, hint: "Open Pensieve to check the library.", exit: 2)
        }
    }

    @MainActor private func skills(in context: ModelContext) throws -> [Skill] {
        try context.fetch(FetchDescriptor<Skill>()).sorted { $0.directoryName < $1.directoryName }
    }

    @MainActor private func skillValue(_ skill: Skill) -> CLIValue { .object(skillFields(skill)) }

    @MainActor private func skillFields(_ skill: Skill) -> [String: CLIValue] {
        ["slug": .string(skill.directoryName), "name": .string(skill.name),
         "description": .string(skill.skillDescription), "tags": .array(skill.tags.map(CLIValue.string))]
    }
}
