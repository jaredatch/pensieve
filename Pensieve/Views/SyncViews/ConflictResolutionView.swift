import SwiftUI
import SwiftData

struct ConflictResolutionView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.modelContext) private var modelContext
    @State private var model: ConflictResolutionModel
    @State private var historySkill: Skill?
    @Query(sort: \Skill.name) private var skills: [Skill]

    let onDismiss: () -> Void
    let notifier: SyncStateNotifying
    let library: SkillLibraryViewModel?

    init(model: ConflictResolutionModel,
         library: SkillLibraryViewModel? = nil,
         notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
         onDismiss: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.library = library
        self.notifier = notifier
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Resolve sync conflicts")
                .font(.headline)

            content

            footer
        }
        .padding(Spacing.xl)
        .frame(width: 560)
        .task { model.load(context: modelContext) }
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .done {
                onDismiss()
            }
        }
        .sheet(isPresented: historySheetBinding) {
            if let historySkill {
                SkillHistoryView(
                    skill: historySkill,
                    git: runtime.paths.makeGitService(),
                    store: runtime.library.skillStore, workingDir: runtime.paths.storeRoot,
                    library: library,
                    notifier: notifier,
                    onDismiss: { self.historySkill = nil }
                )
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        case let .ready(groups):
            if let message = model.selectionError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(groups) { group in
                        conflictCard(group)
                    }
                }
            }
            .frame(maxHeight: 520)
        case .resolving:
            ProgressView("Resolving…")
                .frame(maxWidth: .infinity, alignment: .center)
        case .done:
            EmptyView()
        case let .error(message):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    model.load(context: modelContext)
                }
                .controlSize(.small)
            }
        case .empty:
            ContentUnavailableView {
                Label("No conflicts to resolve", systemImage: "checkmark.circle")
            } actions: {
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Keep selected & sync") {
                model.apply(context: modelContext)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApply)
        }
    }

    private func conflictCard(_ group: ConflictResolutionModel.ConflictGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(group.title)
                    .font(.headline)
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(group.items, id: \.path) { item in
                itemView(item)
            }

            HStack(spacing: Spacing.sm) {
                choiceButton("Keep This Mac", side: .thisMachine, group: group)
                choiceButton("Keep Other Mac", side: .otherMachine, group: group)
            }
        }
        .padding(Spacing.md)
        .background(Color(.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Spacing.md, style: .continuous))
    }

    @ViewBuilder private func itemView(_ item: ConflictItem) -> some View {
        switch item.kind {
        case .body:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ConflictFileComparison(item: item)
                if let skill = bodySkill(for: item) {
                    Button("See history") { historySkill = skill }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        case .overlay, .category, .project:
            settingsRow(item)
        }
    }

    private func settingsRow(_ item: ConflictItem) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Settings differ")
                    .font(.callout)
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.sm)
        .background(.fill.quaternary,
                    in: RoundedRectangle(cornerRadius: Spacing.sm, style: .continuous))
    }

    @ViewBuilder private func choiceButton(_ title: String, side: ConflictSide,
                                           group: ConflictResolutionModel.ConflictGroup) -> some View {
        if group.chosen == side {
            Button(title) { model.choose(group.id, side) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(title) { model.choose(group.id, side) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var historySheetBinding: Binding<Bool> {
        Binding(get: {
            historySkill != nil
        }, set: { isPresented in
            if !isPresented { historySkill = nil }
        })
    }

    private func bodySkill(for item: ConflictItem) -> Skill? {
        guard let slug = bodySlug(from: item.path) else { return nil }
        return skills.first { $0.directoryName == slug }
    }

    private func bodySlug(from path: String) -> String? {
        guard path.hasPrefix("skills/"), path.hasSuffix("/SKILL.md") else { return nil }
        let start = path.index(path.startIndex, offsetBy: "skills/".count)
        let end = path.index(path.endIndex, offsetBy: -"/SKILL.md".count)
        guard start < end else { return nil }
        return String(path[start..<end])
    }
}

/// The sheet's file comparison, separate from grouping and resolution controls.
struct ConflictFileComparison: View {
    private enum Side {
        case deleted
        case unavailable
        case text(String, preview: String, hiddenLines: Int)
        case nonText(bytes: Int)

        init(_ bytes: Data?, unavailable: UnavailableConflictSide?) {
            guard unavailable == nil else { self = .unavailable; return }
            guard let bytes else { self = .deleted; return }
            guard !bytes.contains(0), let text = UpstreamHistoryFileContent.utf8PreservingBOM(bytes) else {
                self = .nonText(bytes: bytes.count)
                return
            }
            var lines = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { lines.removeLast() }
            let visible = lines.prefix(LineDiffView.defaultMaxRows)
            self = .text(text, preview: visible.joined(separator: "\n"), hiddenLines: lines.count - visible.count)
        }
    }

    private let this: Side
    private let other: Side

    init(item: ConflictItem) {
        this = Side(item.thisMachine, unavailable: item.thisUnavailable)
        other = Side(item.otherMachine, unavailable: item.otherUnavailable)
    }

    var body: some View {
        if case let .text(this, _, _) = this, case let .text(other, _, _) = other,
           !this.isEmpty, !other.isEmpty {
            LineDiffView(this: this, other: other)
        } else {
            HStack(alignment: .top, spacing: Spacing.md) {
                side("This Mac", content: this)
                side("Other Mac", content: other)
            }
        }
    }

    private func side(_ title: String, content: Side) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            switch content {
            case .deleted:
                Text("Deleted").foregroundStyle(.secondary)
            case .unavailable:
                Text("This version can’t be shown or kept as a file. You can keep the other version.")
                    .foregroundStyle(.secondary)
            case let .text(text, preview, hiddenLines):
                Text(text.isEmpty ? "Empty file" : preview)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if hiddenLines > 0 {
                    Text(verbatim: "Showing the first \(LineDiffView.defaultMaxRows) lines. "
                         + "\(hiddenLines) more \(hiddenLines == 1 ? "isn’t" : "aren’t") shown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case let .nonText(bytes):
                Text("This file can’t be shown as text.").foregroundStyle(.secondary)
                Text("\(bytes) \(bytes == 1 ? "byte" : "bytes")").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
