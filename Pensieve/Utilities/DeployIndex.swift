import Foundation

/// This Mac's recorded deploys indexed by skill slug, for the middle column's rows and the Skills
/// filter (PLAN-29). Built from `deploy-state.json`, PLAN-16's realized-set artifact, and rebuilt by
/// `PlatformViewModel.refreshDeployIndex()` after every write the app makes or observes, so SwiftUI
/// bodies read it as observable state and never touch the disk. `available == false`
/// means the file could not be read (unreadable bytes or a newer schema); consumers must say so
/// rather than report "Not deployed" (PLAN-24's tri-state rule: a probe's failure is not an answer).
struct DeployIndex: Equatable {
    private let bySlug: [String: [DeployStateRecord]]
    let available: Bool

    init(records: [DeployStateRecord]) {
        var grouped: [String: [DeployStateRecord]] = [:]
        for record in records {
            grouped[record.slug, default: []].append(record)
        }
        bySlug = grouped
        available = true
    }

    private init(unavailable: Void) {
        bySlug = [:]
        available = false
    }

    static let unavailable = DeployIndex(unavailable: ())
    static let empty = DeployIndex(records: [])

    func records(for slug: String) -> [DeployStateRecord] {
        bySlug[slug] ?? []
    }

    func isDeployed(slug: String) -> Bool {
        !records(for: slug).isEmpty
    }

    /// Distinct slugs carrying at least one project-scoped record for an identity key or a keyless checkout path.
    func skillCount(inProjectKey key: String) -> Int {
        bySlug.values.reduce(into: 0) { count, records in
            if records.contains(where: { $0.scope == "project" && $0.projectReference == key }) {
                count += 1
            }
        }
    }

    /// Mail's second line for a skill: "Claude Code, Codex · This Mac", "Cursor · 2 projects",
    /// "Claude Code · This Mac, 1 project", "Not deployed", or "Deploy state unavailable".
    /// Platforms are named in `PlatformTarget.allCases` order; a raw value this build does not know
    /// is shown as-is after them rather than dropped, so a newer build's record still counts.
    func summary(for slug: String) -> String {
        guard available else { return "Deploy state unavailable" }
        let records = records(for: slug)
        guard !records.isEmpty else { return "Not deployed" }
        let rawPlatforms = Set(records.map(\.platform))
        let known = PlatformTarget.allCases.filter { rawPlatforms.contains($0.rawValue) }
        let names = known.map(\.displayName) + rawPlatforms.subtracting(known.map(\.rawValue)).sorted()
        var scopes: [String] = []
        if records.contains(where: { $0.scope == "user" || ($0.scope == "project" && $0.projectIdentityKey == nil) }) {
            scopes.append("This Mac")
        }
        let projectKeys = Set(records.filter { $0.scope == "project" }.map(\.projectReference))
        if !projectKeys.isEmpty {
            scopes.append(projectKeys.count == 1 ? "1 project" : "\(projectKeys.count) projects")
        }
        let platforms = names.joined(separator: ", ")
        return scopes.isEmpty ? platforms : platforms + " · " + scopes.joined(separator: ", ")
    }
}
