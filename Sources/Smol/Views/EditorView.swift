import SmolCore
import SwiftUI

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
        } detail: {
            Group {
                if let item = model.selectedItem {
                    CompareView(item: item).id(item.id)
                } else {
                    Text("Select an image")
                        .font(.dsBody)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.sunken)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 280, max: 340)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle(model.selectedItem?.name ?? "Smol")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.screen = .home } label: { Label("Home", systemImage: "circle.circle") }
                    .help("Back to the dial  ⇧⌘H")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.presentOpenPanel() } label: { Label("Add", systemImage: "plus") }
                    .help("Add images or folders  ⌘O")
                Button { showInspector.toggle() } label: { Label("Settings", systemImage: "sidebar.right") }
                    .help("Toggle settings")
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                ItemRow(item: item, settings: model.settings)
                    .tag(item.id)
                    .onDrag { model.dragProvider(for: item) }
                    .contextMenu {
                        Button("Copy Compressed Image") { model.copyCompressed(item) }
                        Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Divider()
                        Button("Remove", role: .destructive) { model.remove([item.id]) }
                    }
            }
        }
        .onDeleteCommand { if let id = model.selection { model.remove([id]) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var footer: some View {
        let totals = model.totals
        let progress = Double(totals.processed) / Double(max(model.items.count, 1))
        return VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.hairline)
                Rectangle()
                    .fill(Color.primary.opacity(progress < 1 ? 0.6 : 0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: progress, anchor: .leading)
            }
            .frame(height: progress < 1 ? 1.5 : 0.5)
            .animation(.easeOut(duration: 0.3), value: progress)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.items.count) image\(model.items.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                    Text(totals.input > 0 ? "\(Format.bytes(totals.input)) → \(Format.bytes(totals.output))"
                         : progress < 1 ? "Compressing…" : "Nothing compressed")
                        .font(.dsMonoSmall)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if totals.input > 0 {
                    SavingsText(fraction: 1 - Double(totals.output) / Double(totals.input), font: .system(size: 13, weight: .medium).monospacedDigit())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

private struct ItemRow: View {
    let item: ImageItem
    let settings: EncodeSettings

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(DS.fill)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.dsMonoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 2)
    }

    private var failure: String? { item.loadError ?? (item.isCurrent(settings) ? item.error : nil) }

    @ViewBuilder private var detail: some View {
        if failure != nil {
            Text("Failed")
        } else if let result = item.currentResult(settings) {
            Text("\(Format.bytes(item.fileSize)) → \(Format.bytes(result.byteCount))")
        } else {
            Text(Format.bytes(item.fileSize))
        }
    }

    @ViewBuilder private var trailing: some View {
        if item.isEncoding {
            ProgressView().controlSize(.mini)
        } else if let failure {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(DS.negative)
                .help(failure)
        } else if let savings = item.savings(settings) {
            SavingsText(fraction: savings)
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsPanel(settings: $model.settings)
                    if let item = model.selectedItem {
                        Rectangle().fill(DS.hairline).frame(height: 0.5)
                        ResultSummary(item: item, settings: model.settings)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            .contentMargins(.top, 0, for: .scrollContent)

            VStack(spacing: 6) {
                Button { model.saveAll() } label: {
                    HStack(spacing: 8) {
                        if model.isExporting { ProgressView().controlSize(.mini).tint(DS.canvas) }
                        Text(model.isExporting ? "Saving…" : "Save \(model.items.count) image\(model.items.count == 1 ? "" : "s")")
                        Text("⌘S").opacity(0.5)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isExporting || model.items.isEmpty)

                DestinationMenu()
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(DS.hairline).frame(height: 0.5) }
        }
    }
}

private struct ResultSummary: View {
    let item: ImageItem
    let settings: EncodeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Result")
            if let result = item.currentResult(settings), let savings = item.savings(settings) {
                Text(Format.savings(savings))
                    .font(.system(size: 30, weight: .light).monospacedDigit())
                    .foregroundStyle(savings >= 0 ? Color.primary : DS.negative)
                    .contentTransition(.numericText())
                Text("\(Format.bytes(item.fileSize)) → \(Format.bytes(result.byteCount))")
                    .font(.dsMono)
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(result.width) × \(result.height) · \(result.format.displayName)\(result.quality.map { " · q\($0)" } ?? "")")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                if let limit = settings.targetBytes, result.byteCount > Int64(limit) {
                    Text("Can't reach \(settings.targetKB ?? 0) KB at this size. Try resizing.")
                        .font(.dsCaption)
                        .foregroundStyle(DS.negative)
                }
            } else if let error = item.loadError ?? (item.isCurrent(settings) ? item.error : nil) {
                Text(error)
                    .font(.dsLabel)
                    .foregroundStyle(DS.negative)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    Text("—").font(.system(size: 30, weight: .light))
                    ProgressView().controlSize(.mini)
                }
                Text(Format.bytes(item.fileSize)).font(.dsMono).foregroundStyle(.secondary)
            }
        }
        .animation(.snappy(duration: 0.25), value: item.result?.byteCount)
    }
}

// MARK: - Settings panel (shared with Watch Folder)

struct SettingsPanel: View {
    @Binding var settings: EncodeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            formatSection
            if settings.format.supportsQuality || settings.format.supportsLossless || settings.format.supportsEffort {
                compressionSection
            }
            if settings.format == .png { pngSection }
            resizeSection
            if !settings.format.supportsAlpha {
                Text("Transparent areas are filled with white.")
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy(duration: 0.22), value: settings.format)
        .animation(.snappy(duration: 0.22), value: settings.resize.mode)
        .animation(.snappy(duration: 0.22), value: settings.reduceColors)
        .animation(.snappy(duration: 0.22), value: settings.targetKB != nil)
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Format")
            ChipGrid(options: OutputFormat.allCases, selection: $settings.format,
                     title: { $0 == .jxl ? "JXL" : $0.displayName },
                     isEnabled: { $0.isAvailable })
            if settings.format.isAvailable {
                Text(settings.format.blurb)
                    .font(.dsCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let command = settings.format.requiredTool?.installCommand {
                CommandHint(command: command)
            }
        }
    }

    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.format.supportsQuality {
                SectionLabel("Quality", value: settings.isLossless ? "—" : settings.targetBytes != nil ? "auto" : "\(Int(settings.quality))")
                LineSlider(value: $settings.quality, range: 1...100)
                    .disabled(settings.isLossless || settings.targetBytes != nil)
                FieldRow("Target size") {
                    HStack(spacing: 8) {
                        if settings.targetKB != nil {
                            DimensionField(prefix: "KB", value: Binding(
                                get: { settings.targetKB ?? 200 },
                                set: { settings.targetKB = max($0, 1) }))
                                .frame(width: 88)
                                .transition(.opacity)
                        }
                        MiniSwitch(isOn: Binding(
                            get: { settings.targetKB != nil },
                            set: { settings.targetKB = $0 ? 200 : nil }))
                    }
                }
                .disabled(settings.isLossless)
            }
            if settings.format.supportsLossless {
                FieldRow("Lossless") { MiniSwitch(isOn: $settings.lossless) }
            }
            if settings.format.supportsEffort {
                SectionLabel("Effort")
                    .padding(.top, 4)
                Segmented(options: Effort.allCases, selection: $settings.effort, title: \.title)
            }
        }
    }

    private var pngSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldRow("Reduce colors") {
                MiniSwitch(isOn: $settings.reduceColors).disabled(!ExternalTool.pngquant.isInstalled)
            }
            if settings.reduceColors && ExternalTool.pngquant.isInstalled {
                SectionLabel("Colors", value: "\(settings.colors)")
                LineSlider(value: Binding(get: { Double(settings.colors) }, set: { settings.colors = Int($0) }), range: 2...256)
            }
            if !ExternalTool.pngquant.isInstalled || !ExternalTool.oxipng.isInstalled {
                CommandHint(command: "brew install pngquant oxipng")
            }
        }
    }

    private var resizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Resize", value: settings.resize.mode == .percent ? "\(Int(settings.resize.percent))%" : nil)
            Segmented(options: ResizeOptions.Mode.allCases, selection: $settings.resize.mode, title: \.title)
            switch settings.resize.mode {
            case .original:
                EmptyView()
            case .percent:
                LineSlider(value: $settings.resize.percent, range: 5...100, step: 5)
            case .fit:
                HStack(spacing: 6) {
                    DimensionField(prefix: "W", value: $settings.resize.maxWidth)
                    Text("×").font(.dsCaption).foregroundStyle(.tertiary)
                    DimensionField(prefix: "H", value: $settings.resize.maxHeight)
                }
                FieldRow("Enlarge smaller images") { MiniSwitch(isOn: $settings.resize.allowUpscale) }
            }
        }
    }
}

struct CommandHint: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.leading, 10)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(DS.fill))
    }
}
