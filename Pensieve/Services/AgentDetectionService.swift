import Foundation

// MARK: - Environment Probe

/// The single seam tests replace. Every host-environment read AgentDetectionService makes
/// goes through this protocol: filesystem existence (delegated to FileService, the §2 boundary)
/// and CLI-on-PATH resolution (the only environment read).
protocol EnvironmentProbe {
    func directoryExists(at path: String) -> Bool
    func fileExists(at path: String) -> Bool
    func executableExists(named name: String) -> Bool
}

/// Production probe. Directory/file existence delegate to `FileServiceProtocol` (never raw
/// filesystem APIs); `executableExists` scans the injected PATH entries — the only environment read.
struct SystemEnvironmentProbe: EnvironmentProbe {
    private let fileService: FileServiceProtocol
    private let pathEntries: [String]

    init(fileService: FileServiceProtocol = FileService(), pathEntries: [String]? = nil) {
        self.fileService = fileService
        self.pathEntries = pathEntries
            ?? (ProcessInfo.processInfo.environment["PATH"]?
                .split(separator: ":")
                .map(String.init) ?? [])
    }

    func directoryExists(at path: String) -> Bool { fileService.directoryExists(at: path) }

    func fileExists(at path: String) -> Bool { fileService.fileExists(at: path) }

    func executableExists(named name: String) -> Bool {
        for dir in pathEntries where fileService.isExecutableFile(at: dir + "/" + name) {
            return true
        }
        return false
    }
}

// MARK: - Agent Detection

protocol AgentDetectionServiceProtocol {
    func isInstalled(_ platform: PlatformTarget) -> Bool
    func installedPlatforms() -> [PlatformTarget]
}

/// Reports, per `PlatformTarget`, whether that agent is actually installed on this machine,
/// so the UI can show only the agents the user has (ROADMAP §GOOD-2). An agent counts as
/// installed if ANY signal is present: its config dir, its app bundle, or its CLI on PATH.
struct AgentDetectionService: AgentDetectionServiceProtocol {
    private let probe: EnvironmentProbe
    private let home: String

    init(probe: EnvironmentProbe = SystemEnvironmentProbe(), homeDirectory: String) {
        self.probe = probe
        self.home = homeDirectory
    }

    func isInstalled(_ platform: PlatformTarget) -> Bool {
        switch platform {
        case .claudeCode:
            return probe.directoryExists(at: home + "/.claude")
                || probe.executableExists(named: "claude")
        case .grok:
            return probe.directoryExists(at: home + "/.grok")
                || probe.executableExists(named: "grok")
        case .codex:
            return probe.directoryExists(at: home + "/.codex")
                || probe.executableExists(named: "codex")
        case .openClaw:
            return probe.directoryExists(at: home + "/.openclaw")
                || probe.executableExists(named: "openclaw")
        case .hermes:
            return probe.directoryExists(at: home + "/.hermes")
                || probe.executableExists(named: "hermes")
        case .cursor:
            return probe.directoryExists(at: home + "/.cursor")
                || probe.directoryExists(at: "/Applications/Cursor.app")
                || probe.executableExists(named: "cursor")
        }
    }

    func installedPlatforms() -> [PlatformTarget] {
        PlatformTarget.allCases.filter(isInstalled)
    }

}
