import Foundation
import SwiftData
import SwiftUI

@Observable
final class ImportViewModel {
    enum FolderScanOutcome: Equatable { case found(Int), nothingFound, insideLibrary }

    private let scanner: ImportScannerProtocol
    private let skillStore: SkillStoreProtocol
    private let manifestService: ManifestSnapshotting?
    private let manifestRoot: String
    private let notifier: SyncStateNotifying
    private let echoRegistrar: SyncWriteEchoRegistering

    var discoveredSkills: [DiscoveredSkill] = []
    var duplicateGroups: [[DiscoveredSkill]] = []
    var selectedSkills: Set<String> = [] // sourcePath as identifier
    var isScanning = false
    var importProgress: Double = 0
    var error: String?
    var importNotices: [String] = []
    var scanSkips: [ImportScanSkip] = []
    private var latestFolderReport = ImportScanReport()
    private(set) var importedSkillCount = 0

    var hasResults: Bool { !discoveredSkills.isEmpty }

    var doneTitle: String {
        if !hasResults { return scanSkips.isEmpty ? "No Skills Found" : "No Skills Imported" }
        return error == nil && importedSkillCount == selectedSkills.count ? "Import Complete" : "Import Finished"
    }

    var doneMessage: String {
        if hasResults {
            let noun = importedSkillCount == 1 ? "skill" : "skills"
            return "\(importedSkillCount) \(noun) imported into Pensieve."
        }
        return scanSkips.isEmpty ? "No existing skills were found. Create your first skill to get started."
            : "No skills could be imported from the scanned entries."
    }

    var scanSummary: String? {
        ImportScanReport(skipped: scanSkips).summary
    }

    init(
        fileService: FileServiceProtocol? = nil,
        scanner: ImportScannerProtocol? = nil,
        skillStore: SkillStoreProtocol? = nil,
        manifestService: ManifestSnapshotting? = nil,
        manifestRoot: String = Constants.pensieveBaseDir,
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        echoRegistrar: @escaping SyncWriteEchoRegistering = SyncWriteEchoRegistrar.suppressed
    ) {
        let fs = fileService ?? FileService()
        self.scanner = scanner ?? ImportScanner(fileService: fs)
        self.skillStore = skillStore ?? SkillStore(fileService: fs)
        self.manifestService = manifestService
        self.manifestRoot = manifestRoot
        self.notifier = notifier
        self.echoRegistrar = echoRegistrar
    }

    // MARK: - Scan

    func scan() {
        latestFolderReport = ImportScanReport()
        importNotices = []
        importedSkillCount = 0
        error = nil
        isScanning = true
        let report = scanner.scanWithReport()
        discoveredSkills = report.skills
        scanSkips = report.skipped
        duplicateGroups = ImportScanner.findDuplicates(discoveredSkills)
        // Select all by default
        selectedSkills = Set(discoveredSkills.map(\.sourcePath))
        isScanning = false
    }

    /// Import from Folder…: `scan()` over one chosen folder (PLAN-30 / 30.2). The library itself is
    /// refused before any read; an empty result leaves the previous scan results untouched. Every call
    /// clears the last import's notices and error first (PLAN-42).
    @discardableResult
    func scanFolder(_ path: String) -> FolderScanOutcome {
        latestFolderReport = ImportScanReport()
        importNotices = []
        importedSkillCount = 0
        error = nil
        guard !scanner.isInsideStore(path) else { return .insideLibrary }
        isScanning = true
        defer { isScanning = false }
        let report = scanner.scanFolderWithReport(path)
        latestFolderReport = report
        let found = report.skills
        guard !found.isEmpty else {
            // A report belongs to its results. Keep both when retaining an earlier non-empty scan.
            if discoveredSkills.isEmpty { scanSkips = report.skipped }
            return .nothingFound
        }
        discoveredSkills = found
        scanSkips = report.skipped
        duplicateGroups = ImportScanner.findDuplicates(discoveredSkills)
        selectedSkills = Set(discoveredSkills.map(\.sourcePath))
        return .found(found.count)
    }

    func nothingFoundMessage(folder shown: String) -> String {
        let explanation = "\(shown) holds no readable SKILL.md. Pensieve looks in it and in its folders, never deeper."
        guard let summary = latestFolderReport.summary else { return explanation }
        return explanation + "\n\n\(shown): \(summary)"
    }

    func toggleSelection(_ skill: DiscoveredSkill) {
        if selectedSkills.contains(skill.sourcePath) {
            selectedSkills.remove(skill.sourcePath)
        } else {
            selectedSkills.insert(skill.sourcePath)
        }
    }

    func isSelected(_ skill: DiscoveredSkill) -> Bool {
        selectedSkills.contains(skill.sourcePath)
    }

    // MARK: - Import

    /// Best-effort: regenerate the on-disk manifest from current SwiftData state after import has written
    /// synced state (skill rows carrying `cursorConfig`/`importedFrom`). No-op when no manifest service is
    /// wired (tests). A failure is SURFACED via `error`, never silently swallowed (the import itself already
    /// succeeded and is not rolled back). Import is no longer the deliberately-deferred overlay site.
    /// The launch rebuild (PLAN-12 / 12.3) treats the manifest as authoritative, so the
    /// overlay must exist before the next relaunch — otherwise an imported skill's Cursor config / origin /
    /// tags / scope would reset to defaults when `StoreRebuildService` rebuilds off an overlay-less manifest.
    private func regenerateManifest(context: ModelContext) {
        guard let manifestService else { return }
        do {
            try manifestService.write(manifestService.snapshot(from: context), toRoot: manifestRoot)
        } catch {
            self.error = "Imported, but updating the sync manifest failed: \(error.localizedDescription)"
        }
    }

    func importSelected(
        context: ModelContext,
        takenSlugs: (ModelContext) throws -> Set<String> = { Set(try $0.fetch(FetchDescriptor<Skill>()).map(\.directoryName)) },
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) {
        importNotices = []
        importedSkillCount = 0
        error = nil
        let toImport = discoveredSkills.filter { selectedSkills.contains($0.sourcePath) }
        guard !toImport.isEmpty else { return }

        var taken: Set<String>
        do {
            taken = try takenSlugs(context)
        } catch {
            self.error = "Failed to import: couldn't read the library (\(error.localizedDescription))"
            return
        }

        importProgress = 0
        var writtenSlugs: [String] = []

        for discovered in toImport {
            do {
                let resolvedDescription = resolvedDescription(for: discovered)
                let prepared = preparedContent(for: discovered, description: resolvedDescription)
                let dirName = try createImportedSkill(discovered, description: resolvedDescription,
                                                      content: prepared.content, avoiding: taken)
                if prepared.keptAsText {
                    importNotices.append("\(discovered.name): frontmatter was kept as text.")
                }
                taken.insert(dirName)
                let skill = Skill(
                    name: discovered.name,
                    skillDescription: resolvedDescription,
                    tags: TagTokens.normalize(discovered.tags),
                    directoryName: dirName,
                    cursorConfig: discovered.cursorConfig,
                    importedFrom: discovered.sourcePlatform
                )
                context.insert(skill)
                writtenSlugs.append(dirName)
                importProgress = Double(writtenSlugs.count) / Double(toImport.count)
            } catch {
                self.error = "Failed to import \(discovered.name): \(error.localizedDescription)"
            }
        }

        do {
            try saveContext(context)
            importedSkillCount = writtenSlugs.count
            regenerateManifest(context: context)
            echoRegistrar(writtenSlugs)
            notifier()
        } catch {
            self.error = "Failed to save imported skills: \(error.localizedDescription)"
        }
    }

    private func resolvedDescription(for discovered: DiscoveredSkill) -> String {
        guard let description = discovered.skillDescription,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return discovered.name }
        return description
    }

    private func createImportedSkill(
        _ discovered: DiscoveredSkill, description: String, content: String?, avoiding: Set<String>
    ) throws -> String {
        if let content {
            return try skillStore.createSkill(name: discovered.name, content: content, avoiding: avoiding)
        }
        return try skillStore.createSkill(
            name: discovered.name, description: description, body: discovered.body, avoiding: avoiding
        )
    }

    private func preparedContent(
        for discovered: DiscoveredSkill, description: String
    ) -> (content: String?, keptAsText: Bool) {
        guard let source = discovered.sourceContent else { return (nil, false) }
        let parsed = SkillParser.parse(source)
        if parsed.preservedFrontmatter != nil,
           let normalized = SkillSerializer.normalizeIdentity(name: discovered.name, description: description, parsed: parsed) {
            return (normalized, false)
        }
        let firstLine = SkillParser.sourceLines(in: source, yamlBreaks: false)[0]
        let startsWithFence = SkillParser.isFrontmatterFence(source[firstLine.contentRange])
        return (
            SkillSerializer.serialize(name: discovered.name, description: description, body: source),
            startsWithFence
        )
    }

}
