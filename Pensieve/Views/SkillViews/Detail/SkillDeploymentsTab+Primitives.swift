import SwiftUI

extension SkillDeploymentsTab {
    var sectionSpacing: some View {
        Spacer().frame(height: DesignTokens.groupSectionSpacing)
    }

    func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.groupTitle)
            .foregroundStyle(.primary)
            .frame(height: DesignTokens.groupTitleLineHeight, alignment: .topLeading)
            .padding(.bottom, DesignTokens.groupTitleToBoxTop - DesignTokens.groupTitleLineHeight)
    }

    func groupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .background(DesignTokens.groupFill)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.groupCornerRadius, style: .continuous))
    }

    func groupTextRow(
        _ text: String,
        font: Font,
        color: Color,
        showsSeparator: Bool
    ) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DesignTokens.groupLeadingInset)
            .padding(.trailing, DesignTokens.groupTrailingInset)
            .padding(.vertical, DesignTokens.groupRowVerticalPadding)
            .frame(minHeight: DesignTokens.groupRowHeight)
            .overlay(alignment: .bottom) {
                if showsSeparator { separator() }
            }
    }

    func platformToggle(
        _ row: DeploymentsPresentation.PlatformRow,
        nested: Bool = false,
        showsSeparator: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { row.isOn }, set: onChange)) {
            HStack(spacing: Spacing.md) {
                PlatformMarkTile(platform: row.platform, size: DesignTokens.groupPlatformTileSize)
                Text(row.platform.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let note = row.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.leading, DesignTokens.groupLeadingInset + (nested ? DesignTokens.groupNestedInset : 0))
        .padding(.trailing, DesignTokens.groupTrailingInset)
        .frame(height: DesignTokens.groupRowHeight)
        .disabled(!row.isEnabled)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                separator(leading: nested
                          ? DesignTokens.groupPlatformNameStart + DesignTokens.groupNestedInset
                          : DesignTokens.groupPlatformNameStart)
            }
        }
        .accessibilityLabel(row.platform.displayName)
        .accessibilityHint(row.note ?? "")
    }

    /// Chevron at x 8, folder at x 24, name at x 56, caption at x 240, then the deployed marks or summary.
    func projectDisclosureRow(
        _ row: DeploymentsPresentation.ProjectRow,
        expanded: Bool,
        showsSeparator: Bool
    ) -> some View {
        let trailing = row.summary ?? row.deployedPlatforms.map(\.displayName).joined(separator: ", ")
        return Button {
            if expanded {
                presentation.expandedProjects.remove(row.id)
            } else {
                presentation.expandedProjects.insert(row.id)
            }
        } label: {
            projectDisclosureLabel(row, expanded: expanded)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showsSeparator { separator(leading: DesignTokens.groupProjectNameStart) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(row.caption), \(trailing)")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
    }

    func projectDisclosureLabel(
        _ row: DeploymentsPresentation.ProjectRow,
        expanded: Bool
    ) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(expanded ? .degrees(90) : .zero)
                .frame(width: DesignTokens.groupProjectChevronWidth)
            Spacer().frame(
                width: DesignTokens.groupProjectFolderStart
                    - DesignTokens.groupLeadingInset
                    - DesignTokens.groupProjectChevronWidth
            )
            Image(systemName: "folder.fill")
                .foregroundStyle(Color(nsColor: .systemBlue))
                .frame(width: DesignTokens.groupProjectFolderWidth, height: DesignTokens.groupProjectFolderWidth)
            Spacer().frame(
                width: DesignTokens.groupProjectNameStart
                    - DesignTokens.groupProjectFolderStart
                    - DesignTokens.groupProjectFolderWidth
            )
            Text(row.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minWidth: Self.nameColumn, alignment: .leading)
            Spacer().frame(
                width: DesignTokens.groupProjectPathStart
                    - DesignTokens.groupProjectNameStart
                    - Self.nameColumn
            )
            Text(row.caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            projectSummary(row)
        }
        .padding(.leading, DesignTokens.groupLeadingInset)
        .padding(.trailing, DesignTokens.groupTrailingInset)
        .frame(height: DesignTokens.groupRowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder func projectSummary(_ row: DeploymentsPresentation.ProjectRow) -> some View {
        if let summary = row.summary {
            Text(summary).font(.caption).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 6) {
                ForEach(row.deployedPlatforms) { platform in
                    PlatformMark(platform: platform)
                        .foregroundStyle(Color(nsColor: .systemGray))
                        .frame(width: 14, height: 14)
                }
            }
        }
    }

    var addProjectFooter: some View {
        Button(action: onAddProject) {
            ZStack(alignment: .leading) {
                AddProjectGlyph().offset(x: DesignTokens.footerGlyphLeading)
                Rectangle()
                    .fill(DesignTokens.groupSeparator)
                    .frame(width: DesignTokens.groupSeparatorHeight, height: DesignTokens.footerDividerHeight)
                    .offset(x: DesignTokens.footerDividerLeading)
                Text("Add Project")
                    .font(DesignTokens.footerLabel)
                    .foregroundStyle(DesignTokens.footerLabelColor)
                    .padding(.leading, DesignTokens.footerLabelLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: DesignTokens.footerHeight)
        .background(DesignTokens.footerFill)
        .overlay(alignment: .top) { separator() }
        .disabled(addsFenced)
        .accessibilityLabel("Add Project")
    }

    func separator(leading: CGFloat = 0) -> some View {
        Rectangle()
            .fill(DesignTokens.groupSeparator)
            .frame(height: DesignTokens.groupSeparatorHeight)
            .padding(.leading, leading)
    }
}

private struct AddProjectGlyph: View {
    var body: some View {
        ZStack {
            Rectangle().frame(width: DesignTokens.footerGlyphSize, height: DesignTokens.footerGlyphStroke)
            Rectangle().frame(width: DesignTokens.footerGlyphStroke, height: DesignTokens.footerGlyphSize)
        }
        .foregroundStyle(DesignTokens.footerGlyph)
        .frame(width: DesignTokens.footerGlyphSize, height: DesignTokens.footerGlyphSize)
    }
}
