import Foundation
import XCTest
@testable import Pensieve

@MainActor
final class MachineStateWriterSweepTests: XCTestCase {
    private let fileService = FileService()
    private let machineID = "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002"
    private var tempDir = ""

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachineStateWriterSweepTests-\(UUID().uuidString)").path
        try fileService.createDirectory(at: tempDir)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? fileService.deleteDirectory(at: tempDir) }
    }

    func testGeneratedMachineStateWriterSweep() throws {
        var index = 0
        try assertFixedPoint([], index: &index)
        for name in specialValues {
            for path in publishedPaths {
                let project = MachineStateProject(
                    identityKey: "key-\(index)", kind: "git-remote", name: name, path: path
                )
                try assertFixedPoint([project], index: &index)
                try assertFixedPoint([
                    MachineStateProject(identityKey: "anchor-\(index)", kind: "marker", name: "Anchor",
                                        path: "~/Nested/Anchor"),
                    project
                ], index: &index)
            }
        }
    }

    func testEverySerializedStringFieldRoundTripsControls() throws {
        var index = 10_000
        for value in controlValues {
            let state = MachineState(
                schemaVersion: 1,
                machineID: machineID,
                name: "machine-" + value,
                appVersion: "version-" + value,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                agents: ["agent-" + value],
                projects: [MachineStateProject(
                    identityKey: "identity-" + value,
                    kind: "kind-" + value,
                    name: "name-" + value,
                    path: "~/path-" + value
                )],
                userDeploys: [MachineStateUserDeploy(slug: "user-slug-" + value,
                                                     platform: "user-platform-" + value)],
                projectDeploys: [MachineStateProjectDeploy(
                    slug: "project-slug-" + value,
                    platform: "project-platform-" + value,
                    projectKey: "project-key-" + value
                )]
            )
            try assertFixedPoint(state, index: &index)
        }
    }

    func testTargetScaleMachineStateWriterReadsBackIdentically() throws {
        let platforms = PlatformTarget.allCases
        let projectPlatforms = platforms.filter(\.supportsProjectScope)
        XCTAssertFalse(projectPlatforms.isEmpty)

        let skillCount = 5_000
        let projects = (0..<500).map { index in
            MachineStateProject(
                identityKey: "project-\(index)", kind: "git-remote", name: "Project \(index)"
            )
        }
        let userDeploys = (0..<skillCount).flatMap { skill in
            platforms.map { platform in
                MachineStateUserDeploy(slug: "skill-\(skill)", platform: platform.rawValue)
            }
        }
        let projectDeploys = (0..<20_000).map { index in
            let platformIndex = index % projectPlatforms.count
            let projectIndex = (index / projectPlatforms.count) % projects.count
            let skillIndex = (index / (projectPlatforms.count * projects.count)) % skillCount
            return MachineStateProjectDeploy(
                slug: "skill-\(skillIndex)",
                platform: projectPlatforms[platformIndex].rawValue,
                projectKey: projects[projectIndex].identityKey
            )
        }
        XCTAssertEqual(projectDeploys.count, 20_000)
        XCTAssertEqual(Set(projectDeploys.map {
            "\($0.slug)\u{0}\($0.platform)\u{0}\($0.projectKey)"
        }).count, projectDeploys.count)
        XCTAssertEqual(Set(projectDeploys.map(\.platform)), Set(projectPlatforms.map(\.rawValue)))
        XCTAssertEqual(Set(projectDeploys.map(\.projectKey)).count, projects.count)

        let state = MachineState(
            schemaVersion: 1,
            machineID: machineID,
            name: "Target Scale Mac",
            appVersion: "0.13.0",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            agents: platforms.map(\.rawValue),
            projects: projects,
            userDeploys: userDeploys,
            projectDeploys: projectDeploys
        )
        try service.write(state, toRoot: tempDir)
        XCTAssertEqual(service.readAll(fromRoot: tempDir), [state])
    }

    private func assertFixedPoint(_ projects: [MachineStateProject], index: inout Int) throws {
        try assertFixedPoint(MachineState(
            schemaVersion: 1,
            machineID: machineID,
            name: "Sweep Mac",
            appVersion: "0.13.0",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            agents: ["claudeCode"],
            projects: projects,
            userDeploys: [],
            projectDeploys: []
        ), index: &index)
    }

    private func assertFixedPoint(_ state: MachineState, index: inout Int) throws {
        let first = tempDir + "/first"
        let second = tempDir + "/second"
        try service.write(state, toRoot: first)
        let parsed = try XCTUnwrap(service.readAll(fromRoot: first).first)
        XCTAssertEqual(parsed, state, "shape \(index)")
        try service.write(parsed, toRoot: second)
        XCTAssertEqual(try fileService.readData(at: statePath(first)),
                       try fileService.readData(at: statePath(second)), "shape \(index)")
        index += 1
    }

    private var service: MachineStateService {
        MachineStateService(fileService: fileService, agentDetection: EmptyMachineDetection(), warn: { _ in })
    }

    private func statePath(_ root: String) -> String { root + "/machines/" + machineID + ".yaml" }

    private var publishedPaths: [String?] {
        [nil, "~"] + specialValues.map { "~/" + $0 } + ["~/Nested/One/Two"]
    }

    private var specialValues: [String] {
        [
            "'", "\"", "\\", ":", "#", "-first", "{", "}", "[", "]", ",", "&", "*", "!", "%", "@",
            "space name", "null", "123", "élan", "😀", "e\u{301}"
        ]
            + controlValues
    }

    private var controlValues: [String] {
        [
            "\u{7F}", "\u{80}", "\u{85}", "\u{FFFE}", "\u{FFFF}", "\u{2028}",
            "\t", "\n", "\u{202E}"
        ]
    }
}
