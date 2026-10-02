import SwiftUI

/// The brand behind each platform's mark: an
/// app-icon-like tile and the LobeHub mark in the brand's ink. The tile colors are the brands' own — the
/// one place that uses a fixed brand color in chrome; semantic colors everywhere else.
/// Hermes has no vendored mark (its LobeHub SVG is 19 KB of path and the frames carry no Hermes tile):
/// its SF Symbol on the system gray.
enum PlatformBrand {
    enum Mark: Equatable {
        /// A template image in the asset catalog (a vendored LobeHub mark).
        case asset(String)
        /// An SF Symbol, for a platform with no vendored mark.
        case symbol(String)
    }

    struct Tile: Equatable {
        let mark: Mark
        let background: Color
        let ink: Color
    }

    static func tile(for platform: PlatformTarget) -> Tile {
        switch platform {
        case .claudeCode:
            Tile(mark: .asset("brand-claudecode"),
                 background: Color(red: 217 / 255.0, green: 119 / 255.0, blue: 87 / 255.0), ink: .white)
        case .codex:
            Tile(mark: .asset("brand-codex"), background: .white, ink: .black)
        case .cursor:
            Tile(mark: .asset("brand-cursor"), background: .black, ink: .white)
        case .grok:
            Tile(mark: .asset("brand-grok"), background: .black, ink: .white)
        case .openClaw:
            Tile(mark: .asset("brand-openclaw"),
                 background: Color(red: 224 / 255.0, green: 65 / 255.0, blue: 62 / 255.0), ink: .white)
        case .hermes:
            Tile(mark: .symbol(PlatformTarget.hermes.iconName), background: Color(nsColor: .systemGray), ink: .white)
        }
    }
}

/// A 20 pt brand tile (radius 5, an 8 % inside hairline) with the platform's mark at 12 pt — the Sketch
/// masters `Settings / mark tile` and `Mark / *`.
struct PlatformMarkTile: View {
    let platform: PlatformTarget
    var size: CGFloat = 20

    var body: some View {
        let tile = PlatformBrand.tile(for: platform)
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tile.background)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                PlatformMark(platform: platform)
                    .foregroundStyle(tile.ink)
                    .frame(width: size * 0.6, height: size * 0.6)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The bare mark: the LobeHub template image, or the SF Symbol for a platform without one. Tinted by the
/// caller — white on a tile, the system gray on a collapsed project row.
struct PlatformMark: View {
    let platform: PlatformTarget

    var body: some View {
        switch PlatformBrand.tile(for: platform).mark {
        case let .asset(name):
            Image(name).renderingMode(.template).resizable().scaledToFit()
        case let .symbol(name):
            Image(systemName: name).resizable().scaledToFit()
        }
    }
}
