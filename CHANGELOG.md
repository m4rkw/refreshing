# Changelog

## 0.1.0

Initial release.

- Automatic refresh rate management for external displays on Apple Silicon Macs running macOS Sequoia
- Two-layer protection against DCPEXT PANIC kernel panics:
  - Permanent 120Hz written to WindowServer plist so displays reconnect at a safe rate
  - Session-only upshift to high Hz (e.g. 240Hz) for active use
- Display connect/disconnect detection via CGDisplayRegisterReconfigurationCallback
- Sleep/wake safety net with IOKit acknowledgement gating
- Resolution detection and restoration on reconnect
- Menu bar UI with display picker, resolution picker, sleep/wake Hz pickers
- Launch at Login support via SMAppService
- All settings persist across app restarts
