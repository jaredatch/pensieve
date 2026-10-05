import Foundation

/// SwiftData-free deploy reconcile the daemon runs after a successful pull (PLAN-12 / 12.8–12.9).
/// Lives in `Pensieve/Services/` (app-compiled + explicitly daemon-listed in `project.yml`) so
/// `PensieveTests` drives it directly; `PensieveDaemon/main.swift` injects it into `runOnce` at 12.10.
/// Every path root is injected so tests point them at a temp HOME. Conforms to `DeployReconciling`
/// (PLAN-12 / 12.6). Stage 12.8 lands `pruneDangling`; Stage 12.9 added `reconcileCursor` and the full
/// `reconcile(root:)` orchestration (read-manifest → pruneDangling → reconcileCursor).
final class DeployReconciler: DeployReconciling {
    /// The result of one prune pass. `removed` are the agent symlink paths deleted (dangling and
    /// Pensieve-owned); `skippedDirs` are agent dirs left un-walked (symlinked / realpath-escaping parent).
    struct PruneResult: Equatable {
        var removed: [String] = []
        var skippedDirs: [String] = []
    }

    /// The result of one Cursor reconcile pass. `recompiled` are the `.mdc` paths rewritten to match
    /// source. The daemon never DELETES a `.mdc` (see `reconcileCursor` — a filename-only orphan delete
    /// would risk the user's own non-Pensieve rules in the shared `~/.cursor/rules`).
    struct CursorReconcileResult: Equatable {
        var recompiled: [String] = []
    }

    private let fileService: FileServiceProtocol
    private let pensieveSkillsDir: String
    private let agentSkillDirs: [String]
    private let cursorRulesDir: String
    private let manifestService: ManifestReadWriting
    private let deployState: DeployStateStore
    private let ownership: DeployArtifactOwnershipChecking

    init(
        fileService: FileServiceProtocol,
        deployState: DeployStateStore? = nil,
        pensieveSkillsDir: String = PathConstants.pensieveSkillsDir,
        agentSkillDirs: [String] = DeployReconciler.defaultAgentSkillDirs,
        cursorRulesDir: String = PathConstants.cursorUserRulesDir,
        manifestService: ManifestReadWriting = ManifestService()
    ) {
        self.fileService = fileService
        self.pensieveSkillsDir = pensieveSkillsDir
        self.agentSkillDirs = agentSkillDirs
        self.cursorRulesDir = cursorRulesDir
        self.manifestService = manifestService
        self.deployState = deployState ?? DeployStateStore(fileService: fileService)
        self.ownership = DeployArtifactOwnership(fileService: fileService)
    }

    /// User-wide agent skill dirs whose Pensieve symlinks the daemon prunes. Project-scoped agent dirs
    /// are NOT reconciled (daemon scope fence).
    static var defaultAgentSkillDirs: [String] {
        PlatformTarget.allCases.compactMap(DeployPaths.userSkillsRoot(for:))
    }

    @discardableResult
    func reconcile(root: String) throws -> ReconcileOutcome {
        let prune = pruneDangling()
        // Read the manifest to drive the Cursor reconcile. On ANY read failure — a `ManifestError`
        // (corrupt / unsupported schema) or I/O — skip the Cursor reconcile (fail-safe) while KEEPING the
        // prune result: a bad manifest must never block the pull that already landed or touch a `.mdc`.
        let cursor: CursorReconcileResult
        if let manifest = try? manifestService.read(fromRoot: root) {
            cursor = reconcileCursor(manifest: manifest)
        } else {
            cursor = CursorReconcileResult()
        }
        return ReconcileOutcome(prunedLinks: prune.removed.count, recompiledRules: cursor.recompiled.count)
    }

    /// Regenerate stale recorded user-wide `~/.cursor/rules/*.mdc` after a content pull (symlinks
    /// self-heal; `.mdc` does not). A rule is rewritten only when deploy state records its exact
    /// user/cursor path, it has the mark or byte-exact current legacy content, and the canonical
    /// `SKILL.md` still passes the leaf guard. Unrecorded `.mdc` files are left untouched
    /// even when their slug matches a canonical skill, and the daemon still never deletes any `.mdc`.
    /// Only user-wide `~/.cursor/rules` is reconciled; project-scoped `.cursor/rules` is NOT (daemon scope
    /// fence). Pure filesystem; no SwiftData.
    func reconcileCursor(manifest: ManifestSnapshot) -> CursorReconcileResult {
        var result = CursorReconcileResult()
        let records = (try? deployState.read())?.records ?? []
        guard fileService.directoryExists(at: cursorRulesDir),
              let entries = try? fileService.listDirectory(at: cursorRulesDir) else { return result }
        for entry in entries where entry.hasSuffix(".mdc") {
            let slug = String(entry.dropLast(4))   // strip ".mdc"
            let mdcPath = cursorRulesDir + "/" + entry
            guard records.contains(where: {
                $0.artifactPath == mdcPath
                    && $0.scope == "user"
                    && $0.platform == PlatformTarget.cursor.rawValue
            }) else {
                continue
            }
            guard let skillFilePath = SkillStore.safeSkillFile(
                slug: slug,
                base: pensieveSkillsDir,
                fileService: fileService
            ) else {
                // Recorded but no longer safely readable: skip. Cursor rules are never deleted by the
                // daemon; a later GUI backfill can heal stale deploy-state.
                continue
            }
            guard let raw = try? fileService.readFile(at: skillFilePath) else { continue }
            let parsed = SkillParser.parse(raw)
            let cursor = manifest.skills.first(where: { $0.slug == slug })?.cursor
            let expected = CursorMDC.generate(
                directoryName: slug,
                description: cursor?.description ?? parsed.description ?? "",
                cursorConfig: cursor,
                body: SkillParser.stripFrontmatter(raw)
            )
            let occupant = try? ownership.cursor(at: mdcPath) {
                CursorMDC.generateLegacy(directoryName: slug, description: cursor?.description ?? parsed.description ?? "",
                                         cursorConfig: cursor, body: SkillParser.stripFrontmatter(raw))
            }
            guard occupant == .owned else { continue }
            let current = try? fileService.readRegularFileData(at: mdcPath, maximumBytes: expected.utf8.count)
            if current != Data(expected.utf8), (try? fileService.writeFile(at: mdcPath, content: expected)) != nil {
                result.recompiled.append(mdcPath)
            }
        }
        return result
    }

    /// Remove agent symlinks orphaned by skills deleted upstream. For each user-wide agent dir: skip it
    /// entirely if the dir itself is a symlink or its realpath does not match its own literal
    /// parent+component (a redirected `~/.claude/skills` must never steer the prune — never walk it).
    /// Otherwise, for each entry that is a symlink, remove it IFF (a) its target is an ABSOLUTE path under
    /// a direct child of `pensieveSkillsDir` (foreign and relative targets are never touched) AND
    /// (b) that target no longer exists (dangling). The link's own basename is guarded through
    /// `SkillStore.safeSkillDirectory` (the single C7 slug guard — no open-coded sixth guard).
    /// Only the LINK is ever removed, never a target. Pure filesystem; no SwiftData.
    func pruneDangling() -> PruneResult {
        var result = PruneResult()
        for agentDir in agentSkillDirs {
            if fileService.isSymlink(at: agentDir) || !isRealpathContained(agentDir) {
                result.skippedDirs.append(agentDir)
                continue
            }
            result.removed.append(contentsOf: prunedLinks(in: agentDir))
        }
        return result
    }

    /// True iff `dir`'s realpath equals its own literal parent's realpath + last component — i.e. the
    /// leaf is not a symlink redirecting the dir elsewhere. Mirrors `SkillStore.safeSkillDirectory`'s
    /// realpath-containment shape and stays robust to benign ancestor symlinks (e.g. `/var`→`/private/var`)
    /// because both sides resolve them identically.
    private func isRealpathContained(_ dir: String) -> Bool {
        let parent = (dir as NSString).deletingLastPathComponent
        let last = (dir as NSString).lastPathComponent
        let realDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let realParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        return realDir == realParent + "/" + last
    }

    /// Prune the dangling Pensieve-owned symlinks directly under `agentDir`. Returns the removed link paths.
    private func prunedLinks(in agentDir: String) -> [String] {
        guard fileService.directoryExists(at: agentDir),
              let entries = try? fileService.listDirectory(at: agentDir) else { return [] }
        var removed: [String] = []
        for entry in entries {
            // The link's basename is the realized skill's slug; guard it through the single C7 guard.
            guard SkillStore.safeSkillDirectory(
                slug: entry,
                base: pensieveSkillsDir,
                fileService: fileService
            ) != nil else { continue }
            let link = agentDir + "/" + entry
            guard fileService.isSymlink(at: link),
                  let target = try? fileService.symlinkTarget(at: link) else { continue }
            // Ownership uses the literal direct-child shape, including links naming another skill.
            // Never normalize targets: `<store>/alias/../outside` can escape through a linked alias.
            guard DeployArtifactOwnership.ownsLinkTarget(target, skillsDirectory: pensieveSkillsDir, linksFile: false) else {
                continue
            }
            // (b) dangling: the canonical target no longer exists → remove the LINK (never the target).
            guard !fileService.fileExists(at: target), !fileService.directoryExists(at: target) else { continue }
            // Report a removal only when the delete actually succeeded — a link we could not remove (e.g.
            // a permissions error) is left for the next cycle, never counted as pruned (the count feeds
            // the status file PLAN-14 reads).
            do {
                try fileService.deleteFile(at: link)
                try? deployState.remove(artifactPath: link)
                removed.append(link)
            } catch {
                continue
            }
        }
        return removed
    }
}
