# DisplayWave

A small macOS menu bar app that turns external monitors on and off, and adjusts their
brightness and warmth — including monitors that don't support DDC.

Built because the usual approach (DDC over the cable) only worked on one of three
monitors, and the feature that works everywhere is paywalled in BetterDisplay Pro.

## What it does

Click the sun icon in the menu bar. Every connected display gets:

- **A name row** — click to disconnect/reconnect that display (its power toggle)
- **A brightness slider**
- **A warmth slider**

Settings are saved per monitor and reapplied automatically after sleep or a display
change, which macOS would otherwise wipe.

## Build

```bash
./build.sh
open DisplayWave.app
```

Requires macOS 13+ and Xcode command line tools. No dependencies.

To start it at login: System Settings → General → Login Items → add `DisplayWave.app`.

## How it works, and why

There are two ways to control a monitor, and they are not equivalent.

**DDC/CI** sends commands down the video cable asking the monitor to change its own
settings. This is what MonitorControl, Lunar, and DisplayBuddy use. It gives true
hardware control — real backlight dimming, real power-off — but only if the monitor
implements DDC and its cable/adapter passes the signal through. When that fails, it
fails completely and no software can fix it.

**OS-level control** never talks to the monitor. It changes what the Mac does:

- `CGSConfigureDisplayEnabled` (private CoreGraphics SPI) tells macOS to stop driving
  a display. The monitor loses signal and enters standby by itself. This is what
  BetterDisplay Pro's "disconnect" feature does, and it's why that works on every
  monitor — the monitor gets no say.
- `CGSetDisplayTransferByFormula` changes the GPU's gamma transfer table, which
  dims and tints the image before it's sent out. Not true backlight dimming, but it
  works regardless of the monitor.

This app uses the OS-level approach for everything, so it works on monitors with no
usable DDC at all.

### Notes

- Disconnecting a display **removes it from the display list entirely**, so its ID is
  saved to `UserDefaults` — otherwise there'd be no way to bring it back.
- Power changes use `kCGConfigureForSession`, so **a restart always restores every
  display** regardless of app state.
- The app refuses to turn off the last active display.
- Brightness has a floor of 0.15 so a screen can never go fully black.
- These are private APIs: not App Store distributable, and Apple can change them in
  any macOS release. The gamma APIs in particular have been reported broken on some
  Tahoe / M5 configurations.

## Diagnosing a monitor that won't respond to DDC

`tools/` holds the throwaway programs used to work out why two monitors were
unreachable. `tools/probe/` walks every display port and attempts checksum-verified
DDC reads with several timing profiles; `tools/gammatest.swift` verifies whether the
gamma APIs actually apply on this machine.

What they found on the original setup, for reference:

| Monitor | DDC result |
|---|---|
| HP VH240a | Works — clean reads and writes |
| Acer EI272UR | Dead channel; writes hang ~73s in the kernel and nothing ACKs |
| Samsung S34J55x | Returns a fixed 64-byte block, identical every read — nothing is listening |

If DDC hangs on a port, stop probing it. Repeated writes to a wedged channel can drop
the display off the system until it's physically replugged.
