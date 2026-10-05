import AppKit
import SwiftUI

/// A native button preserves the press action and keyboard focus while hosting the measured row artwork.
struct ViewChangesFileButton: NSViewRepresentable {
    let file: PinnedSkillFileDiff
    let selected: Bool
    let action: () -> Void
    let moveSelection: (Int) -> Void

    func makeNSView(context: Context) -> ChangesFileRowButton {
        let button = ChangesFileRowButton(frame: .zero)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ChangesFileRowButton, context: Context) {
        button.configure(file: file, selected: selected, action: action, move: moveSelection)
    }
}

final class ChangesFileRowButton: NSButton {
    private var labelHost: NSHostingView<ViewChangesFileRow>?
    private var selected = false
    private var selectFile: (() -> Void)?
    private var moveSelection: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
    override func isAccessibilitySelected() -> Bool { selected }
    override func accessibilityChildren() -> [Any]? { [] }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    func configure(file: PinnedSkillFileDiff, selected: Bool, action: @escaping () -> Void, move: @escaping (Int) -> Void) {
        self.selected = selected
        selectFile = action
        moveSelection = move
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(chooseFile)
        setAccessibilityLabel(ViewChangesPresentation.accessibilityLabel(file))
        setAccessibilityIdentifier("changes-file-" + file.path)
        let artwork = ViewChangesFileRow(file: file, selected: selected)
        if let labelHost {
            labelHost.rootView = artwork
        } else {
            let host = NSHostingView(rootView: artwork)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            labelHost = host
        }
        if selected, window?.firstResponder is ChangesFileRowButton { window?.makeFirstResponder(self) }
    }

    @objc private func chooseFile() {
        window?.makeFirstResponder(self)
        selectFile?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveSelection?(1)
        case 126: moveSelection?(-1)
        default: super.keyDown(with: event)
        }
    }
}

private struct ViewChangesFileRow: View {
    let file: PinnedSkillFileDiff
    let selected: Bool

    var body: some View {
        let parent = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: DesignTokens.changesFileRowGap) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.changesFileGlyphWidth, height: DesignTokens.changesFileGlyphHeight)
            VStack(alignment: .leading, spacing: DesignTokens.changesFileFolderGap) {
                Text(verbatim: (file.path as NSString).lastPathComponent).font(DesignTokens.changesFileName).lineLimit(1)
                if !parent.isEmpty {
                    Text(verbatim: parent).font(DesignTokens.changesFileFolder).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.changesCountGap) {
                if let counts = ViewChangesPresentation.sidebarCounts(file) {
                    let added = counts.added
                    let removed = counts.removed
                    if added > 0 || removed == 0 { Text("+\(added)").foregroundStyle(Color(nsColor: .systemGreen)) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Color(nsColor: .systemRed)) }
                } else {
                    if case .modeOnly = file.content {
                        Text("Mode").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: ViewChangesPresentation.summary(file)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(DesignTokens.changesCount)
        }
        .padding(.horizontal, DesignTokens.changesFileRowHorizontalPadding)
        .frame(height: parent.isEmpty ? DesignTokens.changesFileRowHeight : DesignTokens.changesNestedFileRowHeight)
        .background(selected ? DesignTokens.changesFileRowSelectedFill : .clear,
                    in: RoundedRectangle(cornerRadius: DesignTokens.changesFileRowCornerRadius))
        .contentShape(Rectangle())
    }
}
