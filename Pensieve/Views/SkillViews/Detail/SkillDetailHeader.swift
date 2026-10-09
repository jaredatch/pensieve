import SwiftUI

/// Above the tabs on every tab (the master `Detail header / v2`, 644 wide): the title, the provenance line
/// of a linked skill (the git-branch icon, owner/repo, the tracked ref), the description with an App Store
/// "more" past two lines, the tags field, and the status labels the editor's header used to carry. Insets
/// 16 top, sides and below; rows on an 8 pt gap.
/// The status labels carry the retired provenance section's three — the local-edit note, a failed check's
/// error, a drift error — beside the library's; "An update is available" is the banner's.
struct SkillDetailHeader: View {
    let skill: Skill
    let provenance: SkillProvenance?
    let tagsInUse: [String]
    let syncModel: SyncModel
    let driftError: String?
    let isChecking: Bool
    @Bindable var library: SkillLibraryViewModel
    let onResolve: () -> Void
    let onCommitTags: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(skill.name)
                .font(DesignTokens.detailTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let provenance, let repo = SkillDetailHeaderPresentation.repositoryPath(provenance) {
                provenanceLine(repo: repo, ref: provenance.trackedRef)
            }
            if !skill.skillDescription.isEmpty {
                SkillDescriptionText(text: skill.skillDescription)
                    .id(skill.id)
            }
            TagTokenField(tokens: skill.tags, tagsInUse: tagsInUse, onCommit: onCommitTags)
                .id(skill.id)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusLabels
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .padding(.bottom, DesignTokens.headerBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func provenanceLine(repo: String, ref: String?) -> some View {
        HStack(spacing: 6) {
            Image("git-branch")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(repo)
                .font(DesignTokens.provenance)
                .foregroundStyle(.secondary)
            if let ref {
                Text("·")
                    .font(DesignTokens.provenanceDot)
                    .foregroundStyle(.secondary)
                Text(ref)
                    .font(DesignTokens.provenanceMono)
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .frame(height: DesignTokens.provenanceLineHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusLabels: some View {
        if let error = library.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let note = provenance?.localEditNote {
            Label(note, systemImage: "pencil.line")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        switch SkillDetailHeaderPresentation.checkLine(isChecking: isChecking, checkError: provenance?.checkError) {
        case .checking?:
            Label {
                Text("Checking for updates…")
            } icon: {
                ProgressView().controlSize(.mini)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .failed(error)?:
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
        if let error = driftError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if library.externallyModified.contains(skill.directoryName) {
            Label(library.hasUnsavedChanges(for: skill)
                      ? "Modified externally — Save overwrites it" : "Modified externally — reloaded",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if syncModel.state == .branchless {
            Label(SyncFooterPresentation.branchlessMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if syncModel.conflictedSlugs.contains(skill.directoryName) {
            HStack(spacing: Spacing.sm) {
                Label("Sync conflict — resolve to continue", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Resolve…", action: onResolve)
                    .controlSize(.small)
                    .disabled(!syncModel.canResolve)
            }
        }
    }
}

enum SkillDetailHeaderPresentation {
    enum CheckLine: Equatable {
        case checking
        case failed(String)
    }

    /// The header's update-check line: "Checking for updates…" while a check runs — it replaces the last
    /// check's error until the answer comes — else that error, if any.
    static func checkLine(isChecking: Bool, checkError: String?) -> CheckLine? {
        if isChecking { return .checking }
        return checkError.map { .failed($0) }
    }

    /// "owner/repo" from the provenance's repository URL; nil for an unlinked skill.
    static func repositoryPath(_ provenance: SkillProvenance) -> String? {
        guard let url = provenance.repositoryURL else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }
}

/// The description on two lines with a fade and `more` (App Store's shape). Collapsed, the text sits in
/// a frame exactly two lines tall (measured from `Text("X\nX")` in the same font) and is clipped — no
/// ellipsis — with the fade and `more` overlaid at the trailing end. That bounded collapsed frame keeps
/// PLAN-26's split-view overflow class from returning. Expanded, the width-bounded text takes its full
/// natural height inside the detail column's scroll view. The caller keys the instance by the skill
/// (`.id(skill.id)`), so another skill starts collapsed.
struct SkillDescriptionText: View {
    let text: String
    @State private var expanded: Bool
    @State private var twoLineHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// Two lines of `.body` until the measurement lands (never nil: the frame must stay bounded).
    private static let fallbackTwoLines: CGFloat = 32

    private var collapsedHeight: CGFloat { twoLineHeight > 0 ? twoLineHeight : Self.fallbackTwoLines }
    private var truncates: Bool { fullHeight > collapsedHeight + 0.5 }

    init(text: String, expanded: Bool = false) {
        self.text = text
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        Group {
            if expanded {
                measuredText
            } else {
                measuredText
                    .frame(height: collapsedHeight, alignment: .top)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        if truncates { fadeAndMore }
                    }
            }
        }
        .background(
            Text("X\nX")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(heightReader($twoLineHeight))
        )
    }

    /// The text at its full wrapped height, measured into `fullHeight`; the parent proposes its width.
    private var measuredText: some View {
        Text(text)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(heightReader($fullHeight))
    }

    private var fadeAndMore: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [Color(nsColor: .textBackgroundColor).opacity(0),
                                    Color(nsColor: .textBackgroundColor)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 56)
            Button("more") { expanded = true }
                .buttonStyle(.plain)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .padding(.leading, Spacing.xs)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(height: 16)
    }

    private func heightReader(_ height: Binding<CGFloat>) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { height.wrappedValue = proxy.size.height }
                .onChange(of: proxy.size.height) { _, new in height.wrappedValue = new }
        }
    }
}
