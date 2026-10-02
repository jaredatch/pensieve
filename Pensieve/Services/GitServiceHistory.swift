import Foundation

extension GitService {
    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] {
        (try? logResult(forPath: path, at: workingDir, limit: limit)) ?? []
    }

    /// Throwing seam for tests: command failure is distinct from genuinely empty history.
    func logResult(forPath path: String, at workingDir: String, limit: Int) throws -> [GitCommit] {
        let format = "%H%x1f%an%x1f%aI%x1f%s"
        let args = ["-C", workingDir, "log", "-n", "\(limit)", "--format=\(format)", "--", path]
        let result = try run(args, in: nil)
        guard result.exit == 0 else {
            throw GitError.commandFailed(
                args: ["log"],
                exitCode: result.exit,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr, confirmingProbe: result.confirmingProbe)
        }
        return result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 4, let date = Self.isoDate(fields[2]) else { return nil }
            return GitCommit(sha: fields[0], author: fields[1], date: date, subject: fields[3])
        }
    }

    func show(sha: String, path: String, at workingDir: String) -> String? {
        guard let result = try? run(["-C", workingDir, "show", "\(sha):\(path)"], in: nil),
              result.exit == 0 else {
            return nil
        }
        return result.stdout
    }

    static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
