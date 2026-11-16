import Foundation

extension StoreIngestState {
    struct RenameHold {
        let record: RefusedCreateRecords.Rename
        var cached: SkillOverlay?

        mutating func observe(_ change: ManifestChange) {
            guard case .skillMetadata(let slug, let tags, let scope) = change, slug == record.new else { return }
            if let tags { cached?.tags = tags }
            if let scope { cached?.scope = scope }
        }

        func current(in local: ManifestSnapshot?) -> SkillOverlay? {
            if let current = local?.skills.first(where: { $0.slug == record.new && record.owns($0) }) { return current }
            return cached
        }
    }

    func holdRename(_ record: RefusedCreateRecords.Rename, cached: SkillOverlay? = nil) {
        lock.lock()
        defer { lock.unlock() }
        renameHolds[record.new] = RenameHold(record: record, cached: cached)
    }

    func heldRename(_ slug: String) -> RenameHold? {
        lock.lock()
        defer { lock.unlock() }
        return renameHolds[slug]
    }

    func forgetRename(_ slug: String) {
        lock.lock()
        defer { lock.unlock() }
        renameHolds[slug] = nil
    }

    /// A launch with unreadable rows still hides the peer overlay. An absent overlay makes
    /// the normal rebuild preserve this Mac's tags, scope and date on its existing row.
    func projectRenameHolds(_ holds: [RenameHold], onto snapshot: inout ManifestSnapshot,
                            durable: ManifestSnapshot, local: ManifestSnapshot?) {
        for hold in holds {
            let record = hold.record
            if hold.cached == nil, let local {
                guard let row = local.skills.first(where: { $0.slug == record.new }), record.owns(row) else {
                    forgetRename(record.new)
                    continue
                }
            }
            let current = hold.current(in: local)
            if let current { holdRename(record, cached: current) }
            if record.isTaken(in: durable) {
                snapshot.skills.removeAll { $0.slug.lowercased() == record.new.lowercased() }
                if var current { current.slug = record.new; snapshot.skills.append(current) }
            } else if let current {
                record.change(publishing: current, as: record.new).apply(to: &snapshot)
                if durable.skills.contains(where: { $0.slug == record.new && record.owns($0) }),
                   !durable.skills.contains(where: { $0.slug == record.old && record.owns($0) }) {
                    if durable.skills.contains(where: { $0.slug == record.old && !record.owns($0) }) {
                        preservePeer(record.old)
                    }
                    forgetRename(record.new)
                }
            }
        }
    }
}

extension StoreIngestState {
    func projectHeldRenames(onto snapshot: inout ManifestSnapshot, durable: ManifestSnapshot, local: ManifestSnapshot?) {
        lock.lock()
        let holds = Array(renameHolds.values)
        lock.unlock()
        projectRenameHolds(holds, onto: &snapshot, durable: durable, local: local)
    }
}

extension StoreIngestState {
    static func preserveRenameHolds(_ holds: [RenameHold], from disk: ManifestSnapshot,
                                    local: ManifestSnapshot, in snapshot: inout ManifestSnapshot) {
        for hold in holds {
            if hold.record.isTaken(in: disk) {
                keepRenameRecords(from: disk, old: hold.record.old, new: hold.record.new, in: &snapshot)
            } else if let current = hold.current(in: local) {
                var resolved = disk
                hold.record.change(publishing: current, as: hold.record.new).apply(to: &resolved)
                keepRenameRecords(from: resolved, old: hold.record.old, new: hold.record.new, in: &snapshot)
            } else {
                keepRenameRecords(from: disk, old: hold.record.old, new: hold.record.new, in: &snapshot)
            }
        }
    }
}
