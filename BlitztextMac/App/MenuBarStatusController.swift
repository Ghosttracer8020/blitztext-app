import AppKit

enum MenuBarStatus: Equatable {
    case idle
    case recording(WorkflowType)
    case processing(WorkflowType)
    case success(WorkflowType?)
    case error(WorkflowType?)
}

@MainActor
final class MenuBarStatusController {
    private weak var button: NSStatusBarButton?
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var currentStatus: MenuBarStatus = .idle

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        renderCurrentStatus()
    }

    func update(to status: MenuBarStatus) {
        currentStatus = status
        animationFrame = 0
        configureAnimationIfNeeded()
        renderCurrentStatus()
    }

    private func configureAnimationIfNeeded() {
        stopAnimation()

        switch currentStatus {
        case .recording:
            startAnimation(interval: 0.09)
        case .processing:
            startAnimation(interval: 0.12)
        default:
            break
        }
    }

    private func startAnimation(interval: TimeInterval) {
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        animationFrame = (animationFrame + 1) % MenuBarWave.frameCount
        renderCurrentStatus()
    }

    private func renderCurrentStatus() {
        guard let button else { return }
        button.image = MenuBarStatusIconRenderer.makeImage(for: currentStatus, frame: animationFrame)
        button.image?.isTemplate = true
        button.toolTip = tooltip(for: currentStatus)
    }

    private func tooltip(for status: MenuBarStatus) -> String {
        switch status {
        case .idle:
            return "UltraDic ist bereit"
        case .recording(let type):
            return "\(type.displayName): Aufnahme läuft"
        case .processing(let type):
            return "\(type.displayName): Verarbeitung läuft"
        case .success(let type):
            if let type {
                return "\(type.displayName): Fertig"
            }
            return "UltraDic: Fertig"
        case .error(let type):
            if let type {
                return "\(type.displayName): Fehler"
            }
            return "UltraDic: Fehler"
        }
    }

    deinit {
        animationTimer?.invalidate()
    }
}

private enum MenuBarStatusIconRenderer {
    static func makeImage(for status: MenuBarStatus, frame: Int) -> NSImage {
        if case .idle = status, let baseImage = baseTemplateImage() {
            return baseImage
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            drawBaseIcon(in: bounds, status: status, frame: frame)

            switch status {
            case .recording(let type):
                drawActivityBadge(
                    type: type,
                    systemName: badgeSymbol(for: type),
                    in: bounds,
                    frame: frame,
                    phase: .recording
                )
            case .processing(let type):
                drawActivityBadge(
                    type: type,
                    systemName: badgeSymbol(for: type),
                    in: bounds,
                    frame: frame,
                    phase: .processing
                )
            case .success:
                drawBadge(systemName: "checkmark", in: bounds, fillOpacity: 1.0)
            case .error:
                drawBadge(systemName: "exclamationmark", in: bounds, fillOpacity: 1.0)
            default:
                break
            }

            return true
        }
        image.isTemplate = true
        image.size = size
        return image
    }

    private enum ActivityPhase {
        case recording
        case processing
    }

    private static func drawBaseIcon(in bounds: CGRect, status: MenuBarStatus, frame: Int) {
        // UltraDic's five-bar wave (same proportions as menubar_icon). With a
        // badge it moves left so the badge does not cover the last bar.
        let hasBadge: Bool
        if case .idle = status { hasBadge = false } else { hasBadge = true }
        let waveWidth: CGFloat = hasBadge ? 8.6 : 13
        let waveRect = CGRect(
            x: hasBadge ? bounds.minX + 0.2 : bounds.midX - waveWidth / 2,
            y: bounds.midY - 6.5,
            width: waveWidth,
            height: 13
        )
        let heights = MenuBarWave.heights(for: status, frame: frame)
        let alphas = MenuBarWave.alphas(for: status, frame: frame)
        let barCount = CGFloat(MenuBarWave.restHeights.count)
        let barWidth = waveRect.width / (barCount * 2 - 1)

        for index in MenuBarWave.restHeights.indices {
            let height = max(barWidth, waveRect.height * heights[index])
            let rect = CGRect(
                x: waveRect.minX + CGFloat(index) * barWidth * 2,
                y: waveRect.midY - height / 2,
                width: barWidth,
                height: height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            NSColor.black.withAlphaComponent(alphas[index]).setFill()
            path.fill()
        }
    }

    private static func drawActivityBadge(
        type: WorkflowType,
        systemName: String,
        in bounds: CGRect,
        frame: Int,
        phase: ActivityPhase
    ) {
        let badgeSize: CGFloat = 7.5
        let badgeRect = CGRect(
            x: bounds.maxX - badgeSize - 0.8,
            y: bounds.minY + 0.8,
            width: badgeSize,
            height: badgeSize
        )

        let badgeOpacity: CGFloat
        let haloOpacity: CGFloat

        switch phase {
        case .recording:
            let values: [CGFloat]
            switch type {
            case .transcription, .localTranscription:
                values = [0.74, 1.0, 0.82, 0.92]
            case .textImprover:
                values = [0.66, 0.84, 1.0, 0.8]
            case .dampfAblassen:
                values = [1.0, 0.76, 0.94, 0.68]
            case .emojiText:
                values = [0.8, 0.92, 0.7, 1.0]
            case .promptText:
                values = [0.7, 1.0, 0.84, 0.9]
            case .mailReply:
                values = [0.9, 0.72, 1.0, 0.8]
            }
            badgeOpacity = values[frame % values.count]
            haloOpacity = 0.14 + (CGFloat(frame % 4) * 0.04)
        case .processing:
            let values: [CGFloat]
            switch type {
            case .transcription, .localTranscription:
                values = [0.58, 0.72, 0.9, 0.72]
            case .textImprover:
                values = [0.48, 0.68, 0.92, 0.84]
            case .dampfAblassen:
                values = [0.84, 0.62, 0.9, 0.56]
            case .emojiText:
                values = [0.54, 0.76, 0.88, 0.68]
            case .promptText:
                values = [0.6, 0.82, 0.94, 0.72]
            case .mailReply:
                values = [0.7, 0.9, 0.6, 0.94]
            }
            badgeOpacity = values[frame % values.count]
            haloOpacity = 0.12 + (CGFloat((frame + 2) % 4) * 0.03)
        }

        let haloInset = phase == .recording ? -0.8 : -0.45
        let haloRect = badgeRect.insetBy(dx: haloInset, dy: haloInset)
        let haloPath = NSBezierPath(ovalIn: haloRect)
        NSColor.black.withAlphaComponent(haloOpacity).setStroke()
        haloPath.lineWidth = phase == .recording ? 0.9 : 0.75
        haloPath.stroke()

        drawBadge(systemName: systemName, in: bounds, fillOpacity: badgeOpacity)

        if phase == .processing {
            drawProcessingDot(around: badgeRect, frame: frame)
        }
    }

    private static func drawBadge(systemName: String, in bounds: CGRect, fillOpacity: CGFloat) {
        let badgeSize: CGFloat = 7.5
        let badgeRect = CGRect(
            x: bounds.maxX - badgeSize - 0.8,
            y: bounds.minY + 0.8,
            width: badgeSize,
            height: badgeSize
        )

        let badgePath = NSBezierPath(ovalIn: badgeRect)
        NSColor.black.withAlphaComponent(fillOpacity).setFill()
        badgePath.fill()

        guard let symbol = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: nil
        ) else {
            return
        }

        let config = NSImage.SymbolConfiguration(pointSize: 5.5, weight: .bold)
        let configuredSymbol = symbol.withSymbolConfiguration(config) ?? symbol
        let symbolRect = badgeRect.insetBy(dx: 1.2, dy: 1.2)
        configuredSymbol.draw(
            in: symbolRect,
            from: .zero,
            operation: .destinationOut,
            fraction: 1.0
        )
    }

    private static func drawProcessingDot(around badgeRect: CGRect, frame: Int) {
        let orbitPoints: [CGPoint] = [
            CGPoint(x: badgeRect.midX, y: badgeRect.maxY + 0.35),
            CGPoint(x: badgeRect.maxX + 0.35, y: badgeRect.midY),
            CGPoint(x: badgeRect.midX, y: badgeRect.minY - 0.35),
            CGPoint(x: badgeRect.minX - 0.35, y: badgeRect.midY),
        ]
        let point = orbitPoints[frame % orbitPoints.count]
        let dotRect = CGRect(x: point.x - 0.85, y: point.y - 0.85, width: 1.7, height: 1.7)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        NSColor.black.withAlphaComponent(0.92).setFill()
        dotPath.fill()
    }

    private static func badgeSymbol(for type: WorkflowType) -> String {
        switch type {
        case .transcription:
            return "mic.fill"
        case .localTranscription:
            return "lock.shield.fill"
        case .textImprover:
            return "text.alignleft"
        case .dampfAblassen:
            return "flame.fill"
        case .emojiText:
            return "face.smiling"
        case .promptText:
            return "list.number"
        case .mailReply:
            return "envelope.fill"
        }
    }

    private static func baseTemplateImage() -> NSImage? {
        guard let image = NSImage(named: "menubar_icon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

/// Bar heights and opacities of the animated menu bar wave.
enum MenuBarWave {
    static let frameCount = 8
    /// Resting wave, left to right (fraction of the wave height).
    static let restHeights: [CGFloat] = [0.30, 0.55, 0.85, 0.55, 0.30]

    static func heights(for status: MenuBarStatus, frame: Int) -> [CGFloat] {
        guard case .recording = status else { return restHeights }
        // Speaking: each bar bounces like a level meter, out of phase with
        // its neighbours, so the wave visibly "talks".
        let step = Double(frame % frameCount) / Double(frameCount) * 2 * .pi
        return restHeights.indices.map { index in
            let wobble = abs(sin(step + Double(index) * 1.3))
            let peak = min(0.95, restHeights[index] + 0.25)
            return 0.25 + CGFloat(wobble) * (peak - 0.25)
        }
    }

    static func alphas(for status: MenuBarStatus, frame: Int) -> [CGFloat] {
        switch status {
        case .processing:
            // Working: a highlight sweeps left to right across the resting wave.
            let position = Double(frame % frameCount) / Double(frameCount - 1)
                * Double(restHeights.count + 1) - 1
            return restHeights.indices.map { index in
                let distance = abs(Double(index) - position)
                return CGFloat(0.35 + 0.65 * max(0, 1 - distance / 1.5))
            }
        case .error:
            return [1, 0.75, 0.55, 0.75, 1]
        default:
            return Array(repeating: 1, count: restHeights.count)
        }
    }
}
