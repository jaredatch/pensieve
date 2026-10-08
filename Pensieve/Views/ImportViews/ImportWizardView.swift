import SwiftUI
import SwiftData

struct ImportWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var importVM: ImportViewModel
    let writesAllowed: Bool

    @State private var step: ImportStep = .welcome

    init(importVM: ImportViewModel, writesAllowed: Bool, startsAtResults: Bool = false) {
        self.importVM = importVM
        self.writesAllowed = writesAllowed
        _step = State(initialValue: startsAtResults ? .results : .welcome)
    }

    enum ImportStep {
        case welcome
        case scanning
        case results
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome:
                welcomeView
            case .scanning:
                scanningView
            case .results:
                ImportResultsView(importVM: importVM) {
                    guard writesAllowed else {
                        importVM.error = "Failed to import: couldn't read the library"
                        return
                    }
                    if importVM.importSelected(context: context) == .finished { step = .done }
                }
            case .done:
                doneView
            }
        }
        .frame(width: 600, height: 500)
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: Spacing.xxl) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Pensieve")
                .font(.largeTitle.bold())

            Text("Let's find your existing AI skills across Claude Code, Grok, Cursor, and Codex.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()

            HStack {
                Button("Skip") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Scan for Skills") {
                    step = .scanning
                    Task {
                        importVM.scan()
                        step = importVM.hasResults ? .results : .done
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .padding()
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Scanning for existing skills...")
                .font(.headline)
            Text("Checking ~/.claude/skills, ~/.cursor/rules, and more")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Done

    private var doneView: some View {
        ImportDoneView(importVM: importVM, onDone: { dismiss() })
    }
}
