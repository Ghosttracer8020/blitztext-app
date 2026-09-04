import SwiftUI
import AppKit

struct SettingsContentView: View {
    @Bindable var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Two-tab segmented picker
            Picker("", selection: $selectedTab) {
                Text("Anpassen").tag(0)
                Text("Zugang").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                if selectedTab == 0 {
                    CustomizeSettingsView(appState: appState)
                } else {
                    AccessSettingsView(appState: appState)
                }
            }
        }
        .onAppear {
            appState.refreshAccessibilityPermission()
            selectedTab = defaultTabSelection
        }
    }

    private var defaultTabSelection: Int {
        if !appState.accessibilityPermissionGranted {
            return 1
        }
        if appState.isConfigured && !BlitztextInstallLocationService.shouldOfferMoveToApplications {
            return 0
        }
        return 1
    }
}

// MARK: - Section Label (quiet style)

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Access Settings (Tab 1: Zugang)

struct AccessSettingsView: View {
    private static let openAIAPIKeyPattern = #"^sk-[A-Za-z0-9_-]{20,}$"#

    @Bindable var appState: AppState

    private enum FieldFocus {
        case openAIAPIKey
    }

    @State private var launchAtLoginService = LaunchAtLoginService()
    @State private var currentInstallLocation = BlitztextInstallLocationService.currentInstallLocation
    @State private var openAIAPIKey = ""
    @State private var editingAPIKey = false
    @State private var saved = false
    @State private var saveErrorText: String?
    @State private var saveWarningText: String?
    @State private var installActionErrorText: String?
    @State private var showCleanupOptions = false
    @State private var deleteLocalDataOnCleanup = true
    @State private var cleanupStatusText: String?
    @State private var cleanupErrorText: String?
    @FocusState private var focusedField: FieldFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Berechtigungen")

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: appState.accessibilityPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appState.accessibilityPermissionGranted ? .green : .orange)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.accessibilityPermissionGranted ? "Direktes Einfügen ist freigegeben." : "Direktes Einfügen ist noch nicht freigegeben.")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("Öffne Bedienungshilfen und aktiviere Blitztext. Falls Blitztext schon aktiv ist, einmal aus- und wieder einschalten.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button("Bedienungshilfen öffnen") {
                        appState.requestAccessibilityPermission()
                    }
                    .buttonStyle(SubtleButtonStyle())

                    Button("Erneut prüfen") {
                        appState.refreshAccessibilityPermission()
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "OpenAI API Key")
                    Spacer()
                    if appState.hasValue(for: .openAIAPIKey) && !editingAPIKey {
                        Button("Aendern") { editingAPIKey = true }
                            .font(.system(size: 10, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                }

                if appState.hasValue(for: .openAIAPIKey) && !editingAPIKey {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.8))
                        Text(appState.apiKeyDisplayValue(for: .openAIAPIKey))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                } else {
                    HStack(spacing: 8) {
                        SecureField("sk-...", text: $openAIAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                            .focused($focusedField, equals: .openAIAPIKey)

                        Button("Einfuegen") {
                            pasteAPIKeyFromClipboard()
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }

                Text("Dein Key bleibt lokal in dieser App. Audio und Text werden direkt an die OpenAI API gesendet.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Installation")

                Text(installationHeadline)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(installationDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(BlitztextInstallLocationService.bundleURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !BlitztextInstallLocationService.otherInstalledBundleURLs.isEmpty {
                    Text("Weitere Blitztext-Kopien auf diesem Mac können doppelte Login-Items auslösen.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if BlitztextInstallLocationService.shouldOfferMoveToApplications {
                        Button("Nach /Applications bewegen") {
                            moveToApplications()
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }

                    Button("Im Finder zeigen") {
                        revealInFinder(urls: [BlitztextInstallLocationService.bundleURL])
                    }
                    .buttonStyle(SubtleButtonStyle())

                    if !BlitztextInstallLocationService.otherInstalledBundleURLs.isEmpty {
                        Button("Weitere Kopien zeigen") {
                            revealInFinder(urls: BlitztextInstallLocationService.otherInstalledBundleURLs)
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }

                if let installActionErrorText {
                    Text(installActionErrorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Updates")

                Text("Diese Preview hat keinen oeffentlichen Update-Feed. Baue neue Versionen selbst aus dem Repo.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !currentInstallLocation.isCanonicalInstall {
                    Text("Hotkeys und Login-Start laufen am stabilsten, wenn Blitztext aus /Applications gestartet wird.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Updates sind in dieser Preview manuell: pull, build, starten.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            // Launch at Login
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Beim Anmelden")

                Toggle("Blitztext automatisch starten", isOn: Binding(
                    get: { launchAtLoginService.isEnabled },
                    set: { launchAtLoginService.setEnabled($0) }
                ))
                .toggleStyle(.switch)

                Text(launchAtLoginService.errorText ?? launchAtLoginService.helperText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(
                        launchAtLoginService.errorText == nil
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.red)
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let saveErrorText {
                Text(saveErrorText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let saveWarningText {
                Text(saveWarningText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Hinweis")

                Text("Fuer direktes Einfuegen: Blitztext einmal nach /Applications legen und danach Mikrofon sowie Bedienungshilfen erlauben.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Sauber Entfernen")

                Text("Vor dem Löschen Blitztext erst auf diesem Mac bereinigen. So verschwinden Anmeldestart und lokale Daten sauber aus dem Weg.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showCleanupOptions {
                    Toggle("Zugangsdaten und Einstellungen dieses Macs löschen", isOn: $deleteLocalDataOnCleanup)
                        .toggleStyle(.switch)

                    Text("Danach Blitztext beenden und die App aus /Applications löschen. Bereits verwaiste alte Login-Items können in den Systemeinstellungen einmalig manuell entfernt werden.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Abbrechen") {
                            showCleanupOptions = false
                        }
                        .buttonStyle(SubtleButtonStyle())

                        Button("Jetzt bereinigen") {
                            runCleanup()
                        }
                        .buttonStyle(SubtleButtonStyle())
                        .foregroundStyle(.red)
                    }
                } else {
                    Button("Entfernung vorbereiten") {
                        showCleanupOptions = true
                    }
                    .buttonStyle(SubtleButtonStyle())
                }

                if let cleanupStatusText {
                    Text(cleanupStatusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let cleanupErrorText {
                    Text(cleanupErrorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Save button (right-aligned, text only)
            HStack {
                Spacer()
                Button {
                    save()
                } label: {
                    if saved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Gespeichert")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                    } else {
                        Text("Speichern")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(SubtleButtonStyle())
                .animation(.easeInOut(duration: 0.2), value: saved)
            }
        }
        .padding(16)
        .onAppear {
            launchAtLoginService.refresh()
            refreshInstallState()
            load()
            if !appState.hasValue(for: .openAIAPIKey) {
                editingAPIKey = true
                focusedField = .openAIAPIKey
            }
        }
    }

    private func load() {
        openAIAPIKey = ""
    }

    private func save() {
        saveErrorText = nil
        saveWarningText = nil
        cleanupStatusText = nil
        cleanupErrorText = nil
        KeychainService.invalidateCache()
        let trimmedAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if editingAPIKey || !appState.hasValue(for: .openAIAPIKey) {
            guard !trimmedAPIKey.isEmpty else {
                saveErrorText = "Bitte trage deinen OpenAI API Key ein."
                return
            }
            // Warn (not block) on unusual formats: typed keys were previously
            // saved unchecked and failed only at the first API call.
            if trimmedAPIKey.range(of: Self.openAIAPIKeyPattern, options: .regularExpression) == nil {
                saveWarningText = "Der Key sieht ungew\u{00F6}hnlich aus (erwartet: beginnt mit sk-). Gespeichert wurde er trotzdem."
            }
            do {
                try KeychainService.save(key: .openAIAPIKey, value: trimmedAPIKey)
                openAIAPIKey = ""
                editingAPIKey = false
            } catch {
                saveErrorText = "OpenAI API Key konnte nicht gespeichert werden."
                return
            }
        }

        KeychainService.invalidateCache()
        if !appState.hasValue(for: .openAIAPIKey) {
            saveErrorText = "OpenAI API Key wurde nicht persistent gespeichert. Bitte App neu starten und erneut versuchen."
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) { saved = false }
        }
    }

    private func pasteAPIKeyFromClipboard() {
        guard let rawText = NSPasteboard.general.string(forType: .string) else {
            saveErrorText = "Zwischenablage enthält keinen Text."
            return
        }

        let firstLine = rawText.components(separatedBy: .newlines).first ?? rawText
        let trimmedKey = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.range(of: Self.openAIAPIKeyPattern, options: .regularExpression) != nil else {
            saveErrorText = "Zwischenablage enthält keinen plausiblen OpenAI API Key."
            return
        }

        openAIAPIKey = trimmedKey
        NSPasteboard.general.clearContents()
        saveErrorText = nil
    }

    private var installationHeadline: String {
        switch currentInstallLocation {
        case .applications:
            return "Blitztext liegt am richtigen Ort."
        case .userApplications:
            return "Blitztext liegt noch in ~/Applications."
        case .outsideApplications:
            return "Blitztext liegt noch nicht in /Applications."
        case .unknown:
            return "Der Installationsort konnte nicht sicher erkannt werden."
        }
    }

    private var installationDetail: String {
        switch currentInstallLocation {
        case .applications:
            if BlitztextInstallLocationService.otherInstalledBundleURLs.isEmpty {
                return "Für stabile Login-Items und Updates nur diese Kopie weiterverwenden."
            }
            return "Diese Kopie ist korrekt. Zusätzliche Kopien solltest du später entfernen."
        case .userApplications:
            return "Fuer stabile Hotkeys und Login-Items sollte Blitztext nur aus /Applications laufen."
        case .outsideApplications:
            return "Verschiebe Blitztext einmal nach /Applications, damit Anmeldestart und Hotkeys sauber bleiben."
        case .unknown:
            return "Öffne Blitztext möglichst direkt aus /Applications."
        }
    }

    private func refreshInstallState() {
        currentInstallLocation = BlitztextInstallLocationService.currentInstallLocation
        installActionErrorText = nil
    }

    private func moveToApplications() {
        installActionErrorText = nil

        do {
            try BlitztextInstallLocationService.moveToApplicationsAndRelaunch()
        } catch {
            installActionErrorText = error.localizedDescription
        }
    }

    private func runCleanup() {
        cleanupStatusText = nil
        cleanupErrorText = nil

        let report = deleteLocalDataOnCleanup
            ? BlitztextCleanupService.cleanupUserData()
            : BlitztextCleanupService.removeLaunchAtLoginRegistration()

        KeychainService.invalidateCache()
        launchAtLoginService.refresh()
        refreshInstallState()

        if deleteLocalDataOnCleanup {
            openAIAPIKey = ""
            editingAPIKey = true
        }

        if report.failedItems.isEmpty {
            cleanupStatusText = deleteLocalDataOnCleanup
                ? "Anmeldestart und lokale Daten wurden bereinigt. Jetzt Blitztext beenden und aus /Applications löschen."
                : "Anmeldestart wurde deaktiviert. Jetzt Blitztext beenden und aus /Applications löschen."
            showCleanupOptions = false

            let urlsToReveal = report.knownInstallBundleURLs.isEmpty
                ? [BlitztextInstallLocationService.bundleURL]
                : report.knownInstallBundleURLs
            revealInFinder(urls: urlsToReveal)
            return
        }

        let failureSummary = report.failedItems
            .map { "\($0.url.lastPathComponent): \($0.errorDescription)" }
            .joined(separator: "\n")
        cleanupErrorText = "Nicht alles konnte bereinigt werden:\n\(failureSummary)"
    }

    private func revealInFinder(urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

// MARK: - Customize Settings (Tab 2: Anpassen)

struct CustomizeSettingsView: View {
    @Bindable var appState: AppState
    @State private var newTerm = ""

    private var installedLocalModels: [LocalTranscriptionModel] {
        LocalTranscriptionService.installedModels()
    }

    private var localModelOptions: [LocalTranscriptionModel] {
        LocalTranscriptionService.modelOptions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // MARK: Lokaler Modus
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Sicherer Lokaler Modus")

                Toggle("Sicherer Lokaler Modus", isOn: $appState.appSettings.secureLocalModeEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: appState.appSettings.secureLocalModeEnabled) { _, newValue in
                        if newValue && !appState.selectedLocalModelIsInstalled {
                            appState.installSelectedLocalModel()
                        }
                    }

                HStack(spacing: 6) {
                    Image(systemName: appState.selectedLocalModelIsInstalled ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(appState.selectedLocalModelIsInstalled ? .green : .blue)
                    Text(appState.selectedLocalModelIsInstalled ? "\(installedLocalModels.count) lokales WhisperKit-Modell installiert." : "Das ausgewählte Modell wird beim Installieren lokal gespeichert.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Lokales Modell")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { appState.selectedLocalModelName },
                        set: { appState.appSettings.selectedLocalTranscriptionModelName = $0 }
                    )) {
                        ForEach(localModelOptions) { model in
                            Text("\(model.displayName) · \(model.installStateLabel)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(appState.isDownloadingLocalModel)
                }

                if let progress = appState.localModelDownloadProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text(appState.localModelDownloadStatusText ?? "Modell wird geladen...")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button(appState.localModelDownloadButtonTitle) {
                            appState.installSelectedLocalModel()
                        }
                        .controlSize(.small)
                        .disabled(appState.selectedLocalModelIsInstalled)

                        Link("Modellseite", destination: LocalTranscriptionService.modelPageURL(for: appState.selectedLocalModelName))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                }

                if let errorText = appState.localModelDownloadErrorText {
                    Text(errorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // MARK: Tastenkuerzel
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Tastenk\u{00FC}rzel")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Fest eingebaut (zus\u{00E4}tzlich aktiv)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(WorkflowType.mainMenuCases) { type in
                        HStack {
                            Text(type.hotkeyLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 124, alignment: .leading)
                            Text(appState.displayName(for: type))
                                .font(.system(size: 11.5, weight: .medium))
                            Spacer()
                        }
                    }
                }

                // Custom shortcuts (single key or modifier combo)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Eigene K\u{00FC}rzel")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(WorkflowType.allCases) { type in
                            HStack {
                                Text(appState.displayName(for: type))
                                    .font(.system(size: 11.5, weight: .medium))
                                Spacer()
                                ShortcutRecorderView(type: type, appState: appState)
                            }
                        }
                    }

                    Text("Klicken, dann Taste oder Kombination dr\u{00FC}cken \u{2014} auch nur Modifier (z. B. rechte \u{2325} allein, beim Loslassen \u{00FC}bernommen). Esc bricht ab, R\u{00FC}ckschritt l\u{00F6}scht.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    if !appState.accessibilityPermissionGranted {
                        Text("Ben\u{00F6}tigt die Bedienungshilfen-Berechtigung.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                }

                // Mode picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Modus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.appSettings.hotkeyMode) {
                        ForEach(HotkeyMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // MARK: Zwischenablage
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Zwischenablage")

                Toggle("Nach dem Einf\u{00FC}gen automatisch leeren", isOn: $appState.appSettings.clipboardAutoClearEnabled)
                    .font(.system(size: 11.5))

                Text("Entfernt den eingef\u{00FC}gten Text 60 s nach erfolgreichem Einf\u{00FC}gen aus der Zwischenablage \u{2014} sofern du nichts anderes kopiert hast.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Blitztext
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext")

                Toggle("E-Mail-Abs\u{00E4}tze automatisch setzen", isOn: $appState.transcriptionSettings.emailParagraphsEnabled)
                    .font(.system(size: 11.5))

                Text("Erkennt Begr\u{00FC}\u{00DF}ung (\u{201E}Hallo Thomas,\u{201C}) und Verabschiedung (\u{201E}Viele Gr\u{00FC}\u{00DF}e Ben\u{201C}) im Diktat und setzt dort Abs\u{00E4}tze. L\u{00E4}uft lokal auf dem Mac, der Wortlaut bleibt unver\u{00E4}ndert.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Blitztext+
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext+")

                // Tone
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schreibstil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.textImprovementSettings.tone) {
                        ForEach(TextImprovementSettings.TextTone.allCases) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // System Prompt
                VStack(alignment: .leading, spacing: 8) {
                    Text("Eigene Anweisung")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $appState.textImprovementSettings.systemPrompt)
                        .font(.system(size: 11))
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            if appState.textImprovementSettings.systemPrompt.isEmpty {
                                Text("z.B. \"Schreibe pr\u{00E4}gnant und ohne F\u{00FC}llw\u{00F6}rter.\"")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                // Context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kontext")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("z.B. \"E-Mails im Bereich Unternehmensberatung\"", text: $appState.textImprovementSettings.context)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }

            // MARK: Blitztext $%&!
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext $%&!")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Eigene Anweisung")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $appState.dampfAblassenSettings.systemPrompt)
                        .font(.system(size: 11))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            if appState.dampfAblassenSettings.systemPrompt.isEmpty {
                                Text("z.B. \"Formuliere den Text sachlich und freundlich um.\"")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }

            // MARK: Blitztext :)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext :)")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Emoji-Dichte")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.emojiTextSettings.emojiDensity) {
                        ForEach(EmojiTextSettings.EmojiDensity.allCases) { density in
                            Text(density.displayName).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // MARK: Blitztext Prompt
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext Prompt")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sprache des Prompts")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.promptTextSettings.outputLanguage) {
                        ForEach(PromptOutputLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Eigene Anweisung")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $appState.promptTextSettings.systemPrompt)
                        .font(.system(size: 11))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            if appState.promptTextSettings.systemPrompt.isEmpty {
                                Text("z.B. \"Formuliere Prompts immer f\u{00FC}r Claude Code, mit Dateipfaden.\"")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Text("Leer = eingebaute Anweisung: nummerierte Liste, nichts dazuerfinden. Eine eigene Anweisung ersetzt sie komplett; die Eigennamen-Liste wird angeh\u{00E4}ngt.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Eigennamen
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Eigennamen")

                // Term chips
                if !appState.textImprovementSettings.customTerms.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(appState.textImprovementSettings.customTerms, id: \.self) { term in
                            HStack(spacing: 3) {
                                Text(term)
                                    .font(.system(size: 10.5))
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        appState.textImprovementSettings.customTerms.removeAll { $0 == term }
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(SubtleButtonStyle())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
                            )
                        }
                    }
                }

                HStack(spacing: 6) {
                    TextField("Neuer Begriff", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { addTerm() }

                    Button { addTerm() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue.opacity(0.7))
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

        }
        .padding(16)
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !appState.textImprovementSettings.customTerms.contains(trimmed) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            appState.textImprovementSettings.customTerms.append(trimmed)
        }
        newTerm = ""
    }
}

// MARK: - Flow Layout (for term tags)

// MARK: - Shortcut Recorder

/// Click-to-record field for a workflow shortcut: press a single key or any
/// modifier+key combination. Esc cancels, Delete clears the binding.
/// While recording, both hotkey systems are suspended so the pressed combo
/// does not trigger a workflow.
private struct ShortcutRecorderView: View {
    let type: WorkflowType
    @Bindable var appState: AppState
    @State private var keyMonitor: Any?
    @State private var timeoutTask: Task<Void, Never>?
    /// Last non-empty modifier state seen while recording; committed as a
    /// modifier-only shortcut when all modifiers are released without a key.
    @State private var pendingModifierFlags: UInt64 = 0

    /// System combos that must never be bound: swallowing them would break
    /// copy/paste/quit systemwide — including this app's own auto-paste ⌘V.
    private static let blockedShortcuts: [KeyboardShortcut] = [
        KeyboardShortcut(keyCode: 9, rawModifierFlags: KeyboardShortcut.commandMask),  // Cmd+V
        KeyboardShortcut(keyCode: 8, rawModifierFlags: KeyboardShortcut.commandMask),  // Cmd+C
        KeyboardShortcut(keyCode: 7, rawModifierFlags: KeyboardShortcut.commandMask),  // Cmd+X
        KeyboardShortcut(keyCode: 12, rawModifierFlags: KeyboardShortcut.commandMask), // Cmd+Q
        KeyboardShortcut(keyCode: 13, rawModifierFlags: KeyboardShortcut.commandMask), // Cmd+W
        KeyboardShortcut(keyCode: 48, rawModifierFlags: KeyboardShortcut.commandMask), // Cmd+Tab
    ]

    private var currentShortcut: KeyboardShortcut? {
        appState.appSettings.customShortcuts[type.rawValue]
    }

    private var isRecording: Bool {
        appState.recordingShortcutFor == type
    }

    private var anotherFieldIsRecording: Bool {
        appState.recordingShortcutFor != nil && !isRecording
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording ? cancelRecording() : beginRecording()
            } label: {
                Text(isRecording
                    ? "Taste dr\u{00FC}cken \u{2026}"
                    : (currentShortcut?.displayString ?? "Nicht belegt"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .frame(minWidth: 88)
            }
            .disabled(anotherFieldIsRecording)

            if currentShortcut != nil && !isRecording {
                Button {
                    appState.setShortcut(nil, for: type)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(anotherFieldIsRecording)
                .help("K\u{00FC}rzel entfernen")
            }
        }
        .onDisappear {
            cancelRecording()
        }
    }

    private func beginRecording() {
        guard keyMonitor == nil, appState.recordingShortcutFor == nil else { return }
        appState.beginShortcutCapture(for: type)
        pendingModifierFlags = 0

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                handleRecordingFlagsChanged(event)
                return nil
            }

            let plainPress = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.function)
                .isEmpty

            switch (event.keyCode, plainPress) {
            case (53, true): // Escape without modifiers: cancel
                cancelRecording()
            case (51, true): // Delete without modifiers: clear binding
                appState.setShortcut(nil, for: type)
                cancelRecording()
            default:
                let shortcut = KeyboardShortcut(
                    keyCode: Int(event.keyCode),
                    rawModifierFlags: UInt64(event.modifierFlags.rawValue)
                )
                if !Self.blockedShortcuts.contains(shortcut) {
                    appState.setShortcut(shortcut, for: type)
                }
                // The recorded key may still be physically held: keep
                // swallowing it so the fresh binding does not fire instantly.
                finishRecording(drainingKeyCode: Int(event.keyCode))
            }
            return nil
        }

        // Abandoned recordings (focus lost, never pressed a key) would leave
        // every hotkey suspended; auto-cancel after a generous timeout.
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            cancelRecording()
        }
    }

    private func handleRecordingFlagsChanged(_ event: NSEvent) {
        let raw = UInt64(event.modifierFlags.rawValue)
        let genericCount = (raw & KeyboardShortcut.genericMask).nonzeroBitCount
        let pendingCount = (pendingModifierFlags & KeyboardShortcut.genericMask).nonzeroBitCount

        if genericCount >= pendingCount, genericCount > 0 {
            // Track the largest modifier chord held so far; partial releases
            // (e.g. letting go of rCmd before rAlt) keep the full chord.
            pendingModifierFlags = raw
        } else if genericCount == 0, pendingModifierFlags != 0 {
            // All modifiers released without a key: modifier-only shortcut —
            // a single modifier (right-Option alone) or a chord (rAlt+rCmd).
            let shortcut = KeyboardShortcut(keyCode: nil, rawModifierFlags: pendingModifierFlags)
            appState.setShortcut(shortcut, for: type)
            finishRecording(drainingKeyCode: nil)
        }
    }

    private func cancelRecording() {
        finishRecording(drainingKeyCode: nil)
    }

    private func finishRecording(drainingKeyCode: Int?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingModifierFlags = 0
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        guard isRecording else { return }
        appState.endShortcutCapture(drainingKeyCode: drainingKeyCode)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
