import SwiftUI

/// "Update available · Sep 10" above the tabs of a linked skill whose checked upstream is newer (the
/// master `Update banner`, 612 × 40): one line, the group fill, the arrow in green, then two buttons —
/// View Changes opens that skill's preview window and Update opens its selected row in Skill Updates.
/// The date is the pinned upstream commit's.
struct SkillUpdateAvailableBanner: View {
    let upstreamDate: Date?
    let onViewChanges: () -> Void
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(Self.title(upstreamDate: upstreamDate))
                .font(DesignTokens.bannerTitle)
                .foregroundStyle(.primary)
            Spacer()
            Button("View Changes", action: onViewChanges)
                .accessibilityIdentifier("skill-view-changes")
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .controlSize(.large)
            Button("Update", action: onUpdate)
                .accessibilityIdentifier("skill-update")
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(DesignTokens.bannerPadding)
        .frame(height: DesignTokens.bannerHeight)
        .background(
            DesignTokens.bannerFill,
            in: RoundedRectangle(cornerRadius: DesignTokens.bannerCornerRadius, style: .continuous)
        )
        .padding(.horizontal, Spacing.lg)
    }

    static func title(upstreamDate: Date?, locale: Locale = .current) -> String {
        guard let upstreamDate else { return "Update available" }
        return "Update available · " + upstreamDate.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }
}
