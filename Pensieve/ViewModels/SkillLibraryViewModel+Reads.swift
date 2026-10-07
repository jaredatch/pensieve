import Foundation

extension SkillLibraryViewModel {
    func readSkillDocument(_ skill: Skill) -> String? {
        try? skillStore.readBody(directoryName: skill.directoryName)
    }

    func readBody(_ skill: Skill) -> String {
        guard let raw = readSkillDocument(skill) else { return "" }
        return SkillParser.stripFrontmatter(raw)
    }

    /// Reads the on-disk body the SAME way the editor sees it (stripped of frontmatter), so the
    /// comparison against the `lastWrittenBody` fingerprint is apples-to-apples.
    func currentOnDiskBody(directoryName: String) -> String {
        guard let raw = try? skillStore.readBody(directoryName: directoryName) else { return "" }
        return SkillParser.stripFrontmatter(raw)
    }

    func estimatedTokens(_ skill: Skill) -> Int {
        TokenCounter.estimate(readBody(skill))
    }

    func noteAppAuthoredBody(_ skill: Skill, body: String) {
        withFingerprintLock {
            lastWrittenBody[skill.directoryName] = body
            pendingAppWrittenBody[skill.directoryName] = nil
        }
        publishAppWriteRevision()
    }

    func noteAppAuthoredBodies(directoryNames: [String]) {
        for directoryName in directoryNames {
            finishAppAuthoredBodyWrite(directoryName: directoryName)
        }
    }

    func beginAppAuthoredBodyWrite(directoryName: String, expectedBody: String) {
        withFingerprintLock {
            pendingAppWrittenBody[directoryName] = expectedBody
        }
    }

    func finishAppAuthoredBodyWrite(directoryName: String, succeeded: Bool = true) {
        // Failed replacement: the app changed nothing on disk, so adopt no fingerprint —
        // the previous one stays valid, and a racing external edit stays classifiable.
        guard succeeded else {
            withFingerprintLock { pendingAppWrittenBody[directoryName] = nil }
            return
        }
        let currentBody = currentOnDiskBody(directoryName: directoryName)
        withFingerprintLock {
            // Record what the app wrote (the pending expected body), not what the disk
            // holds now: an external editor racing in between the write and this
            // finalizer must stay classifiable when its delayed watcher event arrives.
            // Without a bracket (import-style registration after the fact), fall back
            // to the disk body.
            lastWrittenBody[directoryName] = pendingAppWrittenBody[directoryName] ?? currentBody
            pendingAppWrittenBody[directoryName] = nil
        }
        publishAppWriteRevision()
    }

    func setLastWrittenBody(_ body: String, directoryName: String) {
        withFingerprintLock {
            lastWrittenBody[directoryName] = body
            pendingAppWrittenBody[directoryName] = nil
        }
    }

    func wasLastWrittenByApp(directoryName: String, currentBody: String) -> Bool {
        withFingerprintLock {
            Self.bodiesMatch(currentBody, lastWrittenBody[directoryName])
                || Self.bodiesMatch(currentBody, pendingAppWrittenBody[directoryName])
        }
    }

    /// Editors use LF even for CRLF files. Drafts and watcher echoes compare with this same rule.
    static func bodiesMatch(_ body: String, _ baseline: String?) -> Bool {
        guard let baseline else { return false }
        return SkillSerializer.comparableBody(body) == SkillSerializer.comparableBody(baseline)
    }

    func withFingerprintLock<Result>(_ body: () -> Result) -> Result {
        fingerprintLock.lock()
        defer { fingerprintLock.unlock() }
        return body()
    }

    func notifySyncedStateMutation() {
        notifier()
    }

}
