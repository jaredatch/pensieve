import Foundation
import Observation

/// Process-owned reservations outlive either presentation. Release only after the apply worker returns.
@MainActor
@Observable
final class SkillUpdateApplyGate {
    private var skillIDs: Set<UUID> = []
    private weak var library: SkillLibraryViewModel?

    func bind(library: SkillLibraryViewModel) { self.library = library }
    func isApplying(_ skillID: UUID) -> Bool { skillIDs.contains(skillID) }

    func begin(_ skillID: UUID) -> Bool {
        skillIDs.insert(skillID).inserted
    }

    func end(_ skillID: UUID) { skillIDs.remove(skillID) }
    func invalidateEditorBody() { library?.noteEditorBodyInvalidated() }
}
