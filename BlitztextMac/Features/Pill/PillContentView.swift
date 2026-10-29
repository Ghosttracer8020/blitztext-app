import Observation
import SwiftUI

/// Visual state of the pill, decoupled from app state so the view can be
/// rendered in isolation (tests, previews).
enum PillVisualState: Equatable {
    case idle, recording, processing, success, error
}

/// Drives the pill's fade/slide in and out. The window controller flips
/// `isVisible`; the view animates the change.
@Observable
final class PillPresentation {
    var isVisible = false
    /// True while hiding: the pill then slides up (not back down) as it fades.
    var isExiting = false
}

enum PillLayout {
    /// Outer frame of the pill window: leaves room for the "Working" bubble
    /// above and the shadow around the capsule.
    static let outerWidth: CGFloat = 120
    static let outerHeight: CGFloat = 80
    static let pillWidth: CGFloat = 76
    static let pillHeight: CGFloat = 28
    /// Distance from the window's bottom edge to the capsule's bottom edge.
    /// Puts the capsule centre 30 pt above the bottom, as in the old 110x60 window.
    static let pillBottomInset: CGFloat = 16
    static let bubbleGap: CGFloat = 6
    static let slideOffset: CGFloat = 2
}

/// Static, pure rendering of the pill plus bubble. `flowTime` animates the
/// processing flow; pass nil for a still frame.
struct PillStageView: View {
    let state: PillVisualState
    let bands: [Float]
    var flowTime: Double?
    var reduceMotion = false

    private static let background = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    var body: some View {
        ZStack(alignment: .bottom) {
            if state == .processing {
                PillWorkingBubble()
                    .padding(.bottom, PillLayout.pillBottomInset + PillLayout.pillHeight + PillLayout.bubbleGap)
                    .transition(bubbleTransition)
            }

            PillBarsView(levels: levels, color: barColor)
                .frame(width: PillLayout.pillWidth, height: PillLayout.pillHeight)
                .background(Capsule(style: .continuous).fill(Self.background))
                .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .padding(.bottom, PillLayout.pillBottomInset)
        }
        .frame(width: PillLayout.outerWidth, height: PillLayout.outerHeight, alignment: .bottom)
        .animation(.easeOut(duration: 0.18), value: state)
    }

    private var bubbleTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 3)),
                removal: .opacity
            )
    }

    private var barColor: Color {
        switch state {
        case .idle: return .white.opacity(0.75)
        case .recording, .success: return .green
        case .processing: return .orange
        case .error: return .red
        }
    }

    private var levels: [Float] {
        switch state {
        case .idle:
            return Array(repeating: 0, count: PillBandMath.barCount)
        case .recording:
            return PillBandMath.barLevels(from: bands)
        case .processing:
            guard let flowTime, !reduceMotion else { return Self.restingArch(peak: 0.35) }
            // Gentle travelling wave, kept well below the speaking range.
            return (0..<PillBandMath.barCount).map { index in
                let wave = (sin(flowTime * 3.0 - Double(index) * 0.7) + 1) / 2
                return Float(0.12 + 0.3 * wave)
            }
        case .success, .error:
            return Self.restingArch(peak: 0.45)
        }
    }

    /// Still envelope: tallest in the centre, dots at the edges.
    static func restingArch(peak: Float) -> [Float] {
        let centre = PillBandMath.barCount / 2
        return (0..<PillBandMath.barCount).map { index in
            peak * (1 - Float(abs(index - centre)) / Float(centre + 1))
        }
    }
}

/// Nine capsule bars growing symmetrically from the centre line.
struct PillBarsView: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        HStack(spacing: PillBarGeometry.barSpacing) {
            ForEach(0..<PillBandMath.barCount, id: \.self) { index in
                let level = index < levels.count ? levels[index] : 0
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: PillBarGeometry.barWidth, height: PillBarGeometry.height(forLevel: level))
            }
        }
        .frame(height: PillBarGeometry.maxHeight)
    }
}

/// Small dark capsule with the processing label, shown above the pill.
struct PillWorkingBubble: View {
    var body: some View {
        Text("Working")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)))
            .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .fixedSize()
    }
}
