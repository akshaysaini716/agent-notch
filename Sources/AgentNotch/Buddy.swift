import AgentNotchCore
import SwiftUI

/// The agent's face: a small dark-glass screen whose phosphor eyes take the status colour.
/// Working eyes glance around and blink, waiting eyes go wide, done eyes smile, failed eyes cross.
struct Buddy: View {
    var mood: AgentStatus
    var size: CGFloat
    var showsBadge = true

    var body: some View {
        let color = Palette.color(for: mood)
        let corner = size * 0.3
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(RadialGradient(colors: [color.opacity(mood == .ready ? 0.08 : 0.3), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.62))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: max(0.75, size * 0.025))
            BuddyEyes(mood: mood, size: size, color: color)
        }
        .frame(width: size, height: size * 0.84)
        .overlay(alignment: .topTrailing) {
            if showsBadge, let symbol = badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.17, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .background(Circle().fill(color))
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: max(1.5, size * 0.05)))
                    .offset(x: size * 0.12, y: -size * 0.12)
            }
        }
        .animation(.notch, value: mood)
    }

    private var badgeSymbol: String? {
        switch mood {
        case .working: return "ellipsis"
        case .needsYou: return "exclamationmark"
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .ready: return nil
        }
    }
}

private struct BuddyEyes: View {
    let mood: AgentStatus
    let size: CGFloat
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Gaze {
        var blink: CGFloat = 1
        var look: CGFloat = 0
    }

    var body: some View {
        let pair = HStack(spacing: size * 0.2) { eye; eye }
            .shadow(color: color.opacity(mood == .ready ? 0 : 0.9), radius: size * 0.08)
        switch mood {
        case .working where !reduceMotion:
            pair.keyframeAnimator(initialValue: Gaze(), repeating: true) { content, gaze in
                content
                    .scaleEffect(x: 1, y: gaze.blink)
                    .offset(x: gaze.look * size * 0.07)
            } keyframes: { _ in
                KeyframeTrack(\.blink) {
                    CubicKeyframe(1, duration: 2.0)
                    CubicKeyframe(0.1, duration: 0.07)
                    CubicKeyframe(1, duration: 0.1)
                    CubicKeyframe(1, duration: 1.6)
                    CubicKeyframe(0.1, duration: 0.07)
                    CubicKeyframe(1, duration: 0.1)
                }
                KeyframeTrack(\.look) {
                    CubicKeyframe(0, duration: 0.7)
                    CubicKeyframe(-1, duration: 0.45)
                    CubicKeyframe(-1, duration: 0.9)
                    CubicKeyframe(1, duration: 0.6)
                    CubicKeyframe(1, duration: 0.9)
                    CubicKeyframe(0, duration: 0.39)
                }
            }
        case .needsYou where !reduceMotion:
            pair.phaseAnimator([1.0, 1.14]) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in .easeInOut(duration: 0.6) }
        default:
            pair
        }
    }

    @ViewBuilder
    private var eye: some View {
        let stroke = StrokeStyle(lineWidth: size * 0.075, lineCap: .round)
        switch mood {
        case .working:
            Capsule().fill(color).frame(width: size * 0.12, height: size * 0.24)
        case .needsYou:
            Circle().fill(color).frame(width: size * 0.19, height: size * 0.19)
        case .done:
            // ^ — the top half of a circle.
            Path { path in
                path.addArc(center: CGPoint(x: size * 0.09, y: size * 0.11), radius: size * 0.08,
                            startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            }
            .stroke(color, style: stroke)
            .frame(width: size * 0.18, height: size * 0.14)
        case .failed:
            Path { path in
                let d = size * 0.13
                path.move(to: .zero); path.addLine(to: CGPoint(x: d, y: d))
                path.move(to: CGPoint(x: d, y: 0)); path.addLine(to: CGPoint(x: 0, y: d))
            }
            .stroke(color, style: stroke)
            .frame(width: size * 0.13, height: size * 0.13)
        case .ready:
            Capsule().fill(Color.white.opacity(0.4)).frame(width: size * 0.15, height: size * 0.05)
        }
    }
}
