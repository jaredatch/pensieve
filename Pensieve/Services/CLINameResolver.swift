import Foundation
import SwiftData

struct CLICommandRefusal: Error {
    let reply: CLIReply
}

@MainActor
struct CLINameResolver {
    let context: ModelContext
    let files: FileServiceProtocol

    func skill(_ slug: String) throws -> Skill {
        try checkLength(slug, limit: 64)
        let skills = try context.fetch(FetchDescriptor<Skill>())
        guard let skill = skills.first(where: { $0.directoryName == slug }) else {
            throw missing("skill", slug, choices: skills.map(\.directoryName), hint: "Run pensieve skill list.")
        }
        return skill
    }

    func agent(_ name: String) throws -> PlatformTarget {
        try checkLength(name, limit: PublishedStringSanitizer.nameLimit)
        let aliases: [String: PlatformTarget] = ["claude-code": .claudeCode, "grok-cli": .grok,
            "xai": .grok, "hermes-agent": .hermes]
        if let agent = aliases[name.lowercased()] ?? PlatformTarget.allCases.first(where: { $0.cliID == name.lowercased() }) {
            return agent
        }
        throw missing("agent", name, choices: PlatformTarget.allCases.map(\.cliID), hint: "Run pensieve agent list.")
    }

    func project(_ name: String, cwd: String) async throws -> Project {
        let pathLike = name == "." || PathSyntax.hasSeparator(name)
        if !pathLike { try checkLength(name, limit: PublishedStringSanitizer.nameLimit) }
        let projects = try context.fetch(FetchDescriptor<Project>())
        let snapshots = projects.map { (id: $0.id, name: $0.name, path: $0.path) }
        let files = files
        let (path, ids) = await BlockingWork.run {
            let path = files.realPath(at: URL(fileURLWithPath: name, relativeTo: URL(fileURLWithPath: cwd)).path)
            let ids = snapshots.filter {
                (!pathLike && $0.name.caseInsensitiveCompare(name) == .orderedSame) || files.realPath(at: $0.path) == path
            }.map { $0.id }
            return (path, Set(ids))
        }
        let matches = try context.fetch(FetchDescriptor<Project>()).filter { ids.contains($0.id) }
        guard matches.allSatisfy({ project in
            snapshots.contains { $0.id == project.id && $0.name == project.name && $0.path == project.path }
        }) else {
            throw CLICommandRefusal(reply: .failure("project_changed", "The project changed during lookup.",
                hint: "Run the command again with its current name or path.", exit: 3, retryable: true))
        }
        guard matches.count <= 1 else {
            throw ambiguous("project", name, candidates: matches.map {
                $0.name + " — " + $0.path + " (" + $0.id.uuidString + ")"
            })
        }
        guard let project = matches.first else {
            if pathLike {
                throw CLICommandRefusal(reply: .failure("project_not_registered", "No registered project at \(path).",
                    hint: "Run pensieve project add \(name).", exit: 4))
            }
            throw missing("project", name, choices: projects.map(\.name),
                hint: "Run pensieve project list or pensieve project add <path>.")
        }
        return project
    }

    func machine(_ name: String, catalog: DeployTargetCatalog) throws -> DeployIntentMachine {
        // A listed collision name may include a space, parentheses and its 36-character UUID.
        try checkLength(name, limit: PublishedStringSanitizer.nameLimit + 39)
        let machines = catalog.machines
        let aliases = catalog.publishedNamesByID
        let byID = machines.filter { $0.id.caseInsensitiveCompare(name) == .orderedSame }
        let byName = machines.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let byAlias = machines.filter {
            aliases[$0.id]?.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) == true }
        let matches = !byID.isEmpty ? byID : (!byName.isEmpty ? byName : byAlias)
        guard matches.count <= 1 else {
            throw ambiguous("machine", name, candidates: matches.map { $0.name + " — " + $0.id })
        }
        guard let match = matches.first else {
            throw missing("machine", name, choices: machines.map(\.name), hint: "Run pensieve machine list.")
        }
        return match
    }

    private func ambiguous(_ kind: String, _ name: String, candidates: [String]) -> CLICommandRefusal {
        var reply = CLIReply.failure("ambiguous",
            "More than one \(kind) matches \(name): " + candidates.sorted().joined(separator: "; "),
            hint: "Use a project path or a machine ID from pensieve \(kind) list.", exit: 5)
        var envelope = reply.envelope
        envelope.data = .object(["candidates": .array(candidates.sorted().map(CLIValue.string))])
        reply = CLIReply(envelope: envelope, exitCode: reply.exitCode)
        return CLICommandRefusal(reply: reply)
    }

    private func missing(_ kind: String, _ name: String, choices: [String], hint: String) -> CLICommandRefusal {
        let query = name.lowercased()
        let scored: [(name: String, distance: Int)] = choices.map { ($0, Self.distance(query, $0.lowercased())) }
        let closest = scored.sorted {
            $0.distance == $1.distance ? $0.name < $1.name : $0.distance < $1.distance
        }.prefix(3).map { $0.name }
        let advice = closest.isEmpty ? hint : "Closest names: " + closest.joined(separator: ", ") + ". " + hint
        return CLICommandRefusal(reply: .failure(kind + "_not_found", "No \(kind) named \(name).", hint: advice, exit: 4))
    }

    private func checkLength(_ name: String, limit: Int) throws {
        guard name.unicodeScalars.count <= PublishedStringSanitizer.nameScalarLimit, name.count <= limit else {
            throw CLICommandRefusal(reply: .failure("usage", "The name exceeds the \(limit)-character limit.",
                hint: "Use a slug or name from pensieve skill, agent, project or machine list.", exit: 64))
        }
    }

    private static func distance(_ left: String, _ right: String) -> Int {
        let right = Array(right)
        var previous = Array(0...right.count)
        for (index, letter) in left.enumerated() {
            var row = [index + 1]
            for (column, other) in right.enumerated() {
                row.append(min(row[column] + 1, previous[column + 1] + 1, previous[column] + (letter == other ? 0 : 1)))
            }
            previous = row
        }
        return previous.last ?? 0
    }
}
