import SwiftUI
import SwiftData

struct ImportWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var importVM: ImportViewModel
    let writesAllowed: Bool
    let detectedPlatforms: [PlatformTarget]

    @State private var step: ImportStep = .welcome

    init(importVM: ImportViewModel, writesAllowed: Bool, detectedPlatforms: [PlatformTarget], startsAtResults: Bool = false) {
        self.importVM = importVM
        self.writesAllowed = writesAllowed
        self.detectedPlatforms = detectedPlatforms
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

    private var welcomeMessage: String {
        // Match the four sources ImportScanner reads, in its scan order.
        let scanned: [PlatformTarget] = [.claudeCode, .grok, .cursor, .codex]
        let names = scanned.filter { detectedPlatforms.contains($0) }.map(\.displayName)
        guard !names.isEmpty else { return "Let's find your existing AI skills." }
        return "Let's find your existing AI skills across \(names.formatted(.list(type: .and)))."
    }

    private var welcomeView: some View {
        VStack(spacing: Spacing.xxl) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Pensieve")
                .font(.largeTitle.bold())

            Text(welcomeMessage)
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
            Text("Checking for skills on this Mac.")
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
