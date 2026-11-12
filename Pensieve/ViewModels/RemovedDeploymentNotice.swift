import Foundation
import Observation
import os

@Observable
final class RemovedDeploymentNotice {
    static let title = "Pensieve removed deployments from this Mac"
    private let store: RemovedDeploymentNoticeStoring
    private(set) var entries: [RemovedDeploymentNoticeEntry]
    /// One main window at a time may show the shared pending list.
    private(set) var presentationID: UUID?

    init(store: RemovedDeploymentNoticeStoring) {
        self.store = store
        entries = (try? store.read()) ?? []
    }

    func add(_ entry: RemovedDeploymentNoticeEntry) {
        guard !entries.contains(where: { $0.matches(entry) }) else { return }
        entries.append(entry)
        save()
    }

    func dismiss(_ shown: [RemovedDeploymentNoticeEntry]) {
        let ids = Set(shown.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func beginPresentation() -> UUID? {
        guard presentationID == nil, !entries.isEmpty else { return nil }
        let id = UUID()
        presentationID = id
        return id
    }

    func endPresentation(_ id: UUID) {
        if presentationID == id { presentationID = nil }
    }

    static func message(for entries: [RemovedDeploymentNoticeEntry]) -> String {
        struct ProjectSkill: Hashable {
            let slug: String, name: String, path: String
        }
        let groups = Dictionary(grouping: entries) {
            ProjectSkill(slug: $0.slug, name: $0.projectName, path: $0.projectPath)
        }
        let lines = groups.map { key, entries in
            let agents = Set(entries.map { $0.platform.displayName }).sorted()
            return "“\(key.slug)” was renamed or deleted, so it was removed from \(key.name) (\(key.path))"
                + " for \(ListFormatter.localizedString(byJoining: agents))."
        }.sorted()
        return (lines + ["Deploy it again if you still want it there."]).joined(separator: "\n\n")
    }

    private func save() {
        do { try store.write(entries) } catch {
            // Memory remains authoritative, even if disk still holds a dismissed snapshot.
            Logger(subsystem: "com.jaredatch.pensieve", category: "removedDeployments")
                .warning("Couldn't save the local removal message: \(error.localizedDescription, privacy: .public)")
        }
    }
}
