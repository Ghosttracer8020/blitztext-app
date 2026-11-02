import Foundation
import Observation
import Sparkle

/// Sparkle 2 wrapper. While Info.plist still carries the placeholder public key
/// the updater stays off and says so (tooltip of the menu item) - never a silent gap.
@MainActor
@Observable
final class UpdateService {
    static let shared = UpdateService()

    enum State: Equatable {
        case notStarted
        case keyMissing
        case active
        case failed(String)
    }

    /// Must match the placeholder in project.yml / Info.plist.
    private static let placeholderKey = "REPLACE_WITH_PUBLIC_ED_KEY"

    private(set) var state: State = .notStarted
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    private init() {}

    var canCheck: Bool { state == .active }

    func start() {
        guard state == .notStarted else { return }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, key != Self.placeholderKey else {
            state = .keyMissing
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        do {
            try controller.updater.start()
            state = .active
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard state == .active else { return }
        controller?.checkForUpdates(nil)
    }

    var statusText: String {
        switch state {
        case .notStarted: "Updater nicht gestartet"
        case .keyMissing: "Update-Schl\u{00FC}ssel nicht eingerichtet \u{2013} Updater aus"
        case .active: "Updates werden automatisch gepr\u{00FC}ft"
        case .failed(let message): "Updater-Fehler: \(message)"
        }
    }
}
