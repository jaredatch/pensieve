import os

enum AppSignal {
    static let launched = "app.launched"
    static let skillChangedExternally = "skill.changed_externally"
}

struct LaunchSignaler {
    private let sink: (String) -> Void

    init(sink: @escaping (String) -> Void = LaunchSignaler.osLogSink) {
        self.sink = sink
    }

    func signalLaunch() {
        sink(AppSignal.launched)
    }

    private static func osLogSink(_ signal: String) {
        os_log("%{public}@", log: .pensieveSignals, type: .info, signal)
    }
}

extension OSLog {
    static let pensieveSignals = OSLog(subsystem: "com.jaredatch.pensieve", category: "signals")
}
