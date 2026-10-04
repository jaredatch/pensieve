import MarkdownUI
import SwiftUI

private struct PreviewImageAltKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var previewImageAlt: String {
        get { self[PreviewImageAltKey.self] }
        set { self[PreviewImageAltKey.self] = newValue }
    }
}

struct PreviewImageProvider: ImageProvider, InlineImageProvider {
    let loader: PreviewImageLoading
    let skillDirectory: String?
    var documentRelativePath = "SKILL.md"
    var colorScheme: ColorScheme = .light
    var budget = PreviewImageDecodeBudget()

    func makeImage(url: URL?) -> some View {
        PreviewBlockImage(url: url, provider: self)
    }

    /// Shared by the mounted block task and inline provider. Leaf reads and ImageIO decoding are
    /// synchronous, so detach them explicitly even when the caller inherits the main actor.
    func loadImage(url: URL?) async -> CGImage? {
        guard let url, let url = PreviewImageLoader.resolvedURL(
            url, skillDirectory: skillDirectory, documentRelativePath: documentRelativePath
        ) else { return nil }
        return await Task.detached(priority: .userInitiated) { [loader, skillDirectory, url, budget] in
            try? loader.loadImage(at: url, skillDirectory: skillDirectory, budget: budget)
        }.value
    }

    func image(with url: URL, label: String) async throws -> Image {
        if let image = await loadImage(url: url) {
            return Image(image, scale: 1, label: Text(label))
        }
        // MarkdownUI discards the entire paragraph's image batch if any task throws. Return a
        // visible alt-text image for this failure so neighboring valid images still render.
        return await MainActor.run {
            let renderer = ImageRenderer(content: PreviewImagePlaceholder(alt: label)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, colorScheme))
            renderer.scale = 2
            if let image = renderer.cgImage {
                return Image(image, scale: 2, label: Text(label))
            }
            return Image(systemName: "photo")
        }
    }
}

private struct PreviewBlockImage: View {
    @Environment(\.previewImageAlt) private var alt
    let url: URL?
    let provider: PreviewImageProvider
    @State private var image: CGImage?

    var body: some View {
        PreviewBlockImageContent(image: image, alt: alt)
            .task(id: url) {
                let loaded = await provider.loadImage(url: url)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

/// Pure loaded content, shared with offscreen provider tests because ImageRenderer runs no tasks.
struct PreviewBlockImageContent: View {
    let image: CGImage?
    let alt: String

    var body: some View {
        Group {
            if let image {
                Image(image, scale: 1, label: Text(alt))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: CGFloat(image.width), maxHeight: CGFloat(image.height))
            } else {
                PreviewImagePlaceholder(alt: alt)
            }
        }
    }
}

struct PreviewImagePlaceholder: View {
    let alt: String

    var body: some View {
        Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(alt.isEmpty ? "Image unavailable" : "Image unavailable: \(alt)")
    }
}
