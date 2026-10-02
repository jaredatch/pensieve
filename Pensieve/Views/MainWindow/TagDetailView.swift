import Foundation
import SwiftUI

struct TagDetailView: View {
    let tag: String
    let skills: [Skill]
    let onReveal: (Skill) -> Void

    private var relatedSkills: [Skill] {
        RelatedSkills.forTag(tag, in: skills).relatedSkillsOrdered()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(tag)
                        .font(.title2)
                    Text(relatedSkills.count == 1 ? "1 skill" : "\(relatedSkills.count) skills")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Skills") {
                if relatedSkills.isEmpty {
                    Text("No skills")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relatedSkills) { skill in
                        Button(action: { onReveal(skill) }, label: {
                            Label(skill.name, systemImage: "doc.text")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        })
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(tag)
    }
}
