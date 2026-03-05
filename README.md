# Refreshing

A macOS menu bar app that prevents kernel panics (DCPEXT PANIC) on Apple Silicon Macs with external monitors running above 120Hz.

## The Problem

macOS Sequoia (and versions of macOS since then) have a bug in the Display Coprocessor (DCP) firmware that causes kernel panics when Apple Silicon Macs wake from sleep or reconnect to external monitors running at refresh rates above 120Hz. This primarily affects 4K 240Hz QD-OLED panels (Samsung, ASUS ROG, MSI MPG, etc.) and manifests as `DCPEXT2 PANIC - apt firmware: dual_pipe` in crash logs.

The issue is a regression introduced in Sequoia - it does not occur on Sonoma.

## How It Works

Refreshing allows you to run the monitor at refresh rates above 120Hz but
ensures that whenever the monitor is reconnected or the machine wakes from sleep
the default refresh rate on initialisation of the monitor is kept at 120Hz. The
app then upshifts back to 240Hz after the initial connection, avoiding the
codepath that triggers the panic.

it uses a two-layer strategy to achieve this:

### Permanent 120Hz in the WindowServer plist

When the app sets the display to 120Hz, it uses `CGCompleteDisplayConfiguration(.permanently)`, which writes the mode to macOS's display preferences plist. This means WindowServer will request 120Hz when negotiating with the display on reconnection, avoiding the dangerous >120Hz DCP code path.

When upshifting to 240Hz for active use, it uses `.forSession` - a temporary change that is **not** written to the plist. If the display disconnects while at 240Hz, the plist still says 120Hz, so the next connection is safe.

### Display reconfiguration callback

The app registers a `CGDisplayRegisterReconfigurationCallback` to react immediately when an external display is connected or disconnected:

1. **Display connected** → immediately set 120Hz (permanently)
2. **Wait 3 seconds** for the display link to stabilize
3. **Upshift to 240Hz** (session-only) at the target resolution

### Sleep/wake safety net

As a secondary defense, the app uses `IORegisterForSystemPower` to intercept sleep events with acknowledgement gating - the system cannot sleep until the refresh rate change completes. On sleep, it applies the pre-cached 120Hz mode permanently.

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon Mac
- External monitor with refresh rate above 120Hz
- Xcode Command Line Tools (`xcode-select --install`)

## Building

```sh
make
```

This builds `Refreshing.app` in the project directory and ad-hoc signs it.

To install to `/Applications`:

```sh
make install
```

To clean:

```sh
make clean
```

## Installing a Pre-built Release

If you download a pre-built `Refreshing.app`, macOS Gatekeeper will block it because it is not notarized. To allow it to run:

1. Move `Refreshing.app` to `/Applications` (or wherever you want it)
2. **Do not double-click it** - it will just show a warning with no option to open
3. Instead, **right-click** (or Control-click) the app and select **Open**
4. A dialog will appear saying the app is from an unidentified developer - click **Open**
5. macOS will remember this choice and the app will launch normally from now on

Alternatively, from Terminal:

```sh
xattr -c Refreshing.app
open Refreshing.app
```

## Usage

Run the app - a display icon appears in the menu bar. The menu provides:

- **Enable/disable** the automatic refresh rate management
- **Display picker** if multiple external monitors are connected
- **Resolution** - defaults to native, can be changed if desired
- **Sleep Hz** - the safe refresh rate (default: 120Hz)
- **Wake Hz** - the active refresh rate (default: 240Hz)
- **Launch at Login** - uses `SMAppService` for login item registration

All settings persist across app restarts.

## Debugging

The app logs to the system log with the `[Refreshing]` prefix. To watch in real time:

```sh
log stream --predicate 'eventMessage CONTAINS "[Refreshing]"' --level debug
```

## Architecture

| File | Purpose |
|------|---------|
| `RefreshingApp.swift` | `@main` entry point, `MenuBarExtra` scene |
| `DisplayManager.swift` | CoreGraphics display enumeration, mode switching, resolution detection |
| `SleepWakeManager.swift` | IOKit sleep/wake callbacks with acknowledgement gating |
| `AppState.swift` | `ObservableObject` - state coordination, UserDefaults persistence, display connect/disconnect handling |
| `MenuBarView.swift` | SwiftUI menu bar UI |
