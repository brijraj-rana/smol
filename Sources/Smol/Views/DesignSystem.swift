import AppKit
import SwiftUI

// MARK: - Tokens

/// Monochrome, hairline-driven system. Color is reserved for meaning: green = saved / running, red = error.
enum DS {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Image canvas: a quiet neutral that lets photos read true.
    static let sunken = dynamic(light: NSColor(white: 0.925, alpha: 1), dark: NSColor(white: 0.105, alpha: 1))
    static let hairline = Color(nsColor: .separatorColor)
    static let fill = Color.primary.opacity(0.05)
    static let fillStrong = Color.primary.opacity(0.09)
    static let positive = Color(nsColor: .systemGreen)
    static let negative = Color(nsColor: .systemRed)

    /// A surface that sits above the canvas: white in light mode, a lifted gray in dark mode.
    static let raised = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.10))
    /// The dial face: barely lighter than the canvas.
    static let disc = dynamic(light: NSColor(white: 1, alpha: 0.5), dark: NSColor(white: 1, alpha: 0.025))

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension Font {
    static let dsCaption = Font.system(size: 11)
    static let dsLabel = Font.system(size: 12)
    static let dsBody = Font.system(size: 13)
    static let dsMono = Font.system(size: 12).monospacedDigit()
    static let dsMonoSmall = Font.system(size: 11).monospacedDigit()
}

extension View {
    func dsCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline.opacity(0.8), lineWidth: 0.5))
    }
}

// MARK: - Text

struct SectionLabel: View {
    let title: String
    var value: String?

    init(_ title: String, value: String? = nil) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(value)
                    .font(.dsMono)
                    .contentTransition(.numericText())
            }
        }
    }
}

struct SavingsText: View {
    let fraction: Double
    var font: Font = .dsMonoSmall

    var body: some View {
        Text(Format.savings(fraction))
            .font(font)
            .foregroundStyle(fraction >= 0 ? DS.positive : DS.negative)
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(DS.hairline, lineWidth: 1))
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).font(.dsLabel).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: 24)
    }
}

struct MiniSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
    }
}

// MARK: - Controls

/// Grid of text chips. The selected one is inverted (solid primary).
struct ChipGrid<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var isEnabled: (Option) -> Bool = { _ in true }
    var columns = 3

    @State private var hovered: Option?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AnyShapeStyle(DS.canvas)
                                         : isEnabled(option) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color.primary : hovered == option ? DS.fillStrong : DS.fill))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = option } else if hovered == option { hovered = nil }
                }
                .help(isEnabled(option) ? "" : "Not installed")
            }
        }
        .animation(.easeOut(duration: 0.12), value: selection)
        .animation(.easeOut(duration: 0.08), value: hovered)
    }
}

/// Segmented control with a sliding thumb.
struct Segmented<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(DS.raised)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(DS.fill))
    }
}

/// A thin slider: 3pt track, solid fill, small knob that grows while dragging.
struct LineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    @State private var isDragging = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(DS.fillStrong).frame(height: 3)
                Capsule().fill(Color.primary).frame(width: x, height: 3)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .scaleEffect(isDragging ? 1.18 : 1)
                    .offset(x: x - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let f = min(max(drag.location.x / width, 0), 1)
                        let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        let stepped = (raw / step).rounded() * step
                        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
                        if clamped != value { value = clamped }
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }
}

struct DimensionField: View {
    let prefix: String
    @Binding var value: Int
    /// When set, the field can be cleared: empty means 0 and shows this word instead.
    var emptyLabel: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(prefix).font(.dsCaption).foregroundStyle(.tertiary)
            Group {
                if let emptyLabel {
                    TextField(emptyLabel, value: Binding<Int?>(
                        get: { value > 0 ? value : nil },
                        set: { value = max($0 ?? 0, 0) }), format: .number.grouping(.never))
                } else {
                    TextField("", value: $value, format: .number.grouping(.never))
                }
            }
            .textFieldStyle(.plain)
            .font(.dsMono)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(DS.fill))
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.canvas)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(configuration.isPressed ? 0.78 : 1)))
            .opacity(isEnabled ? 1 : 0.3)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }

    private struct SecondaryButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? DS.fillStrong : hovering ? DS.fillStrong.opacity(0.8) : DS.fill))
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hovering = $0 }
        }
    }
}

/// Text-only button that brightens on hover. For tertiary actions.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration)
    }

    private struct QuietButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.dsLabel)
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? DS.fill : .clear))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

/// Square icon button for floating toolbars.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(minWidth: 26, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.fill : .clear))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}
