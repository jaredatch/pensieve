import Foundation
@testable import Pensieve

extension AppRuntimePaths {
    /// A fresh store and App Support directory under the temp dir, both created, so nothing an
    /// `AppRuntime` resolves on its own can reach a real path (LOG 2026-09-10T00:30:33Z).
    static func temporary(named name: String) throws -> AppRuntimePaths {
        let sandbox = NSTemporaryDirectory() + "/\(name)-\(UUID().uuidString)"
        let paths = AppRuntimePaths(storeRoot: sandbox + "/store", appSupportDir: sandbox + "/appSupport")
        try FileManager.default.createDirectory(atPath: paths.storeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: paths.appSupportDir, withIntermediateDirectories: true)
        return paths
    }
}
