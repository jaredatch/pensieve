import Observation
import SwiftUI
@testable import Pensieve

struct PreviewHostGeometry {
    var height: CGFloat = 480
    var chromeHeight: CGFloat?
}

@Observable
final class PreviewFileSelection {
    var file = "SKILL.md"
    var mode = SkillContentPresentation.Mode.rendered
}

struct PreviewContentHarness: View {
    let skill: Skill
    let snapshot: DetailContentSnapshot
    let library: SkillLibraryViewModel
    let selection: PreviewFileSelection
    let chromeHeight: CGFloat?
    let onSelectFile: (String) -> Void

    var body: some View {
        let presentation = SkillContentPresentation.resolve(selectedFile: selection.file, requestedMode: selection.mode,
                                                             inventory: snapshot.inventory)
        SkillDetailScrollLayout(skillID: skill.id,
                              contentOwnsScroller: DetailView.contentOwnsScroller(tab: .content, presentation: presentation)) {
            Text("Detail header").frame(height: chromeHeight)
        } tabContent: {
            SkillContentTab(skill: skill, snapshot: snapshot, library: library, presentation: presentation,
                            onSelectFile: onSelectFile, onSelectMode: { selection.mode = $0 })
        }
    }
}
