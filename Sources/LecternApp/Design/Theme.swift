import AppKit
import LecternCore
import SwiftUI

/// Lectern design tokens, taken once from the v1 screens: ivory canvas, charcoal ink,
/// muted green accent, blue for AI, amber for attention, red for rejection.
enum Theme {
    static let canvas = dynamic(light: 0xF7F5EF, dark: 0x1B1A17)
    static let sidebar = dynamic(light: 0xEFECE3, dark: 0x22211D)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x272621)
    static let inset = dynamic(light: 0xF3F1EB, dark: 0x2E2C27)
    static let border = dynamic(light: 0xE2DED3, dark: 0x3A3832)
    static let borderStrong = dynamic(light: 0xC9C4B7, dark: 0x4C4941)
    static let ink = dynamic(light: 0x1F1E1B, dark: 0xECE9E1)
    static let quiet = dynamic(light: 0x5F5C55, dark: 0xA8A49A)
    static let faint = dynamic(light: 0x8C887E, dark: 0x7C786F)

    static let accent = dynamic(light: 0x3E5C41, dark: 0x4F7553)
    static let accentText = dynamic(light: 0x3E5C41, dark: 0x8DB591)
    static let onAccent = Color(hex: 0xF7F5EF)

    static let ai = dynamic(light: 0x2F5D8C, dark: 0x8DB4DD)
    static let aiStrong = dynamic(light: 0x244A70, dark: 0xA9CBEE)
    static let aiWash = dynamic(light: 0xE3ECF5, dark: 0x22303E)

    static let good = dynamic(light: 0x3F7A4A, dark: 0x8EC497)
    static let goodWash = dynamic(light: 0xE7EFE6, dark: 0x233026)
    static let amber = dynamic(light: 0x7A4810, dark: 0xE2B47C)
    static let amberWash = dynamic(light: 0xF6EBDD, dark: 0x3A2E1E)
    static let bad = dynamic(light: 0xB3412E, dark: 0xE88E7D)
    static let badWash = dynamic(light: 0xF8E6E2, dark: 0x3C2520)

    static let diffRemovedText = dynamic(light: 0xA9661A, dark: 0xF0B072)
    static let diffRemovedWash = dynamic(light: 0xFBE6D5, dark: 0x45301C)
    static let diffAddedText = dynamic(light: 0x244A70, dark: 0xA9CBEE)
    static let diffAddedWash = dynamic(light: 0xDCE8F5, dark: 0x1F3448)

    static func stage(_ status: LectureProgressStatus) -> Color {
        switch status {
        case .done: dynamic(light: 0x3E5C41, dark: 0x5F8A63)
        case .toExport: dynamic(light: 0x9DBB9A, dark: 0x7E9E7B)
        case .toReview: dynamic(light: 0x6F94BC, dark: 0x6F94BC)
        case .preparing: dynamic(light: 0xD9B98A, dark: 0xB8996C)
        case .notImported: .clear
        }
    }

    // MARK: Type

    /// Headings use Newsreader when installed (the logo wordmark face), otherwise the system serif.
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if NSFont(name: "Newsreader", size: size) != nil {
            return .custom("Newsreader", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let eyebrow = Font.system(size: 10.5, weight: .semibold)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

// MARK: - Logo

/// The Lectern mark: an L whose foot rises into a reading desk and an approval tick.
nonisolated struct LogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [.init(x: 50, y: 32), .init(x: 94, y: 32), .init(x: 94, y: 146.4),
                                 .init(x: 184.5, y: 94.2), .init(x: 206.5, y: 132.3), .init(x: 50, y: 222.6)]
        let scale = min(rect.width, rect.height) / 256
        let dx = rect.minX + (rect.width - 256 * scale) / 2, dy = rect.minY + (rect.height - 256 * scale) / 2
        var path = Path()
        path.addLines(points.map { CGPoint(x: dx + $0.x * scale, y: dy + $0.y * scale) })
        path.closeSubpath()
        return path
    }
}

struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 8) {
            LogoMark().fill(Theme.accent).frame(width: size * 1.05, height: size * 1.05)
            Text("Lectern").font(Theme.serif(size)).foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lectern")
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(tint.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var foreground: Color = Theme.ink
    var stroke: Color = Theme.borderStrong
    var fill: Color = Theme.surface
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.inset : fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct LinkButtonStyle: ButtonStyle {
    var color: Color = Theme.accentText
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .underline()
            .foregroundStyle(color.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4))
            .contentShape(Rectangle())
    }
}

struct ChipButtonStyle: ButtonStyle {
    var isOn: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Theme.aiStrong : Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(isOn ? Theme.aiWash : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Theme.ai : Theme.borderStrong, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Two- or three-way segmented control styled like the mockups (green fill for the active segment).
struct SegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var activeFill: Color = Theme.accent
    var activeText: Color = Theme.onAccent

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let active = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? activeText : Theme.ink)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(active ? activeFill : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < options.count - 1 { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        }
        .fixedSize()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderStrong, lineWidth: 1))
    }
}

// MARK: - Containers and badges

struct PanelModifier: ViewModifier {
    var padding: CGFloat = 20
    var fill: Color = Theme.surface
    var stroke: Color = Theme.border
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(stroke, lineWidth: 1))
    }
}

extension View {
    func panel(padding: CGFloat = 20, fill: Color = Theme.surface, stroke: Color = Theme.border) -> some View {
        modifier(PanelModifier(padding: padding, fill: fill, stroke: stroke))
    }
    func eyebrow() -> some View {
        font(Theme.eyebrow).kerning(0.8).foregroundStyle(Theme.quiet).textCase(.uppercase)
    }
}

enum Tone {
    case neutral, good, ai, amber, bad, outline
    var text: Color {
        switch self {
        case .neutral, .outline: Theme.quiet
        case .good: Theme.good
        case .ai: Theme.aiStrong
        case .amber: Theme.amber
        case .bad: Theme.bad
        }
    }
    var wash: Color {
        switch self {
        case .neutral: Theme.inset
        case .good: Theme.goodWash
        case .ai: Theme.aiWash
        case .amber: Theme.amberWash
        case .bad: Theme.badWash
        case .outline: .clear
        }
    }
}

struct Pill: View {
    let text: String
    var tone: Tone = .neutral
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tone.text)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(tone.wash, in: Capsule())
            .overlay {
                if tone == .outline {
                    Capsule().strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .lineLimit(1)
            .fixedSize()
    }
}

struct LegendSwatch: View {
    let status: LectureProgressStatus
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.stage(status))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(status == .notImported ? Theme.borderStrong : .clear))
            .frame(width: 14, height: 14)
    }
}

/// One segment per planned lecture slot, coloured by lecture status.
struct SlotStrip: View {
    @Environment(AppModel.self) private var model
    let slots: [LectureSlot]
    var height: CGFloat = 26
    var onTap: ((LectureSlot) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = slots.count > 30 ? 2 : 5
            let width = max(4, (proxy.size.width - spacing * CGFloat(max(0, slots.count - 1))) / CGFloat(max(1, slots.count)))
            HStack(spacing: spacing) {
                ForEach(slots) { slot in
                    Button { onTap?(slot) } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(slot.status == .notImported ? Theme.surface : Theme.stage(slot.status))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(slot.status == .notImported ? Theme.borderStrong : .clear))
                            .overlay {
                                if slot.statusOverride != nil {
                                    Circle().fill(Theme.surface).frame(width: 5, height: 5)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(width: width, height: height)
                    }
                    .buttonStyle(.plain)
                    .help(Format.slotHelp(slot))
                    .accessibilityLabel(Format.slotHelp(slot))
                    .contextMenu {
                        if let lectureID = slot.lectureID {
                            LectureStatusOptions(current: slot.statusOverride) { status in
                                Task { await model.setLectureStatus(status, for: LectureRef(moduleID: slot.id.moduleID, lectureID: lectureID)) }
                            }
                        } else {
                            LectureStatusOptions(current: slot.statusOverride) { status in
                                Task { await model.setEmptySlotStatus(status, for: slot.id) }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lecture progress")
    }
}

struct LectureStatusOptions: View {
    let current: LectureProgressStatus?
    let onSelect: (LectureProgressStatus?) -> Void

    var body: some View {
        option("Automatic", status: nil)
        Divider()
        ForEach(Format.legendOrder.filter { $0 != .notImported }, id: \.self) { status in
            option(Format.statusLabel(status), status: status)
        }
    }

    private func option(_ title: String, status: LectureProgressStatus?) -> some View {
        Button {
            onSelect(status)
        } label: {
            if current == status { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
            Text(message).font(Theme.small).foregroundStyle(Theme.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button("Dismiss", action: dismiss).buttonStyle(LinkButtonStyle(color: Theme.quiet))
            }
        }
        .padding(10)
        .background(Theme.badWash, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ReadOnlyBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
            Text("This module is archived and read-only. Export still works; unarchive it in Module settings to make changes.")
        }
        .font(Theme.small)
        .foregroundStyle(Theme.amber)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amberWash)
    }
}
