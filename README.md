# DisplayWave

A small macOS menu bar app that turns external monitors on and off, and adjusts their
brightness and warmth — including monitors that don't support DDC.

Built because the usual approach (DDC over the cable) only worked on one of three
monitors, and the feature that works everywhere is paywalled in BetterDisplay Pro.

## What it does

Click the moon icon in the menu bar. Every connected display gets a card showing its
name, with:

- **Resolution and refresh rate dropdowns** — the mode line under the display's name
  is directly changeable. Resolution picks keep the current refresh rate when the new
  resolution offers it, and prefer the HiDPI variant so text stays sharp. Changes are
  applied the same way System Settings does, so they survive restarts.
- **A power button** — disconnects that display; click it again in the "Turned off"
  section to bring it back
- **Brightness** — slider plus 25 / 50 / 75 / 100% presets. On monitors that answer
  DDC this drives the actual backlight; on the rest it dims the image on the GPU and
  the label reads *Brightness · software*
- **Warmth** — slider plus 0 / 25 / 50 / 75 / 100% presets

At the bottom, **scenes** set brightness and warmth on every display at once:

| Scene | Brightness | Warmth |
|---|---|---|
| Day | 100% | 0% |
| Evening | 70% | 40% |
| Night | 40% | 80% |

**Keep Mac Awake** holds a power-management assertion so the Mac and its displays
don't sleep — the same trick as `caffeinate`. It is deliberately session-only: it
never survives a relaunch, so the machine can't be left sleepless by a forgotten
setting.

Settings are saved per monitor and reapplied automatically after sleep or a display
change, which macOS would otherwise wipe.

There is no "detect displays" button on purpose: the menu re-enumerates displays
every time it opens, and a reconfiguration callback catches plugging and unplugging,
so the list is always current.

## Working on the UI

```bash
./DisplayWave.app/Contents/MacOS/DisplayWave --preview out.png
```

Renders the menu's cards to an image so layout can be checked without opening the menu
by hand. Two things that cost time to discover:

- AppKit controls are layer-backed. They only capture via `CALayer.render(in:)` from
  inside a running app with a real window; `cacheDisplay` alone produces a blank image.
- Run the executable **inside the bundle**, not the bare `./DisplayWave` binary. Run
  bare, it gets a different preferences domain and shows defaults instead of your real
  settings.

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

The app uses DDC for brightness when a monitor supports it, because only that
genuinely lowers light output, and falls back to gamma otherwise. Power and warmth
always take the OS-level route, so they work on every monitor.

### Why not always gamma, or always DDC

Gamma dimming darkens the picture but the backlight keeps blazing behind it, so blacks
stay grey and a dark room still feels lit. DDC lowers the actual backlight — but only
if the monitor answers, and many don't.

When a monitor does support DDC, the two are never stacked: the backlight does the
dimming and gamma stays at full brightness, so the picture doesn't end up doubly dark.

### Detecting support safely

A monitor that ignores DDC is not merely slow to answer. `IOAVServiceWriteI2C` can
block inside the kernel for over a minute on a dead channel, and killing a thread
partway through a transaction can drop the display off the system entirely until it is
physically unplugged and replugged. So detection:

- probes each monitor **once**, caches the verdict, and never probes again unasked
- runs on a detached thread that is **abandoned rather than killed** if it times out
- never retries a channel that already failed

A display reconfiguration — a mode change, sleep, replugging — also tears down the
DDC service handles, and writes through a stale handle silently vanish. The app
re-resolves handles after every reconfiguration and wake (registry-only, no DDC
traffic), and if a backlight write still fails it re-resolves once more and retries,
so brightness keeps working without manual intervention.

Use **Re-check Backlight Support** after changing a cable or enabling DDC/CI in a
monitor's own on-screen menu — that's the one case that needs a fresh probe rather
than a fresh handle.

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
