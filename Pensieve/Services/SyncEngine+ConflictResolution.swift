import Foundation

extension SyncEngine {
    private struct Selection {
        let path: String
        let chosen: ConflictVersion
        let stage: Int
        let hasGitlink: Bool
    }

    private func conflictSelections(_ paths: [String], picks: [String: ResolutionPick],
                                    root: String) throws -> [Selection] {
        try paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { path in
            let this = try ConflictVersion { try gitService.conflictEntry(atStage: 3, path: path, in: root) }
            let other = try ConflictVersion { try gitService.conflictEntry(atStage: 2, path: path, in: root) }
            guard let pick = picks[path],
                  pick.expectedThis == this.bytes, pick.expectedOther == other.bytes,
                  pick.expectedThisUnavailable == this.unavailable,
                  pick.expectedOtherUnavailable == other.unavailable,
                  pick.expectedThisMode == this.mode, pick.expectedOtherMode == other.mode else {
                throw SyncError.conflictsChanged
            }
            let chosen = pick.side == .thisMachine ? this : other
            let unchosen = pick.side == .thisMachine ? other : this
            if let error = ConflictItem.selectionError(path: path, chosen: chosen.unavailable,
                                                      other: unchosen.unavailable) { throw error }
            return Selection(path: path, chosen: chosen, stage: pick.side == .thisMachine ? 3 : 2,
                    hasGitlink: this.isGitlink || other.isGitlink)
        }
    }

    func resolveConflictedPaths(_ paths: [String], picks: [String: ResolutionPick],
                                root: String) throws {
        guard Set(paths) == Set(picks.keys) else { throw SyncError.conflictsChanged }
        // Read and validate all index versions before restoring a parent can clear child stages.
        let selections = try conflictSelections(paths, picks: picks, root: root)
        var replacements: [String] = []
        for selection in selections {
            let path = selection.path
            let chosen = selection.chosen
            if replacements.contains(where: { PathSyntax.hasPrefix(path, $0 + "/") }) {
                try gitService.removeConflictEntryFromIndex(path, at: root)
                continue
            }
            guard let full = validatedWorktreePath(path, root: root) else { throw SyncError.conflictsChanged }
            if StoreIgnoreRules.canRetire(path)
                && (chosen.unavailable?.canChoose == true || (selection.hasGitlink && chosen.mode == nil)) {
                try gitService.retireConflictPath(path, at: root)
                continue
            }
            let replacesFolder = try fileService.entryTypeWithoutFollowingLinks(at: full) == .directory
                && chosen.entry != nil
            if replacesFolder {
                guard selections.filter({ PathSyntax.hasPrefix($0.path, path + "/") }).allSatisfy({
                    $0.chosen.entry == nil && $0.chosen.unavailable == nil
                }) else { throw SyncError.conflictsChanged }
            }
            do {
                try applyConflictVersion(chosen, stage: selection.stage, path: path, full: full, root: root)
            } catch is ConflictFolderMustMove { throw SyncError.conflictFolderMustMove(path: path) }
            if replacesFolder { replacements.append(path) }
        }
    }

    private func applyConflictVersion(_ chosen: ConflictVersion, stage: Int, path: String,
                                      full: String, root: String) throws {
        if chosen.entry == nil, try fileService.entryTypeWithoutFollowingLinks(at: full) == .directory {
            // The folder side removed the old file. Resolve that index entry without staging or
            // deleting its children; their own conflict picks retain their native stages.
            try gitService.removeConflictEntryFromIndex(path, at: root)
            return
        }
        if let entry = chosen.entry {
            if entry.mode == "120000" {
                guard let target = String(data: entry.bytes, encoding: .utf8),
                      !target.utf8.contains(0), symlinkTargetIsContained(target, at: full, root: root) else {
                    throw SyncError.conflictsChanged
                }
            }
            try gitService.restoreConflictEntry(entry, stage: stage, path: path, at: root)
        } else if try fileService.entryExistsWithoutFollowingLinks(at: full) {
            try fileService.deleteFile(at: full)
        }
        try gitService.stagePath(path, at: root)
    }

    /// Validate a git-relative path before writing/deleting through it. Reject: empty/absolute paths;
    /// any `.`/`..`/empty/control-scalar component; any symlink at a directory/non-leaf component; and
    /// a symlinked leaf whose target resolves outside `root`. Containment is boundary-aware.
    private func validatedWorktreePath(_ path: String, root: String) -> String? {
        guard !path.isEmpty, !PathSyntax.isAbsolute(path) else { return nil }
        let components = PathSyntax.components(path, omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return nil }
            if component.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return nil
            }
        }
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var current = realRoot
        for (index, component) in components.enumerated() {
            current += "/" + component
            guard fileService.isSymlink(at: current) else { continue }
            // C7: never write/delete THROUGH a symlinked DIRECTORY component. A symlinked `skills/<slug>`
            // dir (even one whose target stays inside root) would redirect the atomic SKILL.md write into
            // the link target. Reject any non-leaf symlink outright; a symlinked leaf is safe because
            // `writeFile(atomically:)` replaces the link rather than following it (so keep the leaf's
            // escape-only check below).
            if index != components.count - 1 { return nil }
            guard let target = try? fileService.symlinkTarget(at: current) else { return nil }
            if !symlinkTargetIsContained(target, at: current, root: realRoot) { return nil }
        }
        return root + "/" + path
    }

    private func symlinkTargetIsContained(_ target: String, at path: String, root: String) -> Bool {
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let base = PathSyntax.isAbsolute(target) ? target : (path as NSString).deletingLastPathComponent + "/" + target
        let resolved = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        return resolved == realRoot || PathSyntax.hasPrefix(resolved, realRoot + "/")
    }

    /// Give Git the intact refused folder first. If abort cannot replace it, discard only that
    /// obstruction and retry. Stage 3 still proves the local file/link that abort must restore.
    func abortResolution(after failure: Error, picks: [String: ResolutionPick], root: String) throws {
        do {
            try gitService.abortRebase(at: root)
        } catch {
            guard case let SyncError.conflictFolderMustMove(path) = failure,
                  let pick = picks[path], pick.side == .thisMachine,
                  let entry = try gitService.conflictEntry(atStage: 3, path: path, in: root),
                  ["100644", "100755", "120000"].contains(entry.mode),
                  entry.mode == pick.expectedThisMode, entry.bytes == pick.expectedThis,
                  let full = validatedWorktreePath(path, root: root),
                  try fileService.entryTypeWithoutFollowingLinks(at: full) == .directory else { return }
            try fileService.deleteDirectory(at: full)
            try gitService.abortRebase(at: root)
        }
    }

}
