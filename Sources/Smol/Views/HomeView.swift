import AppKit
import SmolCore
import SwiftUI
import UniformTypeIdentifiers

/// The circular launcher: drop images on a format to convert to it, on the hub to use the current format,
/// or click a segment to pick files.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hint: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 6)
            GeometryReader { geo in
                let diameter = min(geo.size.width * 0.86, geo.size.height * 0.92, 540)
                Dial(diameter: diameter, hint: $hint)
                    .frame(width: diameter, height: diameter)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            footer
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 24)
        .background(DS.canvas.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle("")
    }

    private var header: some View {
        VStack(spacing: 3) {
            Text("Smol")
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
            // Explains whatever the pointer or keyboard is on, in plain words.
            Text(hint ?? "Drop images on a format, or click one to choose files")
                .font(.dsLabel)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: hint)
                .id(hint)
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if !model.items.isEmpty {
                Button { model.screen = .editor } label: {
                    HStack(spacing: 5) {
                        Text("\(model.items.count) in editor")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(QuietButtonStyle())
            }
            if model.watcher.isWatching {
                Button { model.screen = .watch } label: {
                    HStack(spacing: 6) {
                        Circle().fill(DS.positive).frame(width: 6, height: 6)
                        Text("Watching \(model.watcher.config.inputURL.lastPathComponent)")
                    }
                }
                .buttonStyle(QuietButtonStyle())
            }
            HStack(spacing: 6) {
                Text("Choose").font(.dsCaption).foregroundStyle(.tertiary)
                Keycap(text: "←")
                Keycap(text: "→")
                Keycap(text: "↩")
            }
            HStack(spacing: 6) {
                Text("Paste").font(.dsCaption).foregroundStyle(.tertiary)
                Keycap(text: "⇧⌘V")
            }
            HStack(spacing: 6) {
                Text("Watch folder").font(.dsCaption).foregroundStyle(.tertiary)
                Keycap(text: "⇧⌘F")
            }
        }
        .frame(height: 30)
    }
}

// MARK: - Dial

private enum DialAction: Equatable {
    case format(OutputFormat)
    case resize
    case watch
}

private struct DialEntry: Identifiable {
    let title: String
    let detail: String
    let action: DialAction
    var id: String { title }
}

private enum DialRegion: Equatable {
    case hub
    case wedge(Int)
}

private struct Dial: View {
    @Environment(AppModel.self) private var model
    let diameter: CGFloat
    @Binding var hint: String?

    @State private var hovered: DialRegion?
    @State private var dropTarget: DialRegion?
    @State private var keyboardIndex: Int?
    @State private var indicatorAngle: Double = -90
    @State private var appeared = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let entries: [DialEntry] = [
        DialEntry(title: "AVIF", detail: "smallest", action: .format(.avif)),
        DialEntry(title: "WebP", detail: "web", action: .format(.webp)),
        DialEntry(title: "JPEG XL", detail: "next-gen", action: .format(.jxl)),
        DialEntry(title: "HEIC", detail: "apple", action: .format(.heic)),
        DialEntry(title: "JPEG", detail: "universal", action: .format(.jpeg)),
        DialEntry(title: "PNG", detail: "lossless", action: .format(.png)),
        DialEntry(title: "Resize", detail: "fit 1920", action: .resize),
        DialEntry(title: "Watch", detail: "folder", action: .watch),
    ]

    private let innerFraction: CGFloat = 0.40
    private var radius: CGFloat { diameter / 2 }
    private var step: Double { 360 / Double(entries.count) }

    var body: some View {
        ZStack {
            Circle().fill(DS.disc)
            Circle().strokeBorder(DS.hairline, lineWidth: 1)

            ForEach(entries.indices, id: \.self) { index in
                let start = Angle.degrees(-90 - step / 2 + Double(index) * step)
                Wedge(start: start, end: start + .degrees(step), innerFraction: innerFraction)
                    .fill(wedgeFill(.wedge(index)))
            }

            ForEach(entries.indices, id: \.self) { index in
                Spoke(angle: .degrees(-90 - step / 2 + Double(index) * step), innerFraction: innerFraction)
                    .stroke(DS.hairline.opacity(0.8), lineWidth: 1)
            }

            // Gliding indicator on the outer edge: follows the pointer, rests on the current format.
            RingArc(center: indicatorAngle, span: step - 10, inset: 1.5)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .opacity(indicatorIndex == nil ? 0 : 1)

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                label(entry, index: index)
            }

            hub
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: dropTarget)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                guard !AppModel.ignoresPointer else { return }
                hovered = region(at: point)
                keyboardIndex = nil
            case .ended: hovered = nil
            }
        }
        // Keyboard: arrows travel round the dial, Return opens, 1–8 jump straight to a segment.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.rightArrow) { stepKeyboard(1) }
        .onKeyPress(.downArrow) { stepKeyboard(1) }
        .onKeyPress(.leftArrow) { stepKeyboard(-1) }
        .onKeyPress(.upArrow) { stepKeyboard(-1) }
        .onKeyPress(.return) { activateKeyboard() }
        .onKeyPress(.space) { activateKeyboard() }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = Int(press.characters), (1...entries.count).contains(digit) else { return .ignored }
            keyboardIndex = digit - 1
            activate(.wedge(digit - 1))
            return .handled
        }
        .onTapGesture { point in activate(region(at: point)) }
        .onDrop(of: [.fileURL], delegate: DialDropDelegate(
            region: { region(at: $0) },
            target: $dropTarget,
            perform: { region, urls in handleDrop(urls, on: region) }))
        .onAppear {
            if let index = indicatorIndex { indicatorAngle = angle(of: index) }
            isFocused = true
            if reduceMotion { appeared = true } else { withAnimation(.spring(duration: 0.5, bounce: 0.2)) { appeared = true } }
        }
        .onChange(of: indicatorIndex) { _, index in
            guard let index else { return }
            moveIndicator(to: index)
            // A soft trackpad tick as a dragged file crosses into the next segment.
            if dropTarget != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        .onChange(of: activeRegion) { _, region in hint = explanation(for: region) }
        .onChange(of: dropTarget) { old, new in
            if old != .hub && new == .hub {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    // MARK: Pieces

    private func wedgeFill(_ region: DialRegion) -> Color {
        if dropTarget == region { return Color.primary.opacity(0.07) }
        if hovered == region { return Color.primary.opacity(0.035) }
        return .clear
    }

    private func label(_ entry: DialEntry, index: Int) -> some View {
        let mid = angle(of: index) * .pi / 180
        let labelRadius = radius * (innerFraction + (1 - innerFraction) * 0.5)
        let available = isAvailable(entry)
        let active = indicatorIndex == index

        return VStack(spacing: 3) {
            Text(entry.title)
                .font(.system(size: max(12, diameter * 0.027), weight: active ? .semibold : .medium))
                .foregroundStyle(available ? .primary : .tertiary)
            HStack(spacing: 4) {
                if entry.action == .watch && model.watcher.isWatching {
                    Circle().fill(DS.positive).frame(width: 5, height: 5)
                }
                Text(detail(for: entry, available: available))
                    .font(.system(size: max(10, diameter * 0.02)))
                    .foregroundStyle(.tertiary)
            }
        }
        .offset(x: cos(mid) * labelRadius, y: sin(mid) * labelRadius)
        // Labels settle outward from the hub, one after another.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.15).delay(0.04 + Double(index) * 0.03), value: appeared)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName(for: entry, available: available))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(.wedge(index)) }
    }

    private func accessibilityName(for entry: DialEntry, available: Bool) -> String {
        switch entry.action {
        case .format(let format): available ? "Convert to \(format.displayName)" : "\(format.displayName), not installed"
        case .resize: "Resize to fit 1920 pixels"
        case .watch: model.watcher.isWatching ? "Watch Folder, running" : "Watch Folder"
        }
    }

    private func detail(for entry: DialEntry, available: Bool) -> String {
        if !available { return "not installed" }
        if entry.action == .watch && model.watcher.isWatching { return "running" }
        return entry.detail
    }

    private var hub: some View {
        let size = diameter * innerFraction - 16
        let isTarget = dropTarget == .hub
        return ZStack {
            Circle()
                .fill(DS.raised)
                .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
                .shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)
            Circle()
                .strokeBorder(isTarget ? Color.primary : DS.hairline, lineWidth: isTarget ? 1.5 : 0.5)
            VStack(spacing: 6) {
                Image(systemName: isTarget ? "arrow.down" : "plus")
                    .font(.system(size: size * 0.1, weight: .regular))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: size * 0.13)
                Text(isTarget ? "Release to add" : "Drop images")
                    .font(.system(size: max(12, size * 0.075), weight: .medium))
                Text("as \(model.settings.format.displayName)")
                    .font(.system(size: max(10, size * 0.058)))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(isTarget ? 1.03 : hovered == .hub ? 1.01 : appeared ? 1 : 0.94)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2), value: isTarget)
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: hovered)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Choose images to convert to \(model.settings.format.displayName)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(.hub) }
    }

    // MARK: Hint

    private var activeRegion: DialRegion? {
        dropTarget ?? hovered ?? keyboardIndex.map { .wedge($0) }
    }

    private func explanation(for region: DialRegion?) -> String? {
        switch region {
        case .hub:
            return "Choose images to convert to \(model.settings.format.displayName)"
        case .wedge(let index):
            switch entries[index].action {
            case .format(let format):
                return format.isAvailable ? "\(format.displayName): \(format.blurb)"
                    : "\(format.displayName) needs one install: \(format.requiredTool?.installCommand ?? "")"
            case .resize: return "Shrink images to fit within 1920 pixels, keeping the current format setting"
            case .watch: return "Convert a whole folder, or keep converting new files as they arrive"
            }
        case nil:
            return nil
        }
    }

    // MARK: Indicator

    private var indicatorIndex: Int? {
        if case .wedge(let index) = dropTarget { return index }
        if case .wedge(let index) = hovered { return index }
        if let keyboardIndex { return keyboardIndex }
        return entries.firstIndex { $0.action == .format(model.settings.format) }
    }

    private func angle(of index: Int) -> Double { -90 + Double(index) * step }

    /// Always travels the short way round.
    private func moveIndicator(to index: Int) {
        var delta = (angle(of: index) - indicatorAngle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        if reduceMotion {
            indicatorAngle += delta
        } else {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { indicatorAngle += delta }
        }
    }

    private func stepKeyboard(_ direction: Int) -> KeyPress.Result {
        let current = keyboardIndex ?? indicatorIndex ?? 0
        keyboardIndex = (current + direction + entries.count) % entries.count
        return .handled
    }

    private func activateKeyboard() -> KeyPress.Result {
        if let keyboardIndex { activate(.wedge(keyboardIndex)) } else { activate(.hub) }
        return .handled
    }

    // MARK: Hit testing & actions

    private func region(at point: CGPoint) -> DialRegion? {
        let dx = point.x - radius, dy = point.y - radius
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > radius { return nil }
        if distance < radius * innerFraction { return .hub }
        var degrees = atan2(dy, dx) * 180 / .pi + 90 + step / 2
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return .wedge(min(Int(degrees / step), entries.count - 1))
    }

    private func isAvailable(_ entry: DialEntry) -> Bool {
        if case .format(let format) = entry.action { return format.isAvailable }
        return true
    }

    private func activate(_ region: DialRegion?) {
        switch region {
        case .hub:
            model.presentOpenPanel()
        case .wedge(let index):
            switch entries[index].action {
            case .format(let format):
                guard format.isAvailable else { return showMissing(format) }
                model.presentOpenPanel(format: format)
            case .resize:
                model.presentOpenPanel(resize: ResizeOptions(mode: .fit, maxWidth: 1920, maxHeight: 1920))
            case .watch:
                model.screen = .watch
            }
        case nil:
            break
        }
    }

    private func handleDrop(_ urls: [URL], on region: DialRegion?) {
        switch region {
        case .hub, nil:
            model.add(urls: urls)
        case .wedge(let index):
            switch entries[index].action {
            case .format(let format):
                guard format.isAvailable else { return showMissing(format) }
                model.add(urls: urls, format: format)
            case .resize:
                model.add(urls: urls, resize: ResizeOptions(mode: .fit, maxWidth: 1920, maxHeight: 1920))
            case .watch:
                // Dropping a folder here makes it the watched input folder.
                var isDirectory: ObjCBool = false
                if let folder = urls.first, FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    model.watcher.config.inputPath = folder.path
                    model.showToast("Watching from \(folder.lastPathComponent)")
                } else {
                    model.showToast("Drop a folder here to watch it")
                }
                model.screen = .watch
            }
        }
    }

    private func showMissing(_ format: OutputFormat) {
        model.showToast("\(format.displayName) needs \(format.requiredTool?.installCommand ?? "a newer macOS")")
    }
}

private struct DialDropDelegate: DropDelegate {
    let region: (CGPoint) -> DialRegion?
    @Binding var target: DialRegion?
    let perform: (DialRegion?, [URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) { target = region(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let current = region(info.location)
        if current != target { target = current }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        let dropRegion = region(info.location)
        target = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() { urls.append(url) }
            }
            if !urls.isEmpty { perform(dropRegion, urls) }
        }
        return true
    }
}

extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

// MARK: - Shapes

private struct Wedge: Shape {
    let start: Angle
    let end: Angle
    let innerFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: outer * innerFraction, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct Spoke: Shape {
    let angle: Angle
    let innerFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let dx = cos(angle.radians), dy = sin(angle.radians)
        var path = Path()
        path.move(to: CGPoint(x: center.x + dx * outer * innerFraction, y: center.y + dy * outer * innerFraction))
        path.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
        return path
    }
}

private struct RingArc: Shape {
    var center: Double
    let span: Double
    let inset: CGFloat

    var animatableData: Double {
        get { center }
        set { center = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - inset
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(center - span / 2), endAngle: .degrees(center + span / 2), clockwise: false)
        return path
    }
}
