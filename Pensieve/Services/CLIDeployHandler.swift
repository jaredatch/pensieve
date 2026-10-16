import Foundation
import SwiftData

@MainActor
struct CLIDeployHandler {
    let service: DeployMutationServicing
    let files: FileServiceProtocol

    func handle(_ request: CLIRequest, context: ModelContext) async -> CLIReply {
        do {
            guard let options = request.deployment, !request.arguments.isEmpty, !options.agents.isEmpty,
                  options.global != (options.project != nil), options.machines.isEmpty || options.global else {
                return .failure("usage", "Name skills, agents and a scope (-g or -p). -m requires -g.",
                    hint: "Run pensieve \(request.command) --help.", exit: 64)
            }
            let lookup = CLINameResolver(context: context, files: files)
            let project: Project?
            if let name = options.project {
                project = try await lookup.project(name, cwd: options.workingDirectory)
            } else { project = nil }
            let skills = try Array(Set(request.arguments)).sorted().map(lookup.skill)
            let pairs = try resolvePairs(skills: skills, options: options, project: project, lookup: lookup,
                context: context, selected: request.command == "deploy")
            let report = try service.change(request.command == "deploy", pairs: pairs.pairs,
                dryRun: options.dryRun, context: context)
            return reply(report, selected: request.command == "deploy", dryRun: options.dryRun, skipped: pairs.skipped)
        } catch let refusal as CLICommandRefusal { return refusal.reply } catch let error as DeployIntentPersistenceError {
            return CLIReply(envelope: CLIEnvelope(ok: false, changed: true,
                data: .object(["manifestMayHaveChanged": .bool(true), "swiftDataSaved": .bool(false)]),
                error: CLIError(code: "partial", message: error.localizedDescription,
                    hint: "Open Pensieve to check the saved manifest before retrying.", retryable: false)), exitCode: 1)
        } catch DeployIntentModelError.syncInProgress {
            return .failure("sync_running", "Sync is running. Try again when it finishes.",
                hint: "Wait for sync to finish, then retry.", exit: 1, retryable: true)
        } catch {
            return .failure("deploy_failed", error.localizedDescription, hint: "Open Pensieve to check the deployment.", exit: 1)
        }
    }

    private func resolvePairs(skills: [Skill], options: CLIDeployOptions, project: Project?,
                              lookup: CLINameResolver, context: ModelContext, selected: Bool) throws
        -> (pairs: [DeployMutationPair], skipped: [CLIValue]) {
        let isDirect = project.map { $0.identityKey.map(ManifestService.isAdmittedProjectKey) != true } ?? false
        let localID = isDirect ? (try? service.dependencies.identity.identifier()) ?? ""
            : try service.dependencies.identity.identifier()
        let catalog = try service.targetCatalog(context: context, localID: localID)
        let machines = catalog.machines, states = catalog.states
        let targets = options.machines.isEmpty ? machines.filter(\.isLocal)
            : try options.machines.map { try lookup.machine($0, catalog: catalog) }
        let explicit = try options.agents.filter { $0 != "*" }.map(lookup.agent)
        var pairs: [DeployMutationPair] = [], skipped: [CLIValue] = []
        var seen: Set<String> = []
        for machine in targets {
            let installed = machine.isLocal ? service.platformVM.installedPlatforms()
                : states.first(where: { $0.machineID == machine.id })?.agents.compactMap(PlatformTarget.init(rawValue:)) ?? []
            for agent in explicit where selected && !installed.contains(agent) {
                throw CLICommandRefusal(reply: .failure("agent_not_installed",
                    "\(agent.cliID) is not installed on \(machine.name) (\(machine.id)).",
                    hint: "Check pensieve agent list and pensieve machine list.", exit: 1))
            }
            let heldIntents = isDirect ? [] : catalog.intents.filter { row in
                row.machineID == machine.id && row.projectKey == project?.identityKey
                    && skills.contains(where: { $0.directoryName == row.skillSlug })
            }
            let heldAgents = selected ? [] : heldIntents.compactMap { PlatformTarget(rawValue: $0.platformRaw) }
            let agents = Set(explicit + (options.agents.contains("*") ? installed + heldAgents : []))
            for agent in PlatformTarget.allCases where agents.contains(agent) {
                if project != nil && !agent.supportsProjectScope {
                    if explicit.contains(agent) {
                        throw CLICommandRefusal(reply: .failure("project_scope_unsupported",
                            "\(agent.cliID) does not support projects.",
                            hint: "Use -g for this agent.", exit: 1))
                    }
                    skipped.append(.object(["agent": .string(agent.cliID), "reason": .string("project_scope_unsupported")]))
                    continue
                }
                for skill in skills {
                    guard explicit.contains(agent) || installed.contains(agent) || heldIntents.contains(where: {
                        $0.skillSlug == skill.directoryName && $0.platformRaw == agent.rawValue
                    }) else { continue }
                    let key = machine.id + "|" + skill.directoryName + "|" + agent.rawValue
                    guard seen.insert(key).inserted else { continue }
                    pairs.append(DeployMutationPair(skill: skill, platform: agent, machineID: machine.id,
                        target: project.map(DeployTarget.project) ?? .userWide, isLocal: machine.isLocal))
                }
            }
        }
        return (pairs, skipped)
    }

    private func reply(_ report: DeployMutationReport, selected: Bool, dryRun: Bool, skipped: [CLIValue]) -> CLIReply {
        let changes = report.changes.map { change -> CLIValue in
            let pair = change.pair
            return .object(["skill": .string(pair.skill.directoryName), "agent": .string(pair.platform.cliID),
                "machine": pair.machineID.isEmpty ? .null : .string(pair.machineID),
                "project": pair.target.project.map { .string($0.path) } ?? .null,
                "action": .string(selected ? "deploy" : "undeploy"), "intent": .bool(change.intentChanges),
                "artifact": .bool(change.artifactChanges), "warning": change.warning.map(CLIValue.string) ?? .null,
                "localOnly": .bool(!pair.hasIntent),
                "delivery": .string(!pair.hasIntent ? "This change stays on this Mac and won't reach other Macs."
                    : pair.isLocal ? "This Mac" : "Applies on that Mac's next sync after this Mac pushes.")])
        }
        let results = report.results.outcomes.map { result -> CLIValue in
            .object(["skillID": .string(result.skillID.uuidString), "agent": .string(result.platform.cliID),
                     "applied": .bool(result.isSuccess), "artifactWritten": .bool(result.artifactApplied),
                     "error": result.error.map(CLIValue.string) ?? .null])
        }
        let failures = report.results.readFailures.map(\.message) + report.results.operationFailures
            + report.results.failures.compactMap(\.error)
        let data = CLIValue.object(["dryRun": .bool(dryRun), "changes": .array(changes), "skipped": .array(skipped),
            "intentSaved": .bool(report.intentSaved), "results": .array(results),
            "failures": .array(failures.map(CLIValue.string))])
        let remote = report.changes.contains { !$0.pair.isLocal }
        let error = failures.isEmpty ? nil : CLIError(
            code: report.intentSaved || report.applied ? "partial" : "deploy_failed",
            message: failures.joined(separator: "\n"),
            hint: "Open Pensieve to check the remaining deployment work.", retryable: false)
        return CLIReply(envelope: CLIEnvelope(ok: error == nil, changed: report.applied, data: data,
            next: remote && !dryRun ? ["pensieve sync"] : nil, error: error), exitCode: error == nil ? 0 : 1)
    }
}
