// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import SwiftUI
import UIKit
import HerdrKit

// Herdr Companion compact session desk. Palette stays Switchyard:
// charcoal #211E1A, limestone #E9DDCA, vermilion #E64B2F,
// warm-stone light #E8DDCB with ink #27231F. Status colour is meaning, always
// paired with a text label. Chrome uses system type; monospaced type is only
// for terminals, keys and filesystem paths. Vermilion is reserved for
// actions/selection, not body text.

enum Palette {
    enum Token {
        static let cardLight: UInt32 = 0xF4EDE1
        static let cardDark: UInt32 = 0x2A2622
        static let textFaintLight: UInt32 = 0x5E564E
        static let textFaintDark: UInt32 = 0xC4BBB0
        static let textDimLight: UInt32 = 0x5C534A
        static let textDimDark: UInt32 = 0xB8AFA4
        static let waitingLight: UInt32 = 0x7A4E0E
        static let waitingDark: UInt32 = 0xE0A84A
        static let accentLight: UInt32 = 0xC0392B
        static let accentDark: UInt32 = 0xF05A40
        static let accentOnLight: UInt32 = 0xFFF8F2
        static let accentOnDark: UInt32 = 0x211E1A
        static let workingLight: UInt32 = 0x276355
        static let workingDark: UInt32 = 0x4AA894
        static let doneLight: UInt32 = 0x3A6234
        static let doneDark: UInt32 = 0x6BA85A
        static let diedLight: UInt32 = 0x8E3428
        static let diedDark: UInt32 = 0xE08A7C
    }

    static let ground = Color(light: 0xE8DDCB, dark: 0x211E1A)
    static let groundDeep = Color(light: 0xDDD0BA, dark: 0x181512)
    static let surface = Color(light: Token.cardLight, dark: Token.cardDark)
    static let card = surface
    static let surfaceRaised = Color(light: 0xE0D4C2, dark: 0x35302B)
    static let cardRaised = surfaceRaised
    static let hairline = Color(light: 0xD2C4B0, dark: 0x433E38)
    static let hairlineQuiet = Color(light: 0xDDD1BF, dark: 0x2F2B26)

    static let text = Color(light: 0x27231F, dark: 0xE9DDCA)
    static let textDim = Color(light: Token.textDimLight, dark: Token.textDimDark)
    static let textFaint = Color(light: Token.textFaintLight, dark: Token.textFaintDark)

    /// Switchyard vermilion. Not purple or blue. Not used for small body text.
    static let accent = Color(light: Token.accentLight, dark: Token.accentDark)
    static let accentOn = Color(light: Token.accentOnLight, dark: Token.accentOnDark)
    static let brand = accent

    static let waiting = Color(light: Token.waitingLight, dark: Token.waitingDark)
    static let died = Color(light: Token.diedLight, dark: Token.diedDark)
    static let working = Color(light: Token.workingLight, dark: Token.workingDark)
    static let done = Color(light: Token.doneLight, dark: Token.doneDark)

    /// Terminal only — charcoal, matching the icon field.
    static let groundMachine = Color(hex: 0x211E1A)
    static let machineInk = Color(hex: 0xE9DDCA)
    static let machineDim = Color(hex: 0xA89F93)
}


enum PaletteContrast {
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func ratio(_ foreground: UInt32, _ background: UInt32) -> Double {
        let a = relativeLuminance(foreground)
        let b = relativeLuminance(background)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

enum Typography {
    /// Inherited unused screens still write this. Companion chrome uses
    /// semantic text styles instead of a numeric scale.
    static var scale: CGFloat = 1

    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ...11: return .caption2
        case ...12: return .caption
        case ...13: return .footnote
        case ...14: return .subheadline
        case ...16: return .body
        case ...17: return .headline
        case ...20: return .title3
        default: return .title2
        }
    }

    /// Semantic system type for app chrome. Dynamic Type scales the style.
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(textStyle(for: size), design: .default, weight: weight)
    }

    /// Monospace for terminal output, keys, and filesystem paths only.
    static func machine(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(plexMonoName(weight), size: size, relativeTo: textStyle(for: size))
    }

    static var microLabel: Font { .custom("IBMPlexMono-SmBld", size: 11, relativeTo: .caption2) }

    private static func plexMonoName(_ w: Font.Weight) -> String {
        switch w {
        case .medium: return "IBMPlexMono-Medm"
        case .semibold: return "IBMPlexMono-SmBld"
        case .bold, .heavy, .black: return "IBMPlexMono-Bold"
        default: return "IBMPlexMono"
        }
    }
}

enum CompanionPathLabel {
    static func folder(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let last = URL(fileURLWithPath: path).lastPathComponent
        if last.isEmpty || last == "/" { return nil }
        return last
    }

    static func components(_ path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    /// Shortest unique trailing path among other items, including identical paths.
    static func uniqueSuffix(path: String?, among others: [String?]) -> String? {
        let parts = components(path)
        guard !parts.isEmpty else { return nil }
        let otherParts = others.compactMap { $0 }.map(components)
        for count in 1...parts.count {
            let token = parts.suffix(count)
            let collision = otherParts.contains { $0.suffix(count).elementsEqual(token) }
            if !collision {
                return count == 1 ? nil : token.joined(separator: "/")
            }
        }
        return parts.joined(separator: "/")
    }

    static func visiblePrefix(_ title: String, limit: Int = 10) -> String {
        if title.count <= limit { return title }
        return String(title.prefix(limit))
    }
}

struct CompanionTargetContext {
    let title: String
    let workspace: String?
    let path: String?
    let paneID: String

    var folder: String? { CompanionPathLabel.folder(path) }

    var compactIdentity: String {
        [title, workspace, folder].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "|")
    }

    var visibleIdentity: String {
        [CompanionPathLabel.visiblePrefix(title), workspace, folder]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "|")
    }

    /// Workspace + leaf, ignoring title width. Normal rows ellipsize by geometry,
    /// not a fixed character count, so titles that differ before a guessed cutoff
    /// still collide on screen when they share this layout identity.
    var layoutIdentity: String {
        [workspace, folder].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "|")
    }

    var fullContext: String {
        [title, workspace, path, paneID].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func uniquePaneHint(paneID: String, among ids: [String]) -> String {
        let others = ids.filter { $0 != paneID }
        let maxN = max(4, paneID.count)
        for n in 4...maxN {
            let hint = String(paneID.suffix(n))
            if others.allSatisfy({ String($0.suffix(n)) != hint }) {
                return hint
            }
        }
        return paneID
    }

    static func discriminators(for items: [CompanionTargetContext]) -> [String: String] {
        var result: [String: String] = [:]
        func assign(_ group: [CompanionTargetContext]) {
            guard group.count > 1 else { return }
            let ids = group.map(\.paneID)
            var proposed: [String: String] = [:]
            for item in group {
                let others = group.filter { $0.paneID != item.paneID }.map(\.path)
                if let suffix = CompanionPathLabel.uniqueSuffix(path: item.path, among: others) {
                    proposed[item.paneID] = suffix
                }
            }
            let suffixCounts = Dictionary(grouping: proposed.values, by: { $0 }).mapValues(\.count)
            for item in group {
                if let suffix = proposed[item.paneID], suffixCounts[suffix] == 1 {
                    result[item.paneID] = suffix
                } else {
                    result[item.paneID] = uniquePaneHint(paneID: item.paneID, among: ids)
                }
            }
        }
        Dictionary(grouping: items, by: \.compactIdentity).values.forEach(assign)
        Dictionary(grouping: items, by: \.visibleIdentity).values.forEach(assign)
        Dictionary(grouping: items, by: \.layoutIdentity).values.forEach(assign)
        Dictionary(grouping: items, by: { $0.path ?? "" }).values.forEach { group in
            guard group.count > 1, !(group.first?.path ?? "").isEmpty else { return }
            assign(group)
        }
        return result
    }
}

extension AgentGroup {
    var color: Color {
        switch self {
        case .needsYou: return Palette.waiting
        case .stopped: return Palette.died
        case .unrecognised: return Palette.waiting
        case .working: return Palette.working
        case .idle: return Palette.textFaint
        }
    }

    var sectionTitle: String {
        switch self {
        case .needsYou: return "Needs you"
        case .stopped: return "Stopped"
        case .unrecognised: return "Unknown status"
        case .working: return "Running"
        case .idle: return "Idle"
        }
    }

    var spokenLabel: String { sectionTitle }
}

enum AgentIdentity {
    static func glyph(for agent: String?) -> String {
        switch (agent ?? "").lowercased() {
        case let s where s.contains("claude"): return "\u{2731}"
        case let s where s.contains("codex"): return "C"
        case let s where s.contains("gemini"): return "\u{2726}"
        default:
            let first = String((agent ?? "").trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            return first.isEmpty ? "?" : first
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgba: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgba hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

struct TurningRing: View {
    var color: Color
    var diameter: CGFloat = 13
    var lineWidth: CGFloat = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(reduceMotion ? 40 : (spin ? 360 : 0)))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

struct PulsingDot: View {
    var color: Color
    var active: Bool
    var diameter: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .opacity(shouldPulse && pulse ? 0.4 : 1)
            .scaleEffect(shouldPulse && pulse ? 1.35 : 1)
            .onAppear { if shouldPulse { startPulsing() } }
            .onChange(of: active) { _, isActive in
                pulse = false
                if isActive && !reduceMotion { startPulsing() }
            }
    }

    private var shouldPulse: Bool { active && !reduceMotion }

    private func startPulsing() {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
