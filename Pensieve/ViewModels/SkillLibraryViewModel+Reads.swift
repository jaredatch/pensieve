import Foundation

extension SkillLibraryViewModel {
    func readSkillDocument(_ skill: Skill) -> String? {
        try? skillStore.readBody(directoryName: skill.directoryName)
    }

    func readBody(_ skill: Skill) -> String {
        guard let raw = readSkillDocument(skill) else { return "" }
        return SkillParser.stripFrontmatter(raw)
    }

    /// Reads the complete on-disk document the same way the editor sees it, so the
    /// comparison against the `lastWrittenBody` fingerprint is apples-to-apples.
    func currentOnDiskBody(directoryName: String) -> String {
        guard let raw = try? skillStore.readBody(directoryName: directoryName) else { return "" }
        return raw
    }

    func estimatedTokens(_ skill: Skill) -> Int {
        TokenCounter.estimate(readBody(skill))
    }

    func noteAppAuthoredBody(_ skill: Skill, body: String) {
        withFingerprintLock {
            lastWrittenBody[skill.directoryName] = body
            pendingAppWrittenBody[skill.directoryName] = nil
            registeredAppWriteSlugs.insert(skill.directoryName)
        }
        publishAppWriteRevision()
    }

    func noteAppAuthoredBodies(directoryNames: [String]) {
        for directoryName in directoryNames {
            guard !withFingerprintLock({ registeredAppWriteSlugs.contains(directoryName) }) else { continue }
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
            // Record what the app wrote (the pending expected document), not what the disk
            // holds now: an external editor racing in between the write and this
            // finalizer must stay classifiable when its delayed watcher event arrives.
            // Legacy callers without a bracket register the disk document after the fact.
            lastWrittenBody[directoryName] = pendingAppWrittenBody[directoryName] ?? currentBody
            registeredAppWriteSlugs.insert(directoryName)
            pendingAppWrittenBody[directoryName] = nil
        }
        publishAppWriteRevision()
    }

    func setLastWrittenBody(_ body: String, directoryName: String) {
        // A disk observation cannot retire a replacement still in flight.
        withFingerprintLock { lastWrittenBody[directoryName] = body }
    }

    func wasLastWrittenByApp(directoryName: String, currentBody: String) -> Bool {
        withFingerprintLock {
            Self.bodiesMatch(currentBody, lastWrittenBody[directoryName])
                || Self.bodiesMatch(currentBody, pendingAppWrittenBody[directoryName])
        }
    }

    /// The legacy Body names now carry complete documents. Editors normalize CR/LF transport only;
    /// boundary newlines and Unicode spelling remain significant for drafts and watcher echoes.
    static func bodiesMatch(_ body: String, _ baseline: String?) -> Bool {
        guard let baseline else { return false }
        return SkillDocumentEditing.matches(body, baseline)
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
