import Foundation

/// The Overview tab's rows from the snapshot and the provenance — pure, so the numbers and the copy are
/// tested apart from SwiftUI (the frames `Skills / Details — Overview (installed)` and `(authored)`).
enum SkillOverviewPresentation {
    struct Stat: Equatable, Identifiable {
        let label: String
        let value: String
        let detail: String
        var id: String { label }
    }

    enum SourceAction: Equatable {
        case open(URL)
        case copy(String)
        case reveal(String)
    }

    struct SourceRow: Equatable, Identifiable {
        let label: String
        let value: String
        /// The lighter text after the value ("/tree/main/skills/basecamp", "d3cc757", "1 month ago"),
        /// joined by `separator`.
        let detail: String?
        let separator: String
        let action: SourceAction?
        var id: String { label }
    }

    struct ContentsRow: Equatable, Identifiable {
        let relativePath: String
        let tokens: Int
        /// The bar's share of the widest row, 0…1.
        let share: Double
        var id: String { relativePath }
    }

    static let contentsRowsShown = 5

    static func stats(snapshot: DetailContentSnapshot, installedCount: Int, locale: Locale = .current) -> [Stat] {
        let inventory = snapshot.inventory
        // A walk stopped at its caps or at an unreadable entry counted what it read: a floor, marked "+".
        let floor = inventory.truncated ? "+" : ""
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(inventory.totalBytes), countStyle: .file)
        return [
            Stat(label: "Context cost", value: snapshot.tokenCount.formatted(.number.locale(locale)),
                 detail: "tokens when loaded"),
            Stat(label: "Bundle", value: inventory.fileCount.formatted(.number.locale(locale)) + floor,
                 detail: (inventory.fileCount == 1 && !inventory.truncated ? "file · " : "files · ") + bytes + floor),
            Stat(label: "Deployed", value: "\(snapshot.deployedOnThisMac) of \(installedCount)",
                 detail: "platforms on this Mac")
        ]
    }

    /// A linked skill: Repository, Tracked ref, Local path, Installed, Last updated. An authored or
    /// imported one: Local path, Created, Modified.
    static func sourceRows(skill: Skill, provenance: SkillProvenance?, origin: InstalledOrigin?,
                           homeDirectory: String, now: Date, locale: Locale = .current) -> [SourceRow] {
        var rows: [SourceRow] = []
        if let provenance, let origin {
            let repositoryPath = SkillDetailHeaderPresentation.repositoryPath(provenance)
            let treePath = provenance.skillURL.map { String($0.path.dropFirst(provenance.repositoryURL?.path.count ?? 0)) }
            rows.append(SourceRow(label: "Repository", value: repositoryPath ?? origin.repo, detail: treePath,
                                  separator: "•", action: (provenance.skillURL ?? provenance.repositoryURL).map { .open($0) }))
            let copy: SourceAction? = origin.installedCommit.isEmpty ? nil : .copy(origin.installedCommit)
            if let ref = provenance.trackedRef {
                rows.append(SourceRow(label: "Tracked ref", value: ref, detail: provenance.shortCommit,
                                      separator: "@", action: copy))
            } else {
                rows.append(SourceRow(label: "Tracked ref", value: provenance.shortCommit ?? "—", detail: "pinned",
                                      separator: "•", action: copy))
            }
        }
        rows.append(SourceRow(label: "Local path",
                              value: ListRows.abbreviatePath(skill.canonicalDir, homeDirectory: homeDirectory),
                              detail: nil, separator: "•", action: .reveal(skill.canonicalDir)))
        if let provenance, provenance.installedAt != nil || provenance.updatedAt != nil {
            if let installed = provenance.installedAt {
                rows.append(dateRow("Installed", installed, now: now, locale: locale))
            }
            if let updated = provenance.updatedAt {
                rows.append(dateRow("Last updated", updated, now: now, locale: locale))
            }
        } else {
            rows.append(dateRow("Created", skill.createdAt, now: now, locale: locale))
            rows.append(dateRow("Modified", skill.updatedAt, now: now, locale: locale))
        }
        return rows
    }

    /// The bundle's text files by tokens, the widest first; the bar is each row's share of the widest.
    static func contentsRows(inventory: SkillBundleInventory) -> [ContentsRow] {
        let text = inventory.textFiles.compactMap { file in file.tokens.map { (file.relativePath, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let widest = Double(text.first?.1 ?? 0)
        return text.map { path, tokens in
            ContentsRow(relativePath: path, tokens: tokens, share: widest > 0 ? Double(tokens) / widest : 0)
        }
    }

    /// "Show N more files" past the rows shown, or nil when every row is.
    static func moreFilesLabel(total: Int, shown: Int) -> String? {
        let more = total - shown
        guard more > 0 else { return nil }
        return more == 1 ? "Show 1 more file" : "Show \(more) more files"
    }

    static func dateText(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }

    /// What `RelativeDateTimeFormatter` says in full units: "1 month ago", "4 weeks ago", "9 days ago".
    /// Under a minute reads "just now": a new skill's file date lands a hair past `now`, and the formatter
    /// says "in 0 seconds" for anything from a second ago to the future (#21).
    static func relativeText(_ date: Date, now: Date, locale: Locale = .current) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func dateRow(_ label: String, _ date: Date, now: Date, locale: Locale) -> SourceRow {
        SourceRow(label: label, value: dateText(date, locale: locale), detail: relativeText(date, now: now, locale: locale),
                  separator: "•", action: nil)
    }
}
