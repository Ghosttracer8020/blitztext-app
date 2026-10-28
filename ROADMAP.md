# Roadmap

This is a preview roadmap, not a promise.

## Current Scope

- macOS menubar app
- local recording and hotkeys
- direct OpenAI API calls (and Anthropic API calls for Blitztext Mail) with user-provided API keys
- transcription, rewriting, calmer-message, emoji, prompt-crafting, and Apple Mail reply workflows
- no hosted backend
- no other platforms
- no packaged public release

## Next Useful Work

- Make first-run setup clearer.
- Improve credential setup, validation, and recovery UX.
- Add a small automated test layer around prompt construction and text quality filters.
- Add provider boundaries so OpenAI and future local transcription can be swapped more cleanly.
- Prototype local transcription with WhisperKit or whisper.cpp.
- Reduce the Accessibility blast radius, ideally by moving synthetic paste into a smaller helper with narrower responsibilities.
- Add stronger supply-chain checks around downloaded local speech models.
- Add signed and notarized release builds when the project is ready for non-developer users.

## Not In Scope Yet

- Production support.
- Accounts, sync, teams, or hosted infrastructure.
- Claims that the app is offline or privacy-complete.
- App Store distribution.
