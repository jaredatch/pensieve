import AppKit
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class CLIReadHandlerTests: XCTestCase {
    func testReadCommandsReflectCurrentModelsAndOnlyReadContentOnRequest() throws {
        let directory = try SocketTestDirectory()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let skill = Skill(name: "Review", skillDescription: "Check a change", tags: ["code"], directoryName: "review")
        let project = Project(name: "App", path: directory.path + "/app")
        context.insert(skill)
        context.insert(project)
        try context.save()
        let paths = AppRuntimePaths(storeRoot: directory.path + "/store", appSupportDir: directory.path + "/support")
        let store = SkillStore(fileService: directory.files, baseDir: paths.skillsDir, storeRoot: paths.storeRoot)
        let machines = paths.makeMachineStateService(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let handler = CLIReadHandler(store: store, installedAgents: { [] },
            machines: machines, storeRoot: paths.storeRoot)
        let shown = handler.handle(CLIRequest(command: "skill show", arguments: ["review"]), context: context)
        XCTAssertTrue(shown.envelope.ok, "Metadata succeeds even when content is missing")
        XCTAssertEqual(shown.envelope.data, .object([
            "slug": .string("review"), "name": .string("Review"), "description": .string("Check a change"),
            "tags": .array([.string("code")])]))
        let body = "Untrusted instructions\n"
        try directory.files.writeFile(at: paths.skillsDir + "/review/SKILL.md", content: body)
        let content = handler.handle(CLIRequest(command: "skill show", arguments: ["review"], content: true), context: context)
        guard case let .object(fields) = content.envelope.data else { return XCTFail("Missing skill") }
        XCTAssertEqual(fields["content"], .string(body))
        skill.name = "Changed in window"
        let list = handler.handle(CLIRequest(command: "skill list"), context: context)
        guard case let .array(rows) = list.envelope.data, case let .object(row) = rows.first else {
            return XCTFail("Missing library rows")
        }
        XCTAssertEqual(row["name"], .string("Changed in window"))
        try assertLists(handler: handler, context: context, project: project, machines: machines, paths: paths)
        let missing = handler.handle(CLIRequest(command: "skill show", arguments: ["absent"]), context: context)
        XCTAssertEqual(missing.exitCode, 4)
        XCTAssertEqual(missing.envelope.error?.code, "skill_not_found")
    }

    private func assertLists(handler: CLIReadHandler, context: ModelContext, project: Project,
                             machines: MachineStateService, paths: AppRuntimePaths) throws {
        let projects = handler.handle(CLIRequest(command: "project list"), context: context)
        guard case let .array(projectRows) = projects.envelope.data, case let .object(projectRow) = projectRows.first else {
            return XCTFail("Missing projects")
        }
        XCTAssertEqual(projectRow["path"], .string(project.path))
        let agents = handler.handle(CLIRequest(command: "agent list"), context: context)
        guard case let .array(agentRows) = agents.envelope.data else { return XCTFail("Missing agents") }
        XCTAssertEqual(agentRows.count, 6)
        XCTAssertTrue(agentRows.contains { value in
            guard case let .object(fields) = value else { return false }
            return fields["id"] == .string("claude") && fields["installed"] == .bool(false)
        })
        let machine = MachineState(schemaVersion: 1, machineID: UUID().uuidString, name: "Mini", appVersion: "1.2.3",
            publishedAt: Date(), agents: ["claudeCode"], projects: [], userDeploys: [], projectDeploys: [])
        try machines.write(machine, toRoot: paths.storeRoot)
        let machineList = handler.handle(CLIRequest(command: "machine list"), context: context)
        XCTAssertEqual(machineList.envelope.data, .array([.object([
            "id": .string(machine.machineID), "name": .string("Mini"), "agents": .array([.string("claude")])])]))
    }

    func testRuntimeListensBeforeLaunchWorkAndOverlongPathKeepsRuntimeAlive() async throws {
        let directory = try SocketTestDirectory()
        let paths = AppRuntimePaths(storeRoot: directory.path + "/store", appSupportDir: directory.path)
        let runtime = try AppRuntime(scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            paths: paths, gitUsabilityProbe: { .usable })
        await runtime.bootstrapTask.value
        runtime.container.mainContext.insert(Skill(name: "Runtime skill", directoryName: "runtime-skill"))
        defer { runtime.commandServer?.stop() }
        XCTAssertFalse(runtime.launchWorkCompleted)
        XCTAssertNotNil(runtime.commandServer)
        XCTAssertNil(runtime.commandServerError)
        let socket = CLIProtocol.socketPath(appSupport: directory.path,
            bundleID: Bundle.main.bundleIdentifier ?? "com.jaredatch.Pensieve")
        runtime.start()
        let response = try await BlockingWork.run {
            let client = try SocketTransport.connect(to: socket)
            defer { close(client) }
            _ = try SocketTransport.readFrame(client, limit: 1_024, timeout: TestWait.hostedActionTimeoutSeconds)
            try SocketTransport.writeFrame(CLIRequest(command: "skill list"), to: client,
                timeout: TestWait.hostedActionTimeoutSeconds)
            return try JSONDecoder().decode(CLIReply.self, from: SocketTransport.readFrame(client,
                limit: CLIProtocol.replyLimit, timeout: TestWait.hostedActionTimeoutSeconds))
        }
        XCTAssertEqual(response.envelope.data, .array([.object([
            "slug": .string("runtime-skill"), "name": .string("Runtime skill"), "description": .string(""),
            "tags": .array([])])]))
        let longPaths = AppRuntimePaths(storeRoot: directory.path + "/store2",
            appSupportDir: directory.path + "/" + String(repeating: "x", count: 104))
        let longRuntime = try AppRuntime(scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            paths: longPaths, gitUsabilityProbe: { .usable })
        await longRuntime.bootstrapTask.value
        XCTAssertNil(longRuntime.commandServer)
        XCTAssertTrue(try XCTUnwrap(longRuntime.commandServerError).contains(longPaths.appSupportDir))
        let delegate = try XCTUnwrap(PensieveAppDelegate.shared)
        let previousRuntime = delegate.runtime
        defer { delegate.runtime = previousRuntime }
        delegate.runtime = runtime
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(try directory.files.entryExistsWithoutFollowingLinks(at: socket))
    }
}
