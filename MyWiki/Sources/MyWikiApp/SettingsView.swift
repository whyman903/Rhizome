import SwiftUI
import MyWikiCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                themeSection
                fontSection
                obsidianSection
                claudeCommandsSection
                previewSection
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(EditorialPalette.background)
    }

    // MARK: - Theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("THEME")

            HStack(spacing: 14) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    ThemeSwatchButton(
                        theme: theme,
                        isSelected: model.theme == theme
                    ) {
                        activeTheme = theme
                        model.theme = theme
                    }
                }
            }
        }
    }

    // MARK: - Font

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("FONT")

            HStack(spacing: 14) {
                ForEach(AppFont.allCases, id: \.self) { font in
                    FontOptionButton(
                        font: font,
                        isSelected: model.font == font
                    ) {
                        activeFont = font
                        model.font = font
                    }
                }
            }
        }
    }

    // MARK: - Obsidian

    private var obsidianSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("OBSIDIAN")

            VStack(alignment: .leading, spacing: 10) {
                Text(model.canOpenGraphDirectly
                     ? "Graph opens directly in Obsidian for this vault."
                     : "Graph opening can use the Advanced URI plugin for this vault.")
                    .font(.system(size: 13, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task {
                        await model.installGraphPluginForCurrentWorkspace()
                    }
                } label: {
                    Text(model.isInstallingGraphPlugin
                         ? "Installing Advanced URI…"
                         : (model.isGraphPluginInstalled ? "Reinstall Advanced URI" : "Install Advanced URI"))
                        .font(.system(size: 12, weight: .semibold, design: activeFont.design))
                        .foregroundStyle(EditorialPalette.background)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(EditorialPalette.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isInstallingGraphPlugin || model.workspace == nil)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EditorialPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Claude commands

    private var claudeCommandsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("CLAUDE COMMANDS")

            VStack(alignment: .leading, spacing: 10) {
                Text("Slash commands live in `.claude/commands/` inside your wiki. Edit them in any editor to customize how Claude responds. After updating MyWiki, use Reset to Defaults to pick up new shipped commands (this overwrites your edits).")
                    .font(.system(size: 13, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        model.revealClaudeCommandsInFinder()
                    } label: {
                        Text("Edit Commands in Finder")
                            .font(.system(size: 12, weight: .semibold, design: activeFont.design))
                            .foregroundStyle(EditorialPalette.background)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(EditorialPalette.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.workspace == nil)

                    Button {
                        Task { await model.refreshClaudeCommands() }
                    } label: {
                        Text("Reset to Defaults")
                            .font(.system(size: 12, weight: .semibold, design: activeFont.design))
                            .foregroundStyle(EditorialPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(EditorialPalette.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.workspace == nil)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EditorialPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("PREVIEW")

            VStack(alignment: .leading, spacing: 12) {
                Text("The unexamined life is not worth living.")
                    .font(.system(size: 16, weight: .medium, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                Text("Knowledge is the food of the soul. What we know is a drop; what we don't know is an ocean.")
                    .font(.system(size: 14, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textSecondary)
                    .lineSpacing(3)
                Text("Updated just now")
                    .font(.system(size: 11, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EditorialPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .kerning(1.3)
            .foregroundStyle(EditorialPalette.textTertiary)
    }
}

// MARK: - Theme swatch

private struct ThemeSwatchButton: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let preview = ThemeColorSet.forTheme(theme)
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(preview.background)
                        .frame(width: 72, height: 52)

                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(preview.accent)
                            .frame(width: 28, height: 3)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(preview.textSecondary)
                            .frame(width: 22, height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(preview.textTertiary)
                            .frame(width: 16, height: 2)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected ? preview.accent : EditorialPalette.border,
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .scaleEffect(isHovering ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isHovering)

                Text(theme.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? EditorialPalette.textPrimary
                            : EditorialPalette.textSecondary
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Font option

private struct FontOptionButton: View {
    let font: AppFont
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text("Aa")
                    .font(.system(size: 22, weight: .medium, design: font.design))
                    .foregroundStyle(
                        isSelected
                            ? EditorialPalette.accent
                            : EditorialPalette.textSecondary
                    )
                    .frame(width: 72, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(EditorialPalette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? EditorialPalette.accent : EditorialPalette.border,
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .scaleEffect(isHovering ? 1.04 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovering)

                Text(font.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? EditorialPalette.textPrimary
                            : EditorialPalette.textSecondary
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
