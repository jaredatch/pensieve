import Foundation
import SwiftData

struct MachineStateProject: Equatable {
    let identityKey: String
    let kind: String
    let name: String
    let path: String?

    init(identityKey: String, kind: String, name: String, path: String? = nil) {
        self.identityKey = identityKey
        self.kind = kind
        self.name = name
        self.path = path
    }
}

struct MachineStateUserDeploy: Equatable {
    let slug: String
    let platform: String
}

struct MachineStateProjectDeploy: Equatable {
    let slug: String
    let platform: String
    let projectKey: String
}

struct MachineState: Equatable {
    let schemaVersion: Int
    let machineID: String
    let name: String
    let appVersion: String
    let publishedAt: Date
    let agents: [String]
    let projects: [MachineStateProject]
    let userDeploys: [MachineStateUserDeploy]
    let projectDeploys: [MachineStateProjectDeploy]
}

extension MachineState {
    /// Content equality over the parsed known fields, ignoring `publishedAt` only. Implemented by
    /// rebuilding `self` with the other's timestamp and leaning on synthesized Equatable. Adding a
    /// stored field to MachineState breaks this initializer call at compile time UNLESS the new
    /// field ships a memberwise default — the field-count pin in
    /// MachineStateServiceTests.testContentEqualsIgnoresOnlyPublishedAt catches that case; update
    /// both this initializer call and that test when the struct grows.
    func contentEquals(_ other: MachineState) -> Bool {
        MachineState(schemaVersion: schemaVersion, machineID: machineID, name: name,
                     appVersion: appVersion, publishedAt: other.publishedAt, agents: agents,
                     projects: projects, userDeploys: userDeploys,
                     projectDeploys: projectDeploys) == other
    }
}

enum MachineStateError: LocalizedError {
    case invalidMachineID(String)
    case unsafeMachinesDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .invalidMachineID(value):
            "Invalid machine ID: \(value)"
        case let .unsafeMachinesDirectory(path):
            "Unsafe machines directory: \(path)"
        }
    }
}

protocol MachineStateServicing {
    func compose(machineID: String, context: ModelContext, publishedAt: Date) throws -> MachineState
    func write(_ state: MachineState, toRoot root: String) throws
    func readAll(fromRoot root: String) -> [MachineState]
}

struct MachineStateService: MachineStateServicing {
    static let currentSchemaVersion = 1

    private let fileService: FileServiceProtocol
    private let agentDetection: AgentDetectionServiceProtocol
    private let defaults: UserDefaults
    private let deployState: () throws -> DeployState
    private let homeDirectory: String
    private let hostName: () -> String?
    private let appVersion: () -> String
    private let warn: (String) -> Void

    init(
        fileService: FileServiceProtocol = FileService(),
        agentDetection: AgentDetectionServiceProtocol,
        defaults: UserDefaults = .standard,
        deployState: @escaping () throws -> DeployState,
        homeDirectory: String,
        hostName: @escaping () -> String? = MachineDisplayName.currentHostName,
        appVersion: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        },
        warn: @escaping (String) -> Void = { NSLog("Pensieve machine state: \($0)") }
    ) {
        self.fileService = fileService
        self.agentDetection = agentDetection
        self.defaults = defaults
        self.deployState = deployState
        self.homeDirectory = homeDirectory
        self.hostName = hostName
        self.appVersion = appVersion
        self.warn = warn
    }

    func compose(machineID: String, context: ModelContext, publishedAt: Date) throws -> MachineState {
        guard Self.isCanonicalUUID(machineID) else {
            throw MachineStateError.invalidMachineID(machineID)
        }
        let projects = try context.fetch(FetchDescriptor<Project>())
        let projectedProjects = Self.projectRecords(projects, homeDirectory: homeDirectory)
        let knownProjectKeys = Set(projectedProjects.map(\.identityKey))
        let projections = Self.deployRecords(try deployState().records, knownProjectKeys: knownProjectKeys)
        let storedName = defaults.string(forKey: MachineDisplayName.defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MachineState(
            schemaVersion: Self.currentSchemaVersion,
            machineID: machineID,
            name: storedName.flatMap { $0.isEmpty ? nil : $0 }
                ?? MachineDisplayName.publishedFallback(hostName: hostName()),
            appVersion: appVersion(),
            publishedAt: publishedAt,
            agents: agentDetection.installedPlatforms().map(\.rawValue).sorted(),
            projects: projectedProjects,
            userDeploys: projections.user,
            projectDeploys: projections.project
        )
    }

    func write(_ state: MachineState, toRoot root: String) throws {
        guard Self.isCanonicalUUID(state.machineID) else {
            throw MachineStateError.invalidMachineID(state.machineID)
        }
        let directory = root + "/machines"
        guard !fileService.isSymlink(at: directory) else {
            throw MachineStateError.unsafeMachinesDirectory(directory)
        }
        try fileService.createDirectory(at: directory)
        let destination = directory + "/" + state.machineID + ".yaml"
        let parent = (root as NSString).deletingLastPathComponent
        let base = (root as NSString).lastPathComponent
        let temporary = parent + "/" + base + ".machine-state-" + UUID().uuidString + ".tmp"
        do {
            try fileService.writeFile(at: temporary, content: Self.serialize(state))
            try fileService.replaceItem(at: destination, with: temporary)
        } catch {
            try? fileService.deleteFile(at: temporary)
            throw error
        }
    }

    func readAll(fromRoot root: String) -> [MachineState] {
        let directory = root + "/machines"
        guard !fileService.isSymlink(at: directory), fileService.directoryExists(at: directory) else {
            if fileService.isSymlink(at: directory) { warn("skipped symlinked machines directory") }
            return []
        }
        guard let entries = try? fileService.listDirectory(at: directory) else {
            warn("skipped unreadable machines directory")
            return []
        }
        var seen: Set<String> = []
        var states: [MachineState] = []
        for entry in entries.sorted() {
            guard let machineID = admittedFilename(entry) else { continue }
            guard seen.insert(machineID).inserted else {
                warn("skipped duplicate machine state \(entry)")
                continue
            }
            guard let state = readState(at: directory + "/" + entry, machineID: machineID) else { continue }
            states.append(state)
        }
        return states.sorted { $0.machineID < $1.machineID }
    }
}

private extension MachineStateService {
    static func deployRecords(
        _ deploys: [DeployStateRecord], knownProjectKeys: Set<String>
    ) -> (user: [MachineStateUserDeploy], project: [MachineStateProjectDeploy]) {
        var user: Set<UserDeployKey> = []
        var project: Set<ProjectDeployKey> = []
        for deploy in deploys {
            if deploy.scope == "project", let key = deploy.projectIdentityKey, knownProjectKeys.contains(key) {
                project.insert(ProjectDeployKey(slug: deploy.slug, platform: deploy.platform, projectKey: key))
            } else if deploy.scope == "user", deploy.projectIdentityKey == nil {
                user.insert(UserDeployKey(slug: deploy.slug, platform: deploy.platform))
            }
        }
        return (
            user.sorted().map { MachineStateUserDeploy(slug: $0.slug, platform: $0.platform) },
            project.sorted().map {
                MachineStateProjectDeploy(slug: $0.slug, platform: $0.platform, projectKey: $0.projectKey)
            }
        )
    }

    struct UserDeployKey: Hashable, Comparable {
        let slug: String
        let platform: String
        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.slug, lhs.platform) < (rhs.slug, rhs.platform) }
    }

    struct ProjectDeployKey: Hashable, Comparable {
        let slug: String
        let platform: String
        let projectKey: String
        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.projectKey, lhs.slug, lhs.platform) < (rhs.projectKey, rhs.slug, rhs.platform)
        }
    }

    func admittedFilename(_ entry: String) -> String? {
        guard entry == (entry as NSString).lastPathComponent,
              !entry.contains("/"), !entry.contains("\\"), entry.hasSuffix(".yaml") else {
            warn("skipped traversal-shaped machine state filename \(entry)")
            return nil
        }
        let stem = String(entry.dropLast(5))
        guard let uuid = UUID(uuidString: stem) else {
            warn("skipped non-UUID machine state filename \(entry)")
            return nil
        }
        let canonical = uuid.uuidString
        guard stem == canonical else {
            warn("skipped non-canonical machine state filename \(entry)")
            return nil
        }
        return canonical
    }

    func readState(at path: String, machineID: String) -> MachineState? {
        guard fileService.isRegularFile(at: path),
              let content = try? fileService.readFile(at: path),
              let object = (try? CheckedYAMLLoader.load(yaml: content)) as? [String: Any],
              let state = Self.parse(object),
              (1...Self.currentSchemaVersion).contains(state.schemaVersion),
              state.machineID == machineID else {
            warn("skipped unreadable or unsupported machine state \((path as NSString).lastPathComponent)")
            return nil
        }
        return state
    }

    static func parse(_ object: [String: Any]) -> MachineState? {
        guard let schema = object["schema_version"] as? Int,
              let machineID = object["machine_id"] as? String, isCanonicalUUID(machineID),
              let name = object["name"] as? String,
              let appVersion = object["app_version"] as? String,
              let publishedAt = parseDate(object["published_at"]),
              let agents = stringList(object["agents"]),
              let projects = parseProjects(object["projects"]),
              let userDeploys = parseUserDeploys(object["user_deploys"]),
              let projectDeploys = parseProjectDeploys(object["project_deploys"]) else { return nil }
        return MachineState(schemaVersion: schema, machineID: machineID, name: name,
                            appVersion: appVersion, publishedAt: publishedAt, agents: agents,
                            projects: projects, userDeploys: userDeploys, projectDeploys: projectDeploys)
    }

    static func parseProjects(_ value: Any?) -> [MachineStateProject]? {
        parseMaps(value) { map in
            guard let key = map["identity_key"] as? String, let kind = map["kind"] as? String,
                  let name = map["name"] as? String else { return nil }
            return MachineStateProject(
                identityKey: key,
                kind: kind,
                name: name,
                path: admittedPublishedPath(map["path"])
            )
        }
    }

    static func parseUserDeploys(_ value: Any?) -> [MachineStateUserDeploy]? {
        parseMaps(value) { map in
            guard let slug = map["slug"] as? String, let platform = map["platform"] as? String else { return nil }
            return MachineStateUserDeploy(slug: slug, platform: platform)
        }
    }

    static func parseProjectDeploys(_ value: Any?) -> [MachineStateProjectDeploy]? {
        parseMaps(value) { map in
            guard let slug = map["slug"] as? String, let platform = map["platform"] as? String,
                  let key = map["project_key"] as? String else { return nil }
            return MachineStateProjectDeploy(slug: slug, platform: platform, projectKey: key)
        }
    }

    static func parseMaps<T>(_ value: Any?, transform: ([String: Any]) -> T?) -> [T]? {
        guard let values = value as? [Any] else { return nil }
        let parsed = values.compactMap { ($0 as? [String: Any]).flatMap(transform) }
        return parsed.count == values.count ? parsed : nil
    }

    static func stringList(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        let strings = values.compactMap { $0 as? String }
        return strings.count == values.count ? strings : nil
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let string = value as? String else { return nil }
        return iso8601.date(from: string)
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString == value
    }

    static func serialize(_ state: MachineState) -> String {
        var lines = [
            "schema_version: \(state.schemaVersion)",
            "machine_id: \(quoted(state.machineID))",
            "name: \(quoted(state.name))",
            "app_version: \(quoted(state.appVersion))",
            "published_at: \(iso8601.string(from: state.publishedAt))",
            "agents: [" + state.agents.map(quoted).joined(separator: ", ") + "]",
            "projects:"
        ]
        appendProjects(state.projects, to: &lines)
        lines.append("user_deploys:")
        appendUserDeploys(state.userDeploys, to: &lines)
        lines.append("project_deploys:")
        appendProjectDeploys(state.projectDeploys, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    static func appendProjects(_ values: [MachineStateProject], to lines: inout [String]) {
        if values.isEmpty { lines[lines.count - 1] += " []"; return }
        for value in values {
            var fields = "identity_key: \(quoted(value.identityKey)), kind: \(quoted(value.kind)), "
                + "name: \(quoted(value.name))"
            if let path = value.path { fields += ", path: \(quoted(path))" }
            lines.append("  - {\(fields)}")
        }
    }

    static func appendUserDeploys(_ values: [MachineStateUserDeploy], to lines: inout [String]) {
        if values.isEmpty { lines[lines.count - 1] += " []"; return }
        for value in values {
            lines.append("  - {slug: \(quoted(value.slug)), platform: \(quoted(value.platform))}")
        }
    }

    static func appendProjectDeploys(_ values: [MachineStateProjectDeploy], to lines: inout [String]) {
        if values.isEmpty { lines[lines.count - 1] += " []"; return }
        for value in values {
            lines.append("  - {slug: \(quoted(value.slug)), platform: \(quoted(value.platform)), "
                + "project_key: \(quoted(value.projectKey))}")
        }
    }

    static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        var result = ""
        for scalar in encoded.unicodeScalars {
            if requiresAdditionalYAMLEscape(scalar) {
                let format = scalar.value <= 0xFFFF ? "\\u%04X" : "\\U%08X"
                result += String(format: format, scalar.value)
            } else {
                result.append(Character(scalar))
            }
        }
        return result
    }

    static func requiresAdditionalYAMLEscape(_ scalar: Unicode.Scalar) -> Bool {
        (0x7F...0x9F).contains(scalar.value)
            || scalar.value == 0x2028
            || scalar.value == 0x2029
            || CharacterSet.illegalCharacters.contains(scalar)
    }

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
