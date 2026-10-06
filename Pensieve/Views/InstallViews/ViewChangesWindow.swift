import AppKit
import SwiftData
import SwiftUI

struct ViewChangesScene: Scene {
    let model: ViewChangesViewModel
    let library: SkillLibraryViewModel
    let updates: UpdatesViewModel
    let container: ModelContainer

    var body: some Scene { configuredWindow }

    // SceneBuilder has no buildEither. Its public availability eraser keeps the same scene type
    // across the macOS 14 fallback and the newer SwiftUI restoration/launch policy.
    private var configuredWindow: some Scene {
        if #available(macOS 15, *) {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(
                window.restorationBehavior(.disabled).defaultLaunchBehavior(.suppressed)
            ))
        }
        return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(window))
    }

    private var window: some Scene {
        Window("View Changes", id: WindowPolicy.changesWindowID) {
            ViewChangesWindow(model: model, library: library, updates: updates)
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: DesignTokens.changesWindowWidth, height: DesignTokens.changesWindowHeight)
        .commandsRemoved()
    }
}

struct ViewChangesWindow: View {
    @Bindable var model: ViewChangesViewModel
    @Bindable var library: SkillLibraryViewModel
    let updates: UpdatesViewModel

    var body: some View {
        ViewChangesWindowContent(skillID: model.requestedSkillID, model: model, library: library, updates: updates)
    }

    /// Opening a preview looks up this skill once and leaves draft and sheet state alone.
    static func present(skillID: UUID, model: ViewChangesViewModel, library: SkillLibraryViewModel,
                        context: ModelContext, windows: [NSWindow]? = nil, open: () -> Void) {
        model.open(skillID: skillID, context: context, folderRevisions: library.folderChangeRevisions)
        WindowPolicy.showChangesWindow(among: windows ?? NSApp.windows, open: open)
    }
}

private struct ViewChangesWindowContent: View {
    @Bindable var model: ViewChangesViewModel
    @Bindable var library: SkillLibraryViewModel
    @Environment(\.modelContext) private var context
    @Query private var skills: [Skill]
    let updates: UpdatesViewModel
    @Environment(\.openWindow) private var openWindow

    init(skillID: UUID?, model: ViewChangesViewModel, library: SkillLibraryViewModel, updates: UpdatesViewModel) {
        self.model = model
        self.library = library
        self.updates = updates
        if let skillID {
            _skills = Query(filter: #Predicate<Skill> { $0.id == skillID })
        } else {
            _skills = Query(filter: #Predicate<Skill> { _ in false })
        }
    }

    private var identities: [ViewChangesIdentity] {
        skills.filter { $0.modelContext != nil && !$0.isDeleted }.map {
            ViewChangesIdentity(skill: $0, folderRevision: library.folderChangeRevisions[$0.directoryName, default: 0])
        }
    }

    var body: some View {
        UpdateReviewRouting(preview: model, updates: updates, library: library, context: context,
                            openWindow: { openWindow(id: $0) }).window
            .onAppear { validate() }
            .onChange(of: identities) { _, _ in validate() }
    }

    private func validate() {
        model.validate(skills: skills, folderRevisions: library.folderChangeRevisions, context: context)
    }
}

/// SwiftUI's macOS 14 scene API has no restoration or window-close modifier. This lifecycle-only bridge
/// disables AppKit restoration and observes the real close without replacing SwiftUI's window delegate.
struct ViewChangesWindowLifecycle: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> ViewChangesWindowObserver { ViewChangesWindowObserver(onClose: onClose) }

    func makeNSView(context: Context) -> ViewChangesLifecycleView {
        let view = ViewChangesLifecycleView(frame: .zero)
        view.observer = context.coordinator
        return view
    }

    func updateNSView(_ view: ViewChangesLifecycleView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: ViewChangesLifecycleView, coordinator: ViewChangesWindowObserver) {
        coordinator.detach()
    }
}

final class ViewChangesLifecycleView: NSView {
    weak var observer: ViewChangesWindowObserver?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observer?.attach(to: window)
    }
}

final class ViewChangesWindowObserver {
    var onClose: () -> Void
    private weak var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    func attach(to window: NSWindow?) {
        guard let window, self.window !== window else { return }
        detach()
        self.window = window
        WindowPolicy.configureChangesWindow(window)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.onClose() }
    }

    func detach() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }

    deinit { detach() }
}
