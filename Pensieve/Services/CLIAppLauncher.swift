import AppKit
import Darwin
import Foundation

protocol CLIAppLaunching {
    /// Nil means the requested app was started or was already running at that path.
    func launch(appPath: String, bundleID: String, deadline: TimeInterval) -> CLIReply?
}

/// LaunchServices is needed to start a resident GUI process without activating it. A launch never
/// carries an isolated home reliably, so reject redirected homes before consulting LaunchServices.
struct CLIAppLauncher: CLIAppLaunching {
    let fileService: FileServiceProtocol
    var desktopSession: CLIDesktopSessionReading = CLIDesktopSession()
    var environment = ProcessInfo.processInfo.environment

    func launch(appPath: String, bundleID: String, deadline: TimeInterval) -> CLIReply? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return unavailable("Unable to resolve this user's real home.", appPath: appPath)
        }
        let realHome = fileService.realPath(at: String(cString: home))
        let redirected = ["HOME", "CFFIXED_USER_HOME"].contains { key in
            guard let value = environment[key] else { return false }
            return value.isEmpty || fileService.realPath(at: value) != realHome
        }
        guard !redirected, !bundleID.hasSuffix(".dogfood"), environment["PENSIEVE_DOGFOOD"] != "1" else {
            return unavailable("Automatic launch is disabled for an isolated home or dogfood app.", appPath: appPath,
                hint: "Start the isolated app with script/dogfood.sh, then run its CLI through dogfood.sh --cli.")
        }
        let runningCopies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for running in runningCopies {
            guard let path = running.bundleURL?.path else {
                return unavailable("A running app's bundle path could not be checked.", appPath: appPath)
            }
            if fileService.realPath(at: path) != appPath { return wrongApp(path, expected: appPath) }
        }
        // Opening an already starting app sends a reopen event. Wait for its socket instead.
        if !runningCopies.isEmpty { return nil }
        do {
            guard try desktopSession.hasGraphicAccess() else {
                return .failure("no_desktop_session", "Pensieve needs a logged-in desktop session to start.",
                    hint: "Log in on this Mac and open Pensieve. Status, log and deployment list work without it.", exit: 3)
            }
        } catch { return unavailable(error.localizedDescription, appPath: appPath) }
        return launchUsingWorkspace(appPath: appPath, deadline: deadline)
    }

    private func launchUsingWorkspace(appPath: String, deadline: TimeInterval) -> CLIReply? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = [CLIProtocol.backgroundArgument]
        // Two CLI starts can race the running-copy check. Reusing the first process must not reopen its window.
        configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let completion = LaunchCompletion()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: configuration) { app, error in
            completion.path = app?.bundleURL?.path
            completion.error = error
            completion.finished.signal()
        }
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        guard completion.finished.wait(timeout: .now() + remaining) == .success else {
            return .failure("app_starting", "Pensieve has not finished starting.",
                hint: "Wait a moment, then run this command again.", exit: 3, retryable: true)
        }
        if let error = completion.error { return unavailable(error.localizedDescription, appPath: appPath) }
        guard let path = completion.path else { return unavailable("No app answered the launch.", appPath: appPath) }
        return fileService.realPath(at: path) == appPath ? nil : wrongApp(path, expected: appPath)
    }

    private func unavailable(_ message: String, appPath: String, hint: String? = nil) -> CLIReply {
        .failure("app_unavailable", message, hint: hint ?? "Open \(appPath), then run this command again.",
            exit: 3, retryable: true)
    }

    private func wrongApp(_ path: String, expected: String) -> CLIReply {
        .failure("wrong_app", "Another Pensieve copy is running: \(path)",
            hint: "Quit that copy and open \(expected).", exit: 3)
    }
}

/// The semaphore publishes callback fields; a timed-out caller never reads them.
private final class LaunchCompletion {
    let finished = DispatchSemaphore(value: 0)
    var path: String?
    var error: Error?
}
