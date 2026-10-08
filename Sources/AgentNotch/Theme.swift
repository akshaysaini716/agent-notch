import AgentNotchCore
import SwiftUI

/// Pure black so the shape reads as part of the hardware notch. Colour is reserved for status.
enum Palette {
    static let notch = Color.black
    static let working = Color(red: 0.54, green: 0.71, blue: 1.00)   // #8AB4FF
    static let needsYou = Color(red: 1.00, green: 0.71, blue: 0.28)  // #FFB547
    static let done = Color(red: 0.37, green: 0.83, blue: 0.61)      // #5FD49B
    static let failed = Color(red: 1.00, green: 0.42, blue: 0.42)    // #FF6B6B
    static let text = Color.white
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    /// Raised surface inside the black shell.
    static let card = Color(red: 0.083, green: 0.083, blue: 0.095)
    /// Recessed well inside a card (code, diffs, output).
    static let well = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.08)

    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .working: return working
        case .needsYou: return needsYou
        case .done: return done
        case .failed: return failed
        case .ready: return tertiary
        }
    }
}

enum Fonts {
    static let title = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium, design: .rounded)
    static let code = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    static let button = Font.system(size: 12, weight: .semibold, design: .rounded)
}

enum Metrics {
    static let expandedWidth: CGFloat = 680
    static let listWidth: CGFloat = 214
    static let detailHeight: CGFloat = 300
    static let earWidth: CGFloat = 46
    static let cardRadius: CGFloat = 18
    /// Outward flare where the shape meets the top edge of the screen, like the real notch.
    static let flare: CGFloat = 6
    static let collapsedRadius: CGFloat = 12
    static let expandedRadius: CGFloat = 28
}

extension Animation {
    static let notch = Animation.spring(response: 0.42, dampingFraction: 0.8)
}

/// The notch outline: concave flares at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat = Metrics.flare

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2, (rect.width - 2 * flare) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                          control: CGPoint(x: rect.minX + flare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX + flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - r),
                          control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Capsule buttons for the request card.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, outline }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.button)
            .foregroundStyle(kind == .primary ? Color.black : Palette.text)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background {
                switch kind {
                case .primary: Capsule().fill(Color.white)
                case .secondary: Capsule().fill(Color.white.opacity(0.13))
                case .outline: Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A key you can press for a button, shown only while the notch is open for the keyboard.
struct KeyHint: View {
    @EnvironmentObject private var model: NotchModel
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        if model.keyboardOpen {
            // Takes its colour from where it sits: dark on the white Allow button, light elsewhere.
            Text(key)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.tertiary, lineWidth: 1))
        }
    }
}

/// A pill button label with its key hint.
struct HintedLabel: View {
    let title: String
    let key: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let key { KeyHint(key) }
        }
    }
}

/// Status light. Working agents breathe; everything else holds still.
struct StatusDot: View {
    var status: AgentStatus
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle()
            .fill(Palette.color(for: status))
            .frame(width: size, height: size)
            .shadow(color: Palette.color(for: status).opacity(status == .ready ? 0 : 0.6), radius: 3)
        if status == .working && !reduceMotion {
            dot.phaseAnimator([1.0, 0.35]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.9) }
        } else {
            dot
        }
    }
}

/// Small rotating arc for the collapsed notch while something is working.
struct Spinner: View {
    var color: Color
    var diameter: CGFloat = 12
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(color, style: StrokeStyle(lineWidth: diameter / 6, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

enum Format {
    /// How long ago, compactly: "now", "4m", "3h", "2d" (+ " ago" unless `suffix` is false).
    static func ago(_ date: Date, suffix: Bool = true, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let value: String
        switch seconds {
        case ..<60: return suffix ? "just now" : "<1m"
        case ..<3600: value = "\(seconds / 60)m"
        case ..<86400: value = "\(seconds / 3600)h"
        default: value = "\(seconds / 86400)d"
        }
        return suffix ? "\(value) ago" : value
    }

    /// 74 → "1:14", 3725 → "1:02:05".
    static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
