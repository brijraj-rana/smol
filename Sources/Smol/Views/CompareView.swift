import AppKit
import SmolCore
import SwiftUI

/// Original on the left, compressed on the right, split by a draggable divider.
/// Pinch or ⌘-scroll to zoom, drag or two-finger scroll to pan, double-click to toggle 1:1.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    let item: ImageItem

    @State private var split: CGFloat = 0.5
    @State private var zoom: CGFloat?          // nil = fit
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var magnifyStart: CGFloat?
    @State private var canvasSize: CGSize = .zero
    @State private var isHovering = false
    @State private var isDraggingDivider = false
    @State private var scrollMonitor: Any?

    private var isCurrent: Bool { item.isCurrent(model.settings) }

    var body: some View {
        GeometryReader { geo in
            let canvas = geo.size
            ZStack {
                DS.sunken

                if let original = item.original {
                    let scale = currentScale(canvas: canvas)
                    let display = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

                    positioned(Checkerboard().frame(width: display.width, height: display.height))

                    positioned(image(original, display: display, scale: scale))
                        .clipShape(SplitClip(fraction: split, leading: true))

                    Group {
                        if let preview = item.preview, isCurrent {
                            positioned(image(preview, display: display, scale: scale))
                        } else {
                            positioned(image(original, display: display, scale: scale).blur(radius: 18).opacity(0.35))
                        }
                    }
                    .clipShape(SplitClip(fraction: split, leading: false))

                    divider(canvas: canvas)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .coordinateSpace(name: "canvas")
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture)
            .simultaneousGesture(magnifyGesture(canvas: canvas))
            .onTapGesture(count: 2) { withAnimation(.snappy) { toggleZoom() } }
            .onAppear { canvasSize = canvas }
            .onChange(of: canvas) { _, newValue in canvasSize = newValue }
            .overlay(alignment: .topLeading) { originalTag.padding(12) }
            .overlay(alignment: .topTrailing) { outputTag.padding(12) }
            .overlay(alignment: .bottom) { zoomBar.padding(.bottom, 14) }
        }
        .onHover { isHovering = $0 }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
    }

    // MARK: Layers

    private func positioned(_ content: some View) -> some View {
        content
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func image(_ image: CGImage, display: CGSize, scale: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(scale >= 2 ? .none : .high)
            .frame(width: display.width, height: display.height)
    }

    private func divider(canvas: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 1)
                .shadow(color: .black.opacity(0.25), radius: 1)
            Capsule()
                .fill(.white)
                .frame(width: isDraggingDivider ? 6 : 5, height: isDraggingDivider ? 40 : 30)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .frame(width: 24)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .position(x: canvas.width * split, y: canvas.height / 2)
        .animation(.spring(duration: 0.25), value: isDraggingDivider)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    isDraggingDivider = true
                    split = min(max(value.location.x / max(canvas.width, 1), 0), 1)
                }
                .onEnded { _ in isDraggingDivider = false }
        )
        .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
    }

    // MARK: Chrome

    private var originalTag: some View {
        Tag(title: "Original",
            detail: [item.info?.formatName, Format.bytes(item.fileSize)].compactMap { $0 }.joined(separator: "  "))
    }

    @ViewBuilder private var outputTag: some View {
        if let result = item.currentResult(model.settings) {
            Tag(title: result.format.displayName, detail: Format.bytes(result.byteCount), savings: item.savings(model.settings))
        } else if isCurrent, let error = item.error {
            Tag(title: "Failed", detail: error, isError: true)
        } else {
            Tag(title: model.settings.format.displayName, detail: "Compressing", isLoading: true)
        }
    }

    private var zoomBar: some View {
        let percent = Int((currentScale(canvas: canvasSize) * 100).rounded())
        return HStack(spacing: 0) {
            Button { zoomBy(1 / 1.25) } label: { Image(systemName: "minus") }
                .keyboardShortcut("-", modifiers: .command)
            Text("\(percent)%")
                .font(.dsMonoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 44)
                .contentTransition(.numericText())
            Button { zoomBy(1.25) } label: { Image(systemName: "plus") }
                .keyboardShortcut("=", modifiers: .command)
            Rectangle().fill(DS.hairline).frame(width: 0.5, height: 14).padding(.horizontal, 4)
            Button("Fit") { withAnimation(.snappy) { zoom = nil; offset = .zero } }
                .keyboardShortcut("0", modifiers: .command)
            Button("1:1") { withAnimation(.snappy) { zoom = 1; offset = .zero } }
                .keyboardShortcut("1", modifiers: .command)
        }
        .buttonStyle(IconButtonStyle())
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.hairline.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    // MARK: Zoom & pan

    private var imageSize: CGSize {
        if let original = item.original { return CGSize(width: original.width, height: original.height) }
        if let info = item.info { return CGSize(width: info.width, height: info.height) }
        return CGSize(width: 1, height: 1)
    }

    private func currentScale(canvas: CGSize) -> CGFloat {
        if let zoom { return zoom }
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        return min((canvas.width - 48) / imageSize.width, (canvas.height - 96) / imageSize.height, 1)
    }

    private func setScale(_ newScale: CGFloat) {
        let old = currentScale(canvas: canvasSize)
        let clamped = min(max(newScale, 0.02), 32)
        offset = CGSize(width: offset.width * clamped / old, height: offset.height * clamped / old)
        zoom = clamped
    }

    private func zoomBy(_ factor: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) { setScale(currentScale(canvas: canvasSize) * factor) }
    }

    private func toggleZoom() {
        if zoom == nil {
            zoom = 1
        } else {
            zoom = nil
            offset = .zero
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = panStart ?? offset
                panStart = start
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private func magnifyGesture(canvas: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnifyStart ?? currentScale(canvas: canvas)
                magnifyStart = start
                setScale(start * value.magnification)
            }
            .onEnded { _ in magnifyStart = nil }
    }

    /// Trackpad scroll pans; mouse wheel or ⌘-scroll zooms.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }
            if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : (event.scrollingDeltaY > 0 ? 0.12 : -0.12)
                setScale(currentScale(canvas: canvasSize) * (1 + delta))
            } else {
                offset = CGSize(width: offset.width + event.scrollingDeltaX, height: offset.height + event.scrollingDeltaY)
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

private struct Tag: View {
    let title: String
    let detail: String
    var savings: Double?
    var isError = false
    var isLoading = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isError ? DS.negative : .primary)
            if isLoading { ProgressView().controlSize(.mini) }
            Text(detail)
                .font(.dsMonoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let savings { SavingsText(fraction: savings) }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.hairline.opacity(0.6), lineWidth: 0.5))
        .frame(maxWidth: 340, alignment: .leading)
    }
}

private struct SplitClip: Shape {
    var fraction: CGFloat
    let leading: Bool

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let x = rect.width * fraction
        return Path(leading
            ? CGRect(x: 0, y: 0, width: x, height: rect.height)
            : CGRect(x: x, y: 0, width: rect.width - x, height: rect.height))
    }
}

/// Transparency grid, drawn only beneath the image.
struct Checkerboard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            let light = colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.98)
            let dark = colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.92)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var path = Path()
            for row in 0..<Int(size.height / tile) + 1 {
                for column in 0..<Int(size.width / tile) + 1 where (row + column) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            context.fill(path, with: .color(dark))
        }
    }
}
