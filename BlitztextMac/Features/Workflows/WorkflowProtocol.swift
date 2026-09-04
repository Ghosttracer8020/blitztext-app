import Foundation

// MARK: - Workflow Types

enum WorkflowType: String, CaseIterable, Identifiable, Codable {
    case transcription
    case localTranscription
    case textImprover
    case dampfAblassen
    case emojiText
    case promptText

    var id: String { rawValue }

    static var mainMenuCases: [WorkflowType] {
        allCases.filter { $0 != .localTranscription }
    }

    var displayName: String {
        switch self {
        case .transcription: return "Blitztext"
        case .localTranscription: return "Blitztext Lokal"
        case .textImprover: return "Blitztext+"
        case .dampfAblassen: return "Blitztext $%&!"
        case .emojiText: return "Blitztext :)"
        case .promptText: return "Blitztext Prompt"
        }
    }

    var icon: String {
        switch self {
        case .transcription: return "mic.fill"
        case .localTranscription: return "lock.shield.fill"
        case .textImprover: return "text.badge.checkmark"
        case .dampfAblassen: return "flame.fill"
        case .emojiText: return "face.smiling"
        case .promptText: return "list.number"
        }
    }

    var subtitle: String {
        switch self {
        case .transcription: return "Sprache rein. Text raus."
        case .localTranscription: return "Nur lokal. Kein Server."
        case .textImprover: return "Geschrieben sprechen."
        case .dampfAblassen: return "Frust rein. Entspannt raus."
        case .emojiText: return "Text rein. Emojis dazu."
        case .promptText: return "Gesprochen rein. Prompt raus."
        }
    }

    var hotkeyLabel: String {
        switch self {
        case .transcription: return "fn + Shift"
        case .localTranscription: return "fn + Shift + Ctrl"
        case .textImprover: return "fn + Control"
        case .dampfAblassen: return "fn + Option"
        case .emojiText: return "fn + Cmd"
        case .promptText: return "fn + Shift + Cmd"
        }
    }

    var accentColor: String {
        switch self {
        case .transcription: return "blue"
        case .localTranscription: return "green"
        case .textImprover: return "purple"
        case .dampfAblassen: return "orange"
        case .emojiText: return "cyan"
        case .promptText: return "indigo"
        }
    }
}

// MARK: - Workflow State

enum WorkflowPhase: Equatable {
    case idle
    case running(String)
    case done(String)
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

enum WorkflowLaunchSource: Equatable {
    case manual
    case hotkeyBackground

    var presentsWorkflowPage: Bool {
        switch self {
        case .manual:
            return true
        case .hotkeyBackground:
            return false
        }
    }
}

typealias WorkflowOutputHandler = @MainActor (String) -> Void
typealias WorkflowPhaseChangeHandler = @MainActor (WorkflowPhase) -> Void

// MARK: - Workflow Protocol

@MainActor
protocol Workflow: AnyObject, Observable {
    var type: WorkflowType { get }
    var phase: WorkflowPhase { get set }
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var onOutput: WorkflowOutputHandler? { get set }
    var onPhaseChange: WorkflowPhaseChangeHandler? { get set }

    func start()
    func stop()
    func reset()
}

// MARK: - App Settings

struct AppSettings: Codable {
    /// Default shortcuts, keyed by WorkflowType.rawValue: right-Option +
    /// K (push-to-talk transcription) / J / H / U / L.
    static let defaultCustomShortcuts: [String: KeyboardShortcut] = [
        WorkflowType.transcription.rawValue: rightOptionShortcut(keyCode: 40),      // K
        WorkflowType.textImprover.rawValue: rightOptionShortcut(keyCode: 38),       // J
        WorkflowType.dampfAblassen.rawValue: rightOptionShortcut(keyCode: 4),       // H
        WorkflowType.emojiText.rawValue: rightOptionShortcut(keyCode: 32),          // U
        WorkflowType.localTranscription.rawValue: rightOptionShortcut(keyCode: 37), // L
        WorkflowType.promptText.rawValue: rightOptionShortcut(keyCode: 35),         // P
    ]

    private static func rightOptionShortcut(keyCode: Int) -> KeyboardShortcut {
        // 0x40 = NX device bit for the right Option key
        KeyboardShortcut(
            keyCode: keyCode,
            rawModifierFlags: KeyboardShortcut.optionMask | 0x40
        )
    }

    var hotkeyMode: HotkeyMode = .hold
    var hasSeenOnboarding: Bool = false
    var secureLocalModeEnabled: Bool = false
    var selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName
    var hasAutoSelectedFastLocalModel: Bool = false
    var customShortcuts: [String: KeyboardShortcut] = AppSettings.defaultCustomShortcuts
    var clipboardAutoClearEnabled: Bool = true

    init(
        hotkeyMode: HotkeyMode = .hold,
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false,
        customShortcuts: [String: KeyboardShortcut] = AppSettings.defaultCustomShortcuts,
        clipboardAutoClearEnabled: Bool = true
    ) {
        self.hotkeyMode = hotkeyMode
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
        self.customShortcuts = customShortcuts
        self.clipboardAutoClearEnabled = clipboardAutoClearEnabled
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
        case customShortcuts
        case clipboardAutoClearEnabled
    }

    /// Legacy key from the first hotkey iteration (right-Option letter map).
    private enum LegacyCodingKeys: String, CodingKey {
        case rightOptionHotkeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .hold
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        secureLocalModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .secureLocalModeEnabled) ?? false
        selectedLocalTranscriptionModelName = try container.decodeIfPresent(
            String.self,
            forKey: .selectedLocalTranscriptionModelName
        ) ?? LocalTranscriptionService.recommendedFastModelName
        hasAutoSelectedFastLocalModel = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAutoSelectedFastLocalModel
        ) ?? false

        if let stored = try container.decodeIfPresent([String: KeyboardShortcut].self, forKey: .customShortcuts) {
            customShortcuts = stored
        } else if let legacyContainer = try? decoder.container(keyedBy: LegacyCodingKeys.self),
                  let legacy = try legacyContainer.decodeIfPresent([String: Int].self, forKey: .rightOptionHotkeys) {
            customShortcuts = legacy.mapValues { Self.rightOptionShortcut(keyCode: $0) }
        } else {
            customShortcuts = AppSettings.defaultCustomShortcuts
        }
        clipboardAutoClearEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .clipboardAutoClearEnabled
        ) ?? true
    }
}

enum TranscriptionBackend: String, Codable {
    case remote
    case local
}

// MARK: - Workflow Settings

struct TranscriptionSettings: Codable {
    var language: String = "de"
    var emailParagraphsEnabled: Bool = true

    init(
        language: String = "de",
        emailParagraphsEnabled: Bool = true
    ) {
        self.language = language
        self.emailParagraphsEnabled = emailParagraphsEnabled
    }

    enum CodingKeys: String, CodingKey {
        case language
        case emailParagraphsEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "de"
        emailParagraphsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .emailParagraphsEnabled
        ) ?? true
    }
}

struct DampfAblassenSettings: Codable {
    var systemPrompt: String = "Du erhältst ein emotional gesprochenes Transkript. Erkenne zuerst das eigentliche Ziel, Anliegen und den wahren Frust der Person. Formuliere daraus eine klare, respektvolle und wirksame Nachricht, mit der die Person ihr Ziel eher erreicht. Bewahre relevante Fakten, konkrete Probleme, Grenzen, Erwartungen und die nötige Dringlichkeit. Entferne Beleidigungen, Drohungen, Sarkasmus, Unterstellungen und unnötige Eskalation. Wenn mehrere Vorwürfe genannt werden, verdichte sie auf die entscheidenden Kernpunkte. Der Ton soll ruhig, menschlich, bestimmt und lösungsorientiert sein. Gib NUR die fertige Nachricht zurück."
    var customName: String = ""
}

struct EmojiTextSettings: Codable {
    var emojiDensity: EmojiDensity = .mittel
    var customName: String = ""

    enum EmojiDensity: String, Codable, CaseIterable, Identifiable {
        case wenig
        case mittel
        case viel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wenig: return "Wenig"
            case .mittel: return "Mittel"
            case .viel: return "Viel"
            }
        }
    }
}

struct PromptTextSettings: Codable {
    var systemPrompt: String = ""
    var outputLanguage: PromptOutputLanguage = .spoken
    var customName: String = ""

    init(
        systemPrompt: String = "",
        outputLanguage: PromptOutputLanguage = .spoken,
        customName: String = ""
    ) {
        self.systemPrompt = systemPrompt
        self.outputLanguage = outputLanguage
        self.customName = customName
    }

    enum CodingKeys: String, CodingKey {
        case systemPrompt
        case outputLanguage
        case customName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        outputLanguage = try container.decodeIfPresent(PromptOutputLanguage.self, forKey: .outputLanguage) ?? .spoken
        customName = try container.decodeIfPresent(String.self, forKey: .customName) ?? ""
    }
}

struct TextImprovementSettings: Codable {
    var systemPrompt: String = ""
    var customTerms: [String] = []
    var context: String = ""
    var tone: TextTone = .neutral
    var customName: String = ""

    enum TextTone: String, Codable, CaseIterable, Identifiable {
        case formal
        case neutral
        case casual

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .formal: return "Formell"
            case .neutral: return "Neutral"
            case .casual: return "Locker"
            }
        }
    }
}
