import SmolCore
import SwiftUI

/// Batch-convert a folder once, or keep watching it.
struct WatchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var watcher = model.watcher
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                VStack(spacing: 0) {
                    FolderLine(label: "From", url: watcher.config.inputURL,
                               choose: watcher.chooseInputFolder, reveal: { watcher.reveal(watcher.config.inputURL) })
                    hairline
                    FolderLine(label: "To", url: watcher.config.outputURL,
                               choose: watcher.chooseOutputFolder, reveal: { watcher.reveal(watcher.config.outputURL) })
                    hairline
                    FieldRow("Include subfolders") { MiniSwitch(isOn: $watcher.config.recursive) }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                    hairline
                    FieldRow("Skip images already converted") { MiniSwitch(isOn: $watcher.config.skipExisting) }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                }
                .dsCard(padding: 0)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Output")
                    SettingsPanel(settings: $watcher.config.settings)
                        .dsCard(padding: 16)
                }

                actions(watcher)

                activity(watcher)
            }
            .frame(maxWidth: 580)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(DS.canvas)
        .navigationTitle("Watch Folder")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.screen = .home } label: { Label("Home", systemImage: "circle.circle") }
                    .help("Back to the dial  ⇧⌘H")
            }
            if !model.items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Editor (\(model.items.count))") { model.screen = .editor }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Watch Folder")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
            Text("Convert every image in a folder — once, or automatically as new files arrive.")
                .font(.dsBody)
                .foregroundStyle(.secondary)
        }
    }

    private var hairline: some View {
        Rectangle().fill(DS.hairline.opacity(0.7)).frame(height: 0.5)
    }

    private func actions(_ watcher: FolderWatcher) -> some View {
        let canRun = watcher.config.settings.format.isAvailable
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { watcher.convertNow() } label: {
                    HStack(spacing: 8) {
                        if watcher.isBusy && !watcher.isWatching { ProgressView().controlSize(.mini).tint(DS.canvas) }
                        Text("Convert now")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(watcher.isBusy || !canRun)

                Button { watcher.toggleWatching() } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(watcher.isWatching ? DS.positive : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                            .symbolEffect(.pulse, isActive: watcher.isWatching)
                        Text(watcher.isWatching ? "Stop watching" : "Start watching")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!canRun)
            }

            HStack {
                if watcher.convertedCount + watcher.failedCount > 0 {
                    Text("\(watcher.convertedCount) converted  ·  \(Format.bytes(watcher.bytesIn)) → \(Format.bytes(watcher.bytesOut))")
                        .font(.dsMonoSmall)
                        .foregroundStyle(.secondary)
                    if watcher.bytesIn > 0 { SavingsText(fraction: 1 - Double(watcher.bytesOut) / Double(watcher.bytesIn)) }
                    if watcher.failedCount > 0 {
                        Text("· \(watcher.failedCount) failed").font(.dsMonoSmall).foregroundStyle(DS.negative)
                    }
                } else {
                    Text("Replaces a find | magick shell loop. Metadata is stripped; nothing is overwritten outside the output folder.")
                        .font(.dsCaption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func activity(_ watcher: FolderWatcher) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Activity")
                if !watcher.log.isEmpty {
                    Button("Clear") { watcher.clearLog() }.buttonStyle(QuietButtonStyle())
                }
            }
            if watcher.log.isEmpty {
                Text("Nothing converted yet.")
                    .font(.dsLabel)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(watcher.log.prefix(200)) { entry in
                        LogLine(entry: entry)
                        hairline
                    }
                }
            }
        }
    }
}

private struct FolderLine: View {
    let label: String
    let url: URL
    let choose: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.dsLabel)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Change", action: choose).buttonStyle(QuietButtonStyle())
            Button(action: reveal) { Image(systemName: "arrow.up.right") }
                .buttonStyle(IconButtonStyle())
                .help("Open in Finder")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }
}

private struct LogLine: View {
    let entry: FolderWatcher.LogEntry

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(entry.isError ? DS.negative : entry.message == "info" ? Color.secondary.opacity(0.4) : DS.positive)
                .frame(width: 6, height: 6)
            Text(entry.name)
                .font(.dsLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if entry.isError, let message = entry.message {
                Text(message)
                    .font(.dsCaption)
                    .foregroundStyle(DS.negative)
                    .lineLimit(1)
                    .help(message)
            } else if let output = entry.outputBytes, entry.message == nil {
                Text("\(Format.bytes(entry.inputBytes)) → \(Format.bytes(output))")
                    .font(.dsMonoSmall)
                    .foregroundStyle(.secondary)
                if entry.inputBytes > 0 {
                    SavingsText(fraction: 1 - Double(output) / Double(entry.inputBytes))
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.dsMonoSmall)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
}
