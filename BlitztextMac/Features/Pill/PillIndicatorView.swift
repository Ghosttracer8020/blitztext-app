import SwiftUI

/// Floating speech indicator ("Pille"): a small dark capsule with nine bars
/// that follow the microphone's frequency bands while recording and flow
/// gently while processing. A "Working" bubble sits above it during processing.
struct PillIndicatorView: View {
    let appState: AppState
    let presentation: PillPresentation

    static let outerWidth = PillLayout.outerWidth
    static let outerHeight = PillLayout.outerHeight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only the processing flow needs time-driven frames; other states are
        // static or driven by observation of `audioBands`.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: visualState != .processing || reduceMotion)) { context in
            PillStageView(
                state: visualState,
                bands: appState.activeWorkflow?.audioBands ?? [],
                flowTime: context.date.timeIntervalSinceReferenceDate,
                reduceMotion: reduceMotion
            )
        }
        .opacity(presentation.isVisible ? 1 : 0)
        .offset(y: hiddenOffset)
        // Ease-out in (120 ms), slightly slower ease-in out (150 ms).
        .animation(
            presentation.isVisible ? .easeOut(duration: 0.12) : .easeIn(duration: 0.15),
            value: presentation.isVisible
        )
    }

    /// Enter from below, leave upwards: both directions move ~2 pt up.
    private var hiddenOffset: CGFloat {
        if reduceMotion || presentation.isVisible { return 0 }
        return presentation.isExiting ? -PillLayout.slideOffset : PillLayout.slideOffset
    }

    private var visualState: PillVisualState {
        switch appState.menuBarStatus {
        case .idle: return .idle
        case .recording: return .recording
        case .processing: return .processing
        case .success: return .success
        case .error: return .error
        }
    }
}
