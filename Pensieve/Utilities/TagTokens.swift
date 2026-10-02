import Foundation

/// The tag editor's rules, apart from AppKit: what a typed list becomes and what completion offers.
enum TagTokens {
    /// Trim each token, drop empties, keep the first spelling of a duplicate (case-insensitive), and
    /// sort with the manifest's comparator — the overlay stores tags `sorted()`, so a rebuild would
    /// reorder them anyway; sorting here keeps the field and the store in one order. Case is kept as
    /// typed: "Swift" and "swift" are one tag, spelled as first entered.
    static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in raw {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result.sorted()   // the manifest's own comparator (`appendBlockList` uses `sorted()`), so one order everywhere
    }

    /// What ending an edit does, given what the field showed when editing began (`baseline`), what it
    /// shows now (`edited`), and what the store holds now (`stored` — it may have moved under the edit,
    /// a sync pull). An untouched field never writes: it adopts the store. A touched field is the user's
    /// intent and wins, unless it already equals the store.
    enum CommitDecision: Equatable { case nothing, adoptStored, commit([String]) }

    static func commitDecision(baseline: [String], edited: [String], stored: [String]) -> CommitDecision {
        let b = normalize(baseline), e = normalize(edited), s = normalize(stored)
        if e == b { return e == s ? .nothing : .adoptStored }
        return e == s ? .nothing : .commit(e)
    }

    /// Completions for what the user has typed so far: tags in use that start with it
    /// (case-insensitive), excluding tags already on the skill, sorted case-insensitively.
    static func completions(for prefix: String, inUse: [String], excluding present: [String]) -> [String] {
        let typed = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return [] }
        let presentKeys = Set(present.map { $0.lowercased() })
        return inUse
            .filter { $0.lowercased().hasPrefix(typed) && !presentKeys.contains($0.lowercased()) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
