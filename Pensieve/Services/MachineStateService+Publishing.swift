import Foundation
import SwiftData

extension MachineStateServicing {
    /// The production publication decision shared by resident sync and its fixed-point tests.
    @discardableResult
    func publishIfChanged(
        machineID: String,
        context: ModelContext,
        publishedAt: Date,
        root: String
    ) throws -> Bool {
        let state = try compose(machineID: machineID, context: context, publishedAt: publishedAt)
        let existing = readAll(fromRoot: root).first { $0.machineID == machineID }
        guard existing.map(state.contentEquals) != true else { return false }
        try write(state, toRoot: root)
        return true
    }
}
