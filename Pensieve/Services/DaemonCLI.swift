import Foundation

enum DaemonCommand: Equatable {
    case runCycle
    case status(json: Bool, appSupport: String?)
    case deployed(json: Bool, appSupport: String?)
    case log(lines: Int, appSupport: String?)
    case version
    case help
    case usageError(String)
}

struct CLIOutcome: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum DaemonCLI {
    static let daemonVersion = "0.4.0"
    static let defaultLogLines = 20

    static func parse(_ args: [String]) -> DaemonCommand {
        if args.contains("--version") {
            return .version
        }
        guard let command = args.first else {
            return .usageError("no command given; use `run` to sync")
        }

        switch command {
        case "run":
            guard args.count == 1 else {
                return .usageError("run does not accept arguments")
            }
            return .runCycle
        case "help", "--help", "-h":
            guard args.count == 1 else {
                return .usageError("\(command) does not accept arguments")
            }
            return .help
        case "status":
            return parseStatus(Array(args.dropFirst()))
        case "deployed":
            return parseDeployed(Array(args.dropFirst()))
        case "log":
            return parseLog(Array(args.dropFirst()))
        default:
            return .usageError("unknown command: \(command)")
        }
    }

    static func usage() -> String {
        """
        pensieve-daemon — Pensieve sync status + degraded SSH fallback

        The Pensieve app is the primary sync actor. Use `run` only as a degraded SSH path.

        USAGE:
          pensieve-daemon run                      run one degraded SSH sync cycle
          pensieve-daemon status [--json] [--app-support <dir>]
                                                   show the last cycle's result
          pensieve-daemon deployed [--json] [--app-support <dir>]
                                                   show recorded deployments on this machine
          pensieve-daemon log [--lines <n>] [--app-support <dir>]
                                                   show the last <n> daemon log lines (default 20)
          pensieve-daemon help                     show this help
          pensieve-daemon --version                print the version

        EXIT CODES:
          0   success (run: cycle synced or safely skipped; deployed: readable state)
          1   the cycle failed (run), or the last recorded cycle failed (status)
          2   no readable audit/deploy-state file: the daemon/app has not recorded it, or --app-support is wrong
          64  usage error
        """
        + "\n"
    }

    static func execute(
        _ args: [String],
        appSupport defaultDir: String,
        readFile: (String) -> Data?,
        runCycle: () -> DaemonCycleResult,
        now: () -> Date
    ) -> CLIOutcome {
        switch parse(args) {
        case .runCycle:
            let result = runCycle()
            return CLIOutcome(
                stdout: "pensieve-daemon \(result.category) \(DisplayTextSanitizer.singleLine(result.detail))\n",
                stderr: "",
                exitCode: result.exitCode
            )
        case .version:
            return CLIOutcome(stdout: "pensieve-daemon \(daemonVersion)\n", stderr: "", exitCode: 0)
        case .help:
            return CLIOutcome(stdout: usage(), stderr: "", exitCode: 0)
        case let .usageError(message):
            return CLIOutcome(stdout: "", stderr: "\(message)\n\n\(usage())", exitCode: 64)
        case let .status(json, appSupport):
            let dir = appSupport ?? defaultDir
            let path = "\(dir)/daemon-status.json"
            let rendered = renderStatus(
                data: readFile(path),
                path: path,
                json: json,
                now: now()
            )
            return CLIOutcome(
                stdout: rendered.isError ? "" : rendered.output,
                stderr: rendered.isError ? rendered.output : "",
                exitCode: rendered.exitCode
            )
        case let .deployed(json, appSupport):
            let dir = appSupport ?? defaultDir
            let path = "\(dir)/deploy-state.json"
            let rendered = renderDeployed(
                data: readFile(path),
                path: path,
                json: json
            )
            return CLIOutcome(
                stdout: rendered.isError ? "" : rendered.output,
                stderr: rendered.isError ? rendered.output : "",
                exitCode: rendered.exitCode
            )
        case let .log(lines, appSupport):
            return logOutcome(
                lines: lines,
                appSupport: appSupport,
                defaultDir: defaultDir,
                readFile: readFile
            )
        }
    }

    // swiftlint:disable large_tuple
    static func renderStatus(
        data: Data?,
        path: String,
        json: Bool,
        now: Date
    ) -> (output: String, isError: Bool, exitCode: Int32) {
        guard let data else {
            return (
                "no daemon status at \(path) — the daemon has not completed a cycle "
                    + "(is Background sync enabled in Settings → General?)\n",
                true,
                2
            )
        }

        // Strict UTF-8 up front: JSONDecoder auto-detects UTF-16/32, but the CLIOutcome String
        // seam can only carry UTF-8, so a non-UTF-8 file could never satisfy the --json
        // byte-verbatim contract — fail loud as unreadable (log's strict-UTF-8 contract, 15.3).
        guard let text = String(data: data, encoding: .utf8),
              let status = try? JSONDecoder().decode(DaemonStatus.self, from: data)
        else {
            return ("unreadable daemon status at \(path)\n", true, 2)
        }

        let exitCode: Int32 = status.result == "failed" ? 1 : 0
        if json {
            return (text, false, exitCode)
        }

        let age = statusAge(from: status.timestamp, now: now)
        let stale = age.map { $0 > 1_800 } ?? false
        let ageText = age.map { " (\(formatAge($0)) ago)" } ?? ""
        let staleText = stale ? " — stale: daemon may be disabled or the Mac was asleep" : ""
        let line = "last cycle \(status.timestamp)\(ageText): \(status.result) \(status.detail)\(staleText)"
        return (
            DisplayTextSanitizer.singleLine(line) + "\n",
            false,
            exitCode
        )
    }
    // swiftlint:enable large_tuple

    // swiftlint:disable large_tuple
    static func renderLog(
        current: String?,
        rotated: String?,
        lines: Int
    ) -> (output: String, isError: Bool, exitCode: Int32) {
        renderLog(current: current, rotated: rotated, lines: lines, missingPath: "daemon.log")
    }
    // swiftlint:enable large_tuple
}

private extension DaemonCLI {
    private static func parseStatus(_ args: [String]) -> DaemonCommand {
        var json = false
        var appSupport: String?
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
                index += 1
            case "--app-support":
                guard let value = value(after: index, in: args) else {
                    return .usageError("--app-support requires a value")
                }
                appSupport = value
                index += 2
            default:
                return .usageError("unknown flag for status: \(args[index])")
            }
        }

        return .status(json: json, appSupport: appSupport)
    }

    private static func parseLog(_ args: [String]) -> DaemonCommand {
        var lines = defaultLogLines
        var appSupport: String?
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--lines":
                guard let value = value(after: index, in: args),
                      let parsed = Int(value),
                      parsed > 0
                else {
                    return .usageError("--lines requires a positive integer")
                }
                lines = parsed
                index += 2
            case "--app-support":
                guard let value = value(after: index, in: args) else {
                    return .usageError("--app-support requires a value")
                }
                appSupport = value
                index += 2
            default:
                return .usageError("unknown flag for log: \(args[index])")
            }
        }

        return .log(lines: lines, appSupport: appSupport)
    }

    private static func value(after index: Int, in args: [String]) -> String? {
        let valueIndex = index + 1
        guard valueIndex < args.count else { return nil }
        let value = args[valueIndex]
        guard !value.hasPrefix("--") else { return nil }
        return value
    }

    static func logOutcome(
        lines: Int,
        appSupport: String?,
        defaultDir: String,
        readFile: (String) -> Data?
    ) -> CLIOutcome {
        let dir = appSupport ?? defaultDir
        let currentPath = "\(dir)/daemon.log"
        let rotatedPath = "\(dir)/daemon.log.1"
        let currentData = readFile(currentPath)
        let rotatedData = readFile(rotatedPath)

        guard let current = decodedLog(currentData) else {
            return CLIOutcome(
                stdout: "",
                stderr: "unreadable daemon log at \(currentPath)\n",
                exitCode: 2
            )
        }
        guard let rotated = decodedLog(rotatedData) else {
            return CLIOutcome(
                stdout: "",
                stderr: "unreadable daemon log at \(rotatedPath)\n",
                exitCode: 2
            )
        }

        let rendered = renderLog(
            current: current,
            rotated: rotated,
            lines: lines,
            missingPath: currentPath
        )
        return CLIOutcome(
            stdout: rendered.isError ? "" : rendered.output,
            stderr: rendered.isError ? rendered.output : "",
            exitCode: rendered.exitCode
        )
    }

    private static func decodedLog(_ data: Data?) -> String?? {
        guard let data else { return .some(nil) }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return .some(text)
    }

    // swiftlint:disable large_tuple
    private static func renderLog(
        current: String?,
        rotated: String?,
        lines: Int,
        missingPath: String
    ) -> (output: String, isError: Bool, exitCode: Int32) {
        guard current != nil || rotated != nil else {
            return ("no daemon log at \(missingPath)\n", true, 2)
        }

        let allLines = logLines(from: rotated) + logLines(from: current)
        let selectedLines = allLines.suffix(lines)
        guard !selectedLines.isEmpty else {
            return ("", false, 0)
        }

        return (selectedLines.map(DisplayTextSanitizer.logLine).joined(separator: "\n") + "\n", false, 0)
    }
    // swiftlint:enable large_tuple

    private static func logLines(from text: String?) -> [String] {
        guard let text else { return [] }
        var components = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if components.last == "" {
            components.removeLast()
        }
        return components
    }

    private static func statusAge(from timestamp: String, now: Date) -> TimeInterval? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: timestamp) else { return nil }
        let age = now.timeIntervalSince(date)
        guard age >= 0 else { return nil }
        return age
    }

    private static func formatAge(_ age: TimeInterval) -> String {
        if age < 90 {
            return "\(Int(age))s"
        }
        if age < 90 * 60 {
            return "\(Int(age / 60))m"
        }
        return "\(Int(age / 3_600))h"
    }
}

private extension DaemonCycleResult {
    var exitCode: Int32 {
        switch self {
        case .synced, .skipped:
            return 0
        case .failed:
            return 1
        }
    }
}
