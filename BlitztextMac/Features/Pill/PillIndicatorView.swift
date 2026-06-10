import SwiftUI

/// Floating speech indicator ("Pille"): a small dark capsule with a status
/// dot and a live waveform, visible while a workflow records or processes.
/// Design ported from the Fluesterapp pill.
struct PillIndicatorView: View {
    let appState: AppState

    static let outerWidth: CGFloat = 110
    static let outerHeight: CGFloat = 60
    private static let pillWidth: CGFloat = 70
    private static let pillHeight: CGFloat = 30
    private static let cornerRadius: CGFloat = 15
    private static let pillBackground = Color(red: 0.14, green: 0.14, blue: 0.16)

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)

            PillWaveformView(appState: appState)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: Self.pillWidth, height: Self.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Self.pillBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .frame(width: Self.outerWidth, height: Self.outerHeight)
    }

    private var statusDotColor: Color {
        switch appState.menuBarStatus {
        case .idle: return .white.opacity(0.4)
        case .recording: return .red
        case .processing: return .orange
        case .success: return .green
        case .error: return .red
        }
    }
}

/// Five capsule bars: live mic level with a per-bar sine wobble while
/// recording, sine-only flow while processing.
struct PillWaveformView: View {
    let appState: AppState

    private let barCount = 5
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2.5
    private let maxHeight: CGFloat = 18
    private let minHeight: CGFloat = 3
    private let weights: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor)
                        .frame(width: barWidth, height: barHeight(for: index, time: context.date))
                }
            }
            .frame(height: maxHeight)
        }
    }

    private var barColor: Color {
        switch appState.menuBarStatus {
        case .idle: return .white.opacity(0.75)
        case .recording: return .red
        case .processing: return .orange
        case .success: return .green
        case .error: return .red.opacity(0.7)
        }
    }

    private func barHeight(for index: Int, time: Date) -> CGFloat {
        let weight = weights[index]
        let t = time.timeIntervalSinceReferenceDate

        switch appState.menuBarStatus {
        case .idle:
            return minHeight + (maxHeight - minHeight) * 0.15 * weight
        case .recording:
            // Live mic level + sine wobble per-bar so the wave actually flows.
            let level = max(CGFloat(appState.activeWorkflow?.audioLevel ?? 0), 0.2)
            let phase = t * 8 + Double(index) * 0.7
            let wobble = (sin(phase) + 1) / 2  // 0...1
            let amp = level * weight * (0.45 + 0.55 * CGFloat(wobble))
            return minHeight + (maxHeight - minHeight) * amp
        case .processing:
            // Sine-only flow while the transcript/rewrite is in flight.
            let phase = t * 5 + Double(index) * 0.6
            let wobble = (sin(phase) + 1) / 2
            let amp = (0.35 + 0.55 * CGFloat(wobble)) * weight
            return minHeight + (maxHeight - minHeight) * amp
        case .success, .error:
            return minHeight + (maxHeight - minHeight) * 0.55 * weight
        }
    }
}
