# Setup

This guide is for people who want to build and inspect the preview themselves.

## 1. Requirements

- macOS 14 or newer
- Full Xcode, with Command Line Tools installed
- XcodeGen
- Homebrew, if you want to install XcodeGen with `brew install xcodegen`
- Optional for online workflows: an OpenAI API key
- Optional for Blitztext Mail: an Anthropic API key (in addition to the OpenAI key, which still does the transcription)
- Optional for secure local transcription: a local WhisperKit/CoreML model

Install XcodeGen manually if needed:

```bash
brew install xcodegen
```

## 2. Clone And Build

```bash
git clone https://github.com/cmagnussen/blitztext-app.git
cd blitztext-app
./build.sh --debug
```

To launch after building:

```bash
./build.sh --run
```

## 3. Configure OpenAI For Online Workflows

Open the app settings and paste your own OpenAI API key if you want online transcription or rewriting workflows.

The preview currently uses:

- `gpt-live-transcribe` for live transcription while you speak (OpenAI Realtime API, WebSocket, audio streamed during recording)
- `gpt-transcribe` as fallback: if the live connection fails, errors, or returns nothing, the recorded file is transcribed with this model in one request
- `gpt-4.1-mini` for lightweight rewriting
- `gpt-4.1` for the calmer-message and prompt workflows

You are responsible for API access, billing, and data handling in your own OpenAI account.

Never commit your API key into this repository, issues, logs, or screenshots.

You can skip this step if you only want to test local transcription with a local WhisperKit model.

### Anthropic Key For Blitztext Mail

Blitztext Mail writes the reply with Claude. Paste your own Anthropic API key (`sk-ant-...`) under **Zugang -> Anthropic API Key** in the app settings. The key is stored in the macOS Keychain, like the OpenAI key. The workflow uses `claude-sonnet-5-5` and needs both keys: OpenAI for transcribing your dictation, Anthropic for writing the reply. If one is missing, the workflow stops with a message naming it.

## 4. Optional Local Transcription

To use secure local transcription, choose a compatible WhisperKit CoreML model in the app and click **Installieren**. Blitztext stores models in:

```text
~/Library/Application Support/Blitztext/models/whisperkit/
```

Recommended first model: `openai_whisper-small_216MB`.

See [local-models.md](local-models.md) for the exact command, model links, and expected folder layout.

## 5. macOS Permissions

The app needs Microphone permission to record audio.

For automatic paste into the previous app, grant Accessibility permission in macOS System Settings. Without it, you can still copy and paste manually.

Blitztext Mail additionally needs Automation permission for Mail. On first use macOS asks "Blitztext möchte Mail steuern." Click **OK**; if you declined, enable it under **Privacy & Security -> Automation -> Blitztext -> Mail**. The app only reads the selected message (subject, sender, date, recipients, text) and the title of the frontmost Mail window (via the Accessibility permission it already uses). It does not send mail or open reply windows. Workflow: select the mail in Mail, click Reply yourself, hold right Option + M, dictate your points, release, review the pasted reply, send it yourself. Typed alternative: press right Option + N once (single press, independent of the hold/press mode), type your points into the panel (Enter sends, Shift+Enter new line, Esc cancels). Blitztext then brings the reply window back to the front and pastes. If the window was closed meanwhile, the text stays on the clipboard. The typed variant needs only the Anthropic key. After pasting, a small panel "Prüfen vor dem Senden" (top right of the screen holding the reply window) may list review hints from the thread (Widerspruch, Schon beantwortet, Offen). It does not take focus from Mail, stays until you close it with X, and is replaced when the next Blitztext Mail run starts. The hints are never part of the pasted text and come from the same single Claude request (no extra data leaves the Mac). New mail: both shortcuts also work in a new-mail window whose title has no reply/forward prefix ("Neue E-Mail" or a typed subject). Blitztext then reads only that window through Accessibility (recipient display names in To/Cc, current subject; no selection lookup, no thread sent) and Claude writes a complete mail from your points. Default is Du; say "siezen" in the points for Sie. To decide Du/Sie and get names right, Blitztext also asks Mail (AppleScript, all accounts and mailboxes, a few seconds, in parallel to your dictation) for the newest mail you received from the first To recipient and sends an excerpt (up to about 4,000 characters) to Anthropic with the request; without such a mail, or when the lookup fails or takes longer than about 10 seconds, it is skipped and Du is used. An empty subject is filled with a suggested one (an existing subject is never overwritten), and the text is pasted into the message body. No review hints in this mode; nothing is sent. Both shortcuts can be changed under **Tastenkürzel**.

Blitztext does not need Full Disk Access. Auto-paste uses the Accessibility permission because the app simulates Cmd+V after putting the result on the clipboard.

## Troubleshooting

- If `xcodebuild` reports that the active developer directory is only Command Line Tools, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- If the build cannot find XcodeGen, install it explicitly with `brew install xcodegen`.
- If online transcription fails immediately, check whether the API key is present and valid.
- If secure local mode is disabled, check whether a WhisperKit model is installed in the expected folder.
- If transcription works but paste does not, this is not an OpenAI billing issue. Check **Privacy & Security -> Accessibility**, restart Blitztext after changing the permission, and make sure the cursor is focused in a text field before starting the workflow.
- If macOS shows multiple Blitztext entries under Accessibility, remove or disable stale entries, run the app from the final location (`/Applications` if you used `./build.sh --install`), then grant the permission again.
- If the target app blocks synthetic paste or the target app was not detected, the result still stays on the clipboard so you can press Cmd+V manually.
- If audio is missing, check Microphone permission and macOS input settings.
- If Blitztext Mail says it may not control Mail, enable the Automation entry above, then try again. If it says the selected mail does not match the reply window, select the mail you are answering in the mailbox list first.
- If you see OpenAI errors, verify model access and account billing.
