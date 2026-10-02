import Foundation

// MARK: - Discovered Skill

struct DiscoveredSkill: Equatable {
    let name: String
    let body: String
    let sourcePlatform: String
    let sourcePath: String
    var skillDescription: String?
    var cursorConfig: CursorAdapterConfig?
    var tags: [String] = []
    /// Local SKILL.md text without its leading BOM, separate from the duplicate-detection body.
    var sourceContent: String?

    /// Normalized body for duplicate detection (whitespace-normalized)
    var normalizedBody: String {
        body.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Protocol

protocol ImportScannerProtocol {
    /// Scan all known platform paths for existing skills
    func scan() -> [DiscoveredSkill]
    func scanFolder(_ path: String) -> [DiscoveredSkill]
    func isInsideStore(_ path: String) -> Bool
}

// MARK: - Implementation

final class ImportScanner: ImportScannerProtocol {
    private let fileService: FileServiceProtocol
    private let claudeSkillsDir: String
    private let grokSkillsDir: String
    private let cursorRulesDir: String
    private let codexSkillsDir: String
    private let storeRoot: String

    init(
        fileService: FileServiceProtocol,
        claudeSkillsDir: String = Constants.claudeCodeUserSkillsDir,
        grokSkillsDir: String = Constants.grokUserSkillsDir,
        cursorRulesDir: String = Constants.cursorUserRulesDir,
        codexSkillsDir: String = Constants.codexUserSkillsDir,
        storeRoot: String = Constants.pensieveBaseDir
    ) {
        self.fileService = fileService
        self.claudeSkillsDir = claudeSkillsDir
        self.grokSkillsDir = grokSkillsDir
        self.cursorRulesDir = cursorRulesDir
        self.codexSkillsDir = codexSkillsDir
        self.storeRoot = storeRoot
    }

    func scan() -> [DiscoveredSkill] {
        var discovered: [DiscoveredSkill] = []
        discovered += scanClaudeCode()
        discovered += scanGrok()
        discovered += scanCursor()
        discovered += scanCodex()
        return discovered
    }

    /// A `<dir>/<entry>/SKILL.md` scan shared by Claude Code, Grok, Codex, and Import from Folder….
    /// Dot-entries are skipped (Codex keeps a `.system` directory beside its skills).
    private func scanSkillDirectory(_ skillsDir: String, platform: String) -> [DiscoveredSkill] {
        guard fileService.directoryExists(at: skillsDir),
              let entries = try? fileService.listDirectory(at: skillsDir) else { return [] }
        return entries
            .filter { !$0.hasPrefix(".") }
            .compactMap { discoveredSkill(inDirectory: skillsDir, entry: $0, platform: platform) }
    }

    /// One `<dir>/<entry>/SKILL.md`: nil when there is none, when it cannot be read, or when it
    /// resolves into Pensieve's store (a deploy symlink on the entry, or a link anywhere along the
    /// path — a store skill must never be re-imported as a duplicate). With frontmatter, adopt the
    /// upstream identity and retain the original file for the import write.
    private func discoveredSkill(inDirectory skillsDir: String, entry: String, platform: String) -> DiscoveredSkill? {
        let skillPath = skillsDir + "/" + entry + "/SKILL.md"
        guard fileService.isRegularFile(at: skillPath), !isInsideStore(skillPath),
              let data = try? fileService.readRegularFileData(at: skillPath, maximumBytes: Int.max),
              let content = String(bytes: Self.sourceTextBytes(data), encoding: .utf8) else { return nil }
        // The byte boundary removes the encoding signature before decoding or frontmatter detection.
        let parsed = SkillParser.parse(content)
        if parsed.hasFrontmatter {
            let sourceName = parsed.name ?? entry
            let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry : sourceName
            return DiscoveredSkill(
                name: name,
                body: parsed.body,
                sourcePlatform: platform,
                sourcePath: skillPath,
                skillDescription: parsed.description,
                tags: parsed.tags,
                sourceContent: content
            )
        }
        return DiscoveredSkill(
            name: entry,
            body: content,
            sourcePlatform: platform,
            sourcePath: skillPath,
            skillDescription: nil,
            sourceContent: content
        )
    }

    static func sourceTextBytes(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    }

    private func scanClaudeCode() -> [DiscoveredSkill] { scanSkillDirectory(claudeSkillsDir, platform: "claude-code") }
    private func scanGrok() -> [DiscoveredSkill] { scanSkillDirectory(grokSkillsDir, platform: "grok") }
    private func scanCodex() -> [DiscoveredSkill] { scanSkillDirectory(codexSkillsDir, platform: "codex") }

    /// True when the path is Pensieve's own library or inside it — as written, resolved, or at any
    /// symlink on the way there. The last clause is C7 (`docs/CONVENTIONS.md` §15): a deploy link into
    /// a canonical `skills/<slug>` that itself links back out must never be ingested through, so a
    /// chain that merely passes through the store is refused with it.
    ///
    /// A hand-rolled `realpath(3)`: components are walked left to right against the physical
    /// directory reached so far, a link's target is spliced in place (so `..` applies to the real
    /// parent, never folded lexically — `standardizingPath` would also strip `/private`), and every
    /// intermediate path is checked. Linear in the components traversed; a loop or an absurd chain
    /// exhausts the budget and is refused rather than spun on.
    func isInsideStore(_ path: String) -> Bool {
        let roots = [storeRoot, fileService.realPath(at: storeRoot)]
        let storeIdentity = fileService.fileIdentity(at: storeRoot, followingLinks: true)
        // By spelling for a store that does not exist yet; by device and inode once it does, so a
        // differently cased spelling on a case-insensitive volume is the same directory and a
        // same-named directory on a case-sensitive one is not.
        func within(_ candidate: String) -> Bool {
            if roots.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) { return true }
            guard let store = storeIdentity,
                  let own = fileService.fileIdentity(at: candidate, followingLinks: false) else { return false }
            return own == store
        }
        var physical = "/"
        var components = Array((path as NSString).pathComponents.dropFirst())   // pathComponents leads with "/"
        var index = 0
        var budget = 4_096
        while index < components.count {
            let component = components[index]
            index += 1
            if component == "." || component.isEmpty { continue }
            if component == ".." { physical = (physical as NSString).deletingLastPathComponent; continue }
            let candidate = (physical as NSString).appendingPathComponent(component)
            budget -= 1
            if budget < 0 || within(candidate) { return true }
            if fileService.isSymlink(at: candidate), let target = try? fileService.symlinkTarget(at: candidate) {
                let targetComponents = (target as NSString).pathComponents
                if target.hasPrefix("/") {
                    physical = "/"
                    components = Array(targetComponents.dropFirst()) + components[index...]
                } else {
                    components = targetComponents + components[index...]
                }
                index = 0
                continue
            }
            physical = candidate
        }
        return false
    }

    /// Import from Folder…: the chosen folder is itself a skill (it holds SKILL.md), else a folder of
    /// skills (its immediate children hold one). Never deeper — a project checkout would otherwise
    /// import its vendored agent directories. The chosen folder may be a dot-folder; only children
    /// are subject to the dot rule. The library itself is refused: importing `~/.pensieve/skills`
    /// would duplicate every skill under a new slug with frontmatter tags in place of its overlay's.
    func scanFolder(_ path: String) -> [DiscoveredSkill] {
        guard !isInsideStore(path) else { return [] }   // never re-import the library into itself
        if fileService.fileExists(at: path + "/SKILL.md") {
            // The folder is a skill: its own SKILL.md decides, readable or not. An unreadable one
            // yields nothing rather than silently widening the import to the children.
            let parent = (path as NSString).deletingLastPathComponent
            let entry = (path as NSString).lastPathComponent
            return discoveredSkill(inDirectory: parent, entry: entry, platform: "folder").map { [$0] } ?? []
        }
        return scanSkillDirectory(path, platform: "folder")
    }

    // MARK: - Cursor

    private func scanCursor() -> [DiscoveredSkill] {
        var results: [DiscoveredSkill] = []

        // ~/.cursor/rules/*.mdc
        let rulesDir = cursorRulesDir
        if fileService.directoryExists(at: rulesDir),
           let entries = try? fileService.listDirectory(at: rulesDir) {
            for entry in entries where entry.hasSuffix(".mdc") {
                let mdcPath = rulesDir + "/" + entry
                if let content = try? fileService.readFile(at: mdcPath) {
                    let parsed = SkillParser.parseMDC(content)
                    let name = String(entry.dropLast(4)) // remove .mdc
                    results.append(DiscoveredSkill(
                        name: name,
                        body: parsed.body,
                        sourcePlatform: "cursor",
                        sourcePath: mdcPath,
                        skillDescription: parsed.description,
                        cursorConfig: parsed.cursorConfig
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Duplicate Detection

    /// Group discovered skills by similarity. Skills with >80% shared lines are grouped.
    static func findDuplicates(_ skills: [DiscoveredSkill]) -> [[DiscoveredSkill]] {
        var groups: [[DiscoveredSkill]] = []
        var assigned = Set<Int>()

        for i in 0..<skills.count {
            guard !assigned.contains(i) else { continue }
            var group = [skills[i]]
            assigned.insert(i)

            for j in (i + 1)..<skills.count {
                guard !assigned.contains(j) else { continue }
                if similarity(skills[i].normalizedBody, skills[j].normalizedBody) > 0.8 {
                    group.append(skills[j])
                    assigned.insert(j)
                }
            }

            if group.count > 1 {
                groups.append(group)
            }
        }

        return groups
    }

    /// Line-based similarity: percentage of shared lines after normalization.
    static func similarity(_ a: String, _ b: String) -> Double {
        let linesA = Set(a.components(separatedBy: " "))
        let linesB = Set(b.components(separatedBy: " "))
        let intersection = linesA.intersection(linesB).count
        let union = linesA.union(linesB).count
        guard union > 0 else { return 1.0 }
        return Double(intersection) / Double(union)
    }
}
