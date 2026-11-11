import XCTest
@testable import Pensieve

final class WrappedFileServiceTemporaryTests: XCTestCase {
    func testManifestPublicationThroughWrappersRemovesEmptyNamespace() throws {
        let files = FileService()
        let base = TestTemporaryDirectory.path + "WrappedTemporaryFolders-" + UUID().uuidString
        try files.createDirectory(at: base)
        defer { try? files.deleteDirectory(at: base) }
        let wrappers: [(String, FileServiceProtocol)] = [
            ("ImportReadSpy", ImportReadSpy(files: files)),
            ("FaultyFileService", FaultyFileService(wrapped: files)),
            ("CLIProjectFileService", CLIProjectFileService()),
            ("StoreDirectorySwapFileService", StoreDirectorySwapFileService(
                wrapped: files, directory: base + "/unused", outsideDirectory: base + "/outside"))
        ]
        for (name, wrapper) in wrappers {
            let root = base + "/" + name
            try files.createDirectory(at: root)
            // The production temporary parent is outside the test root; clean any failed assertion's leftovers.
            let namespace = try VendorTemporaryDirectory.namespace(storeRoot: root, fileService: files).parent
            defer { try? files.deleteDirectory(at: namespace) }
            let manifest = ManifestService(fileService: wrapper)
            let snapshot = ManifestSnapshot(schemaVersion: 5,
                categories: [CategoryRecord(name: "Saved category", projectKeys: [], skillSlugs: [])],
                projects: [], skills: [])
            try manifest.write(snapshot, toRoot: root)
            XCTAssertEqual(try ManifestService(fileService: files).read(fromRoot: root).categories.map(\.name),
                           ["Saved category"], name)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: namespace), name)
        }
        // Handoff overlays test fixtures onto the base, including their forwarding repairs.
        // Pair the publication assertions with the production contract that prevents future omissions.
        try NativeTestWork.run { try self.assertCleanupMustBeExplicit(directory: base) }
    }

    private func assertCleanupMustBeExplicit(directory: String) throws {
        for explicit in [true, false] {
            let cleanup = explicit ? "func removeEmptyDirectory(at path: String) throws {}" : ""
            let source = directory + "/cleanup-conformance.swift"
            try FileService().writeFile(at: source, content: """
                import Foundation
                @testable import Pensieve
                struct CleanupConformanceProbe: FileServiceProtocol {
                    func readFile(at path: String) throws -> String { "" }
                    func writeFile(at path: String, content: String) throws {}
                    func deleteFile(at path: String) throws {}
                    func fileExists(at path: String) -> Bool { false }
                    func isExecutableFile(at path: String) -> Bool { false }
                    func directoryExists(at path: String) -> Bool { false }
                    func createDirectory(at path: String) throws {}
                    func deleteDirectory(at path: String) throws {}
                    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
                    func symlinkTarget(at path: String) throws -> String { "" }
                    func isSymlink(at path: String) -> Bool { false }
                    func listDirectory(at path: String) throws -> [String] { [] }
                    func contentsHash(at path: String) throws -> String { "" }
                    \(cleanup)
                }
                """)
            let (status, diagnostics) = try typecheck(source)
            if explicit {
                XCTAssertEqual(status, 0, "Explicit cleanup must satisfy the protocol: " + diagnostics)
            } else {
                XCTAssertNotEqual(status, 0, "A file service must explicitly choose its cleanup behavior")
                XCTAssertTrue(diagnostics.contains("removeEmptyDirectory"), diagnostics)
            }
        }
    }

    private func typecheck(_ source: String) throws -> (Int32, String) {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let derived = checkout + "/DerivedData"
        let products = derived + "/Build/Products/Debug"
        let deployment = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String)
        #if arch(arm64)
        let target = "arm64-apple-macos" + deployment
        #else
        let target = "x86_64-apple-macos" + deployment
        #endif
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", "-target", target, "-I", products, "-F", products,
            "-F", derived + "/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64",
            "-I", derived + "/SourcePackages/checkouts/Yams/Sources/CYaml/include", source]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? "Invalid compiler output"
        process.waitUntilExit()
        return (process.terminationStatus, diagnostics)
    }
}
