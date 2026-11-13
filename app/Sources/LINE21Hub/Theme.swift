import AppKit
import SwiftUI

/// LINE21 design tokens, taken from line21-website (app/globals.css): dark teal, hard offset
/// shadows, 2–3 px frames, mono labels and a light VHS layer (scanlines, red/cyan split).
enum L21 {
    static let bg = dynamic(light: 0xF8F9FA, dark: 0x0A1A1A)
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x11272A)
    static let accent = dynamic(light: 0x1A1A1A, dark: 0x34C0AE)
    static let accentSoft = dynamic(light: 0x636E72, dark: 0x7DD3C0)
    static let muted = dynamic(light: 0x8A969B, dark: 0x5BB3A0)
    static let ink = dynamic(light: 0x0A0A0A, dark: 0xE8FFFB)
    static let line = dynamic(light: 0xDDE2E5, dark: 0x2D4A4A)
    static let onAccent = dynamic(light: 0xF8F9FA, dark: 0x0A1A1A)
    static let teal = Color(hex: 0x34C0AE)
    static let red = Color(hex: 0xFF3050)
    static let cyan = Color(hex: 0x28D2FF)
    static let amber = Color(hex: 0xF2B84B)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// Uppercase mono label with tracking, like the website's tags.
struct Tag: View {
    var text: String
    var color: Color = L21.accentSoft
    var body: some View {
        Text(text.uppercased()).font(L21.mono(10.5)).tracking(1.4).foregroundStyle(color)
    }
}

/// Frame with a hard, unblurred offset shadow.
struct HardFrame: ViewModifier {
    var color: Color = L21.accent
    var offset: CGFloat = 6
    var lineWidth: CGFloat = 2
    var fill: Color = L21.bg

    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay(Rectangle().strokeBorder(color, lineWidth: lineWidth))
            .background(Rectangle().fill(color).offset(x: offset, y: offset))
            .padding(.trailing, offset)
            .padding(.bottom, offset)
    }
}

extension View {
    func hardFrame(_ color: Color = L21.accent, offset: CGFloat = 6, lineWidth: CGFloat = 2, fill: Color = L21.bg) -> some View {
        modifier(HardFrame(color: color, offset: offset, lineWidth: lineWidth, fill: fill))
    }
}

/// Primary action: filled, with a 3 px hard shadow that collapses when pressed.
struct L21ButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, kind == .quiet ? 6 : 14)
            .padding(.vertical, kind == .quiet ? 4 : 7)
            .foregroundStyle(kind == .primary ? L21.onAccent : L21.accent)
            .background(kind == .primary ? L21.accent : Color.clear)
            .overlay(kind == .quiet ? nil : Rectangle().strokeBorder(L21.accent, lineWidth: 2))
            .background(kind == .quiet ? nil : Rectangle().fill(L21.accent).offset(x: pressed ? 0 : 3, y: pressed ? 0 : 3))
            .offset(x: pressed && kind != .quiet ? 3 : 0, y: pressed && kind != .quiet ? 3 : 0)
            .opacity(kind == .quiet && pressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Faint scanlines over the whole window. Static, so it costs nothing.
struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(L21.teal.opacity(0.045)))
                y += 4
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The LINE21 wordmark, drawn from the same geometry as components/Line21Wordmark.tsx.
struct Line21Mark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 1200, sy = rect.height / 240
        var p = Path()
        let rects: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 92, 240), (0, 154, 209, 86), (227, 0, 96, 240), (345, 0, 84, 240), (470, 0, 84, 240),
            (560, 0, 84, 240), (560, 0, 209, 78), (560, 81, 180, 78), (560, 162, 209, 78),
            (776, 0, 209, 72), (891, 0, 86, 132), (776, 84, 209, 72), (776, 108, 86, 132), (776, 168, 209, 72),
            (1091, 0, 109, 240),
        ]
        for (x, y, w, h) in rects { p.addRect(CGRect(x: rect.minX + x * sx, y: rect.minY + y * sy, width: w * sx, height: h * sy)) }
        let polys: [[(CGFloat, CGFloat)]] = [[(429, 0), (510, 0), (554, 240), (475, 240)], [(991, 40), (1093, 0), (1093, 78), (991, 118)]]
        for poly in polys {
            p.addLines(poly.map { CGPoint(x: rect.minX + $0.0 * sx, y: rect.minY + $0.1 * sy) })
            p.closeSubpath()
        }
        return p
    }
}

/// Wordmark with a short red/cyan tracking glitch. `trigger` changes → it glitches once.
struct GlitchMark: View {
    var trigger: Int
    @State private var split: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Line21Mark().fill(L21.red.opacity(0.7)).offset(x: split)
            Line21Mark().fill(L21.cyan.opacity(0.6)).offset(x: -split)
            Line21Mark().fill(L21.accent)
        }
        .compositingGroup()
        .accessibilityLabel("LINE21")
        .onAppear { glitch() }
        .onChange(of: trigger) { _ in glitch() }
    }

    private func glitch() {
        guard !reduceMotion else { return }
        let steps: [(Double, CGFloat)] = [(0, 3), (0.06, -2), (0.12, 4), (0.18, 1), (0.26, 0)]
        for (delay, value) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { split = value }
        }
    }
}

/// VHS on-screen-display style status: ▶ PLAY, ● REC, ■ STOP.
struct StatusChip: View {
    enum Kind { case current, update, notInstalled, blocked, working, failed }
    var kind: Kind
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(symbol).font(L21.mono(10, .bold)).foregroundStyle(symbolColor)
            Text(text.uppercased()).font(L21.mono(10.5)).tracking(1.2)
        }
        .foregroundStyle(kind == .update ? L21.ink : L21.accentSoft)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .overlay(Rectangle().strokeBorder(kind == .update ? L21.accent : L21.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .current: return "▶"
        case .update: return "●"
        case .notInstalled: return "■"
        case .blocked: return "❚❚"
        case .working: return "▶▶"
        case .failed: return "✕"
        }
    }

    private var symbolColor: Color {
        switch kind {
        case .update, .failed: return L21.red
        case .blocked: return L21.amber
        default: return L21.accent
        }
    }
}

/// Hard-edged progress bar with moving tape stripes.
struct TapeProgress: View {
    var value: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(L21.line.opacity(0.5))
                if let value {
                    Rectangle().fill(L21.accent).frame(width: max(4, geo.size.width * value))
                } else {
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let w = geo.size.width * 0.3
                        Rectangle().fill(L21.accent).frame(width: w)
                            .offset(x: (geo.size.width + w) * CGFloat(t.truncatingRemainder(dividingBy: 1.4) / 1.4) - w)
                    }
                }
            }
            .clipped()
            .overlay(Rectangle().strokeBorder(L21.accent, lineWidth: 1))
        }
        .frame(height: 8)
        .accessibilityValue(value.map { "\(Int($0 * 100)) procent" } ?? "i gang")
    }
}
