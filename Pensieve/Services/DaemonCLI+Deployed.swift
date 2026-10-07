import Foundation

extension DaemonCLI {
    static func parseDeployed(_ args: [String]) -> DaemonCommand {
        var json = false
        var appSupport: String?
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
                index += 1
            case "--app-support":
                guard let value = deployedValue(after: index, in: args) else {
                    return .usageError("--app-support requires a value")
                }
                appSupport = value
                index += 2
            default:
                return .usageError("unknown flag for deployed: \(args[index])")
            }
        }

        return .deployed(json: json, appSupport: appSupport)
    }

    // swiftlint:disable large_tuple
    static func renderDeployed(
        data: Data?,
        path: String,
        json: Bool
    ) -> (output: String, isError: Bool, exitCode: Int32) {
        guard let data else {
            return (
                "no deploy state at \(path) — nothing recorded yet "
                    + "(deploy something in Pensieve first, or check --app-support)\n",
                true,
                2
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return ("unreadable deploy state at \(path)\n", true, 2)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let state = try? decoder.decode(DeployState.self, from: data),
              state.schemaVersion <= DeployStateStore.currentSchemaVersion
        else {
            return ("unreadable deploy state at \(path)\n", true, 2)
        }

        if json {
            return (text, false, 0)
        }

        let records = state.records.sorted { lhs, rhs in
            if lhs.artifactPath != rhs.artifactPath { return lhs.artifactPath < rhs.artifactPath }
            return lhs.recordedAt < rhs.recordedAt
        }
        guard !records.isEmpty else {
            return ("no deployments recorded\n", false, 0)
        }

        let lines = records.map { record in
            let scope = renderedScope(for: record)
            return "\(record.slug)\t\(record.platform)\t\(scope)\t\(record.artifactPath)"
        }
        return (lines.joined(separator: "\n") + "\n", false, 0)
    }
    // swiftlint:enable large_tuple
}

private func renderedScope(for record: DeployStateRecord) -> String {
    if record.scope == "project" {
        return "project:\(record.projectReference)"
    }
    return "user"
}

private func deployedValue(after index: Int, in args: [String]) -> String? {
    let valueIndex = index + 1
    guard valueIndex < args.count else { return nil }
    let value = args[valueIndex]
    guard !value.hasPrefix("--") else { return nil }
    return value
}
