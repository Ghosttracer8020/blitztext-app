# Blitztext App

Blitztext App is an experimental open-source macOS menubar app for turning speech into text.

It is intentionally small and unfinished. The goal is to make a real workflow visible and hackable: press a hotkey, speak, get text back, optionally rewrite it, and paste it into the app you were using.

This is a learning and experimentation project, not a polished product.

> Preview status: bring your own OpenAI API key, no hosted backend, no warranty, no support guarantee.

## What It Does

- **Blitztext**: record speech and transcribe it; optional email paragraphing (greeting/sign-off) is applied on-device, no extra API call.
- **Blitztext+**: record speech, transcribe it, then turn the rough draft into cleaner writing.
- **Blitztext $%&!**: turn frustrated speech into a calmer message.
- **Blitztext :)**: add fitting emojis to dictated text.
- **Blitztext Prompt**: turn spoken instructions into a structured prompt with numbered points you can refer back to.
- **Blitztext Mail**: in an open Apple Mail reply window, dictate bullet points and get a finished reply (always Du unless your dictation explicitly uses Sie/Ihnen or says "siezen"; tone follows the thread) pasted at the cursor. Uses Claude for writing, so it needs an Anthropic API key in addition to the OpenAI key. It never sends anything; you review and send yourself. If Claude finds something worth checking in the thread (a point that contradicts an earlier agreement, a question you ask that was already answered, an open question you did not address), a small non-focus-stealing panel "Prüfen vor dem Senden" appears after the paste; hints never go into the mail text. Default shortcut: right Option + M (dictate). Right Option + N opens a small input panel instead (type the points, Enter sends, Shift+Enter new line, Esc cancels) - same result, for when dictating does not fit; no OpenAI key needed for that variant. The same shortcuts also work in a new-mail window (title without Re:/AW:/Fwd:): Claude then writes a complete mail from your points and the recipient names in To/Cc (greeting, closing), fills the subject only if it is still empty, and pastes into the message body; no hints in that mode. The address form is always Du, unless your points explicitly use the formal address (Sie, Ihnen, ...) or say "siezen" / "per Sie"; nothing else (thread, recipient, sender domain) changes it.

## Important Preview Notes

- macOS only.
- Bring your own OpenAI API key (and an Anthropic API key if you want Blitztext Mail).
- No hosted Blitztext backend is included or provided.
- In online mode, audio and text are sent directly from the app to the OpenAI API. Audio is streamed live to OpenAI while you hold the hotkey; if that fails, the recorded file is transcribed in one request instead.
- Optional local transcription via WhisperKit/CoreML if you install a compatible model locally.
- `./build.sh` creates a locally ad-hoc-signed development app. No notarized release binary is provided.
- Not production ready.
- No warranty and no support guarantee.

You are welcome to use, fork, adapt, and share this project under the license terms.

The intent is not to ship a one-click finished app. The intent is to make a real AI workflow understandable: clone it, build it, read the code, change it, break it, fix it, and suggest improvements. If you only want to download something and never look inside, this preview will probably feel rough. If you want to learn how a small native macOS AI app is put together, you are in the right place.

## Screenshots

<table>
  <tr>
    <td><img src="docs/screenshots/online-mode.png" alt="Blitztext online transcription mode" width="420"></td>
    <td><img src="docs/screenshots/local-mode.png" alt="Blitztext secure local transcription mode" width="420"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/local-model-picker.png" alt="Blitztext local model picker" width="420"></td>
    <td><img src="docs/screenshots/settings-customize.png" alt="Blitztext settings and customization view" width="420"></td>
  </tr>
</table>

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (Swift 5.10), with Command Line Tools installed and selected for `xcodebuild`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project
- For online transcription and rewriting: an OpenAI API key with access to:
  - `gpt-live-transcribe` (live streaming while you speak) and `gpt-transcribe` (fallback on the recorded file) for transcription
  - `gpt-4.1-mini` and optionally `gpt-4.1` for rewriting
- For local-only transcription: a WhisperKit CoreML model in:
  `~/Library/Application Support/Blitztext/models/whisperkit/`

The build also pulls one Swift Package dependency automatically:

- [`argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit) — used for local on-device transcription.

Install XcodeGen if needed:

```bash
brew install xcodegen
```

## Build And Run

```bash
git clone https://github.com/cmagnussen/blitztext-app.git
cd blitztext-app
./build.sh --run
```

For a local install into `/Applications`:

```bash
./build.sh --install --run
```

The generated `.app` is ad-hoc signed for local development only. Do not treat it as a trusted redistributable binary. A public binary release would need Developer ID signing and notarization.

On first launch, either paste your own OpenAI API key for online workflows or install a WhisperKit CoreML model for local transcription. Rewriting workflows still require OpenAI.

For fully local transcription, install a WhisperKit CoreML model and enable **Sicherer Lokaler Modus** in the app.

For a slower, more explicit walkthrough, see [docs/setup.md](docs/setup.md).

## Permissions

Blitztext asks for:

- **Microphone**: to record your voice.
- **Accessibility**: to paste the result back into the app you were using.

If you do not grant Accessibility permission, you can still copy results manually.

Full Disk Access is not required. If auto-paste does not work even though transcription succeeds, open **System Settings -> Privacy & Security -> Accessibility**, enable Blitztext there, restart Blitztext, and try again with the cursor focused in a text field. If macOS shows multiple Blitztext entries, remove or disable the old ones and grant the permission to the app you just built or installed.

## Data Flow

The preview has no custom backend.

```text
Online transcription: Your Mac -> OpenAI Realtime API (WebSocket, live while recording)
                      fallback: Your Mac -> OpenAI Audio Transcriptions API (recorded file)
Text rewriting:       Your Mac -> OpenAI Chat Completions API
Local transcription:  Your Mac -> WhisperKit/CoreML on device
```

The app stores your OpenAI API key in the user's macOS Keychain.

Read [docs/privacy.md](docs/privacy.md) before using the preview with sensitive content.

## Project Structure

```text
BlitztextMac/
  App/          App lifecycle and paste handling
  Features/     Workflows, menu bar UI, settings
  Services/     Recording, OpenAI calls, hotkeys, local storage
  Views/        Shared SwiftUI views
build.sh        Local build script
docs/           Setup, privacy, roadmap, preflight, landing page notes
```

## Local Models

Local transcription is available as an experimental WhisperKit/CoreML path. The app does not bundle a model; choose one in the app, click install, and then switch on **Sicherer Lokaler Modus** from the menu bar or settings.

See [docs/local-models.md](docs/local-models.md).

## Contributing

Contributions are welcome, especially if they make the preview easier to build, understand, or fork.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Support And Roadmap

This preview has no formal support promise. See [SUPPORT.md](SUPPORT.md) for how to ask for help without sharing secrets.

The current direction is documented in [ROADMAP.md](ROADMAP.md). Maintainer-facing release checks live in [docs/open-source-preflight.md](docs/open-source-preflight.md).

## License

Code is released under the MIT License. See [LICENSE](LICENSE).

Project names, logos, and app icons are not automatically granted as trademarks or brand assets. See [TRADEMARKS.md](TRADEMARKS.md).

## Legal / Impressum & Datenschutz

This is an experimental, non-commercial open-source project, provided as-is under the MIT License without warranty or support. Nothing is sold here and no installation or operation is performed on your behalf.

The companion website (blitztext.de) is operated by Blackboat Internet GmbH:

- Impressum: https://www.blackboat.com/impressum
- Datenschutz / Privacy: https://www.blackboat.com/datenschutz
