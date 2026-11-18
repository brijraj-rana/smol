import SmolCore
import SwiftUI

/// The ⌘, window: where files go, how they're named, appearance, and which encoders are installed.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 26) {
            section("Saving") {
                VStack(spacing: 0) {
                    row("Save to") { DestinationMenu() }
                    hairline
                    row("File name suffix") {
                        TextField("none", text: $model.preferences.suffix)
                            .textFieldStyle(.plain)
                            .font(.dsMono)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DS.fill))
                    }
                    hairline
                    row("Show in Finder after saving") { MiniSwitch(isOn: $model.preferences.revealAfterSave) }
                }
                .dsCard(padding: 0)
                Text("Example: photo.jpg → photo\(model.preferences.cleanSuffix).\(model.settings.format.fileExtension). Smol never overwrites an existing file.")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Responsive set") {
                VStack(spacing: 0) {
                    row("Widths") {
                        TextField("640, 1280, 1920", text: $model.preferences.responsiveWidths)
                            .textFieldStyle(.plain)
                            .font(.dsMono)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 200)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DS.fill))
                    }
                }
                .dsCard(padding: 0)
                Text(responsiveExample)
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Appearance") {
                Segmented(options: Preferences.Appearance.allCases, selection: $model.preferences.appearance, title: \.title)
            }

            section("Encoders") {
                VStack(spacing: 0) {
                    encoderRow("AVIF, HEIC, JPEG, PNG, TIFF, GIF, BMP", detail: "Built into macOS", installed: true, command: nil)
                    ForEach(ExternalTool.allCases, id: \.self) { tool in
                        hairline
                        encoderRow(toolTitle(tool), detail: tool.isInstalled ? (tool.path ?? "") : tool.installCommand,
                                   installed: tool.isInstalled, command: tool.isInstalled ? nil : tool.installCommand)
                    }
                }
                .dsCard(padding: 0)
                Text("Optional encoders come from Homebrew. Smol notices new ones when you switch back to it.")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(DS.canvas)
    }

    private var responsiveExample: String {
        guard let widths = ResponsiveSet.parseWidths(model.preferences.responsiveWidths) else {
            return "Type widths in pixels, separated by commas."
        }
        let name = ResponsiveSet.baseName("photo\(model.preferences.cleanSuffix)", width: widths.sorted()[0])
        return "Example: \(name).\(model.settings.format.fileExtension). Widths larger than the image are skipped."
    }

    private func toolTitle(_ tool: ExternalTool) -> String {
        switch tool {
        case .cwebp: "WebP"
        case .cjxl: "JPEG XL"
        case .pngquant: "PNG color reduction"
        case .oxipng: "PNG optimization"
        }
    }

    private var hairline: some View {
        Rectangle().fill(DS.hairline.opacity(0.7)).frame(height: 0.5)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer(minLength: 16)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
    }

    private func encoderRow(_ title: String, detail: String, installed: Bool, command: String?) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(installed ? DS.positive : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dsBody)
                Text(detail)
                    .font(.system(size: 11, design: command == nil ? .default : .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let command {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    model.showToast("Copied: \(command)")
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }
}

/// Pick where compressed files go. Used in Settings and under the Save button.
struct DestinationMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.preferences
        Menu {
            Button { model.preferences.destination = .ask } label: {
                Label("Ask each time", systemImage: preferences.destination == .ask ? "checkmark" : "")
            }
            Button { model.preferences.destination = .besideOriginal } label: {
                Label("Next to originals", systemImage: preferences.destination == .besideOriginal ? "checkmark" : "")
            }
            if let folder = preferences.folderURL {
                Button { model.preferences.destination = .folder } label: {
                    Label(folder.lastPathComponent, systemImage: preferences.destination == .folder ? "checkmark" : "folder")
                }
            }
            Divider()
            Button("Choose Folder…") { model.chooseOutputFolder() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: preferences.destination == .ask ? "questionmark.folder" : "folder")
                    .font(.system(size: 11))
                Text(preferences.destinationLabel)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(.dsLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Where compressed images are saved")
    }
}
