import Foundation
import SwiftData

/// Per-machine observation cache for one canonical repository/ref pair. It is intentionally absent
/// from the synced manifest; a fresh SwiftData rebuild starts without cursors and checks anew.
@Model
final class RepoUpdateCursor {
    @Attribute(.unique) var id: UUID
    var repo: String
    var ref: String
    var lastSeenHead: String?
    var lastCheckedAt: Date

    init(repo: String, ref: String, lastSeenHead: String?, lastCheckedAt: Date) {
        self.id = UUID()
        self.repo = repo
        self.ref = ref
        self.lastSeenHead = lastSeenHead
        self.lastCheckedAt = lastCheckedAt
    }
}
