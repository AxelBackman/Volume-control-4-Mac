# VolumeMixer

Per-app volume control for macOS — the Windows volume mixer, for a Mac.

A menu bar app that lists every application playing audio and gives each one its own slider,
mute button and level meter, plus a master control for everything at once.

## Requirements

- **macOS 14.4 or later.** Core Audio process taps arrived in 14.2 and the audio capture
  permission landed in its own TCC category in 14.4.
- **Command Line Tools for Xcode 26 or later** (Swift 6, SDK 26). Full Xcode is not needed.

  ```sh
  softwareupdate --list                                        # find the current label
  sudo softwareupdate -i "Command Line Tools for Xcode 26.6-26.6"
  xcrun --show-sdk-version                                     # expect 26.x
  ```

- **A code signing identity.** See [Signing](#signing) — this is not optional in practice.

## Quick start

```sh
make run      # build, bundle, sign, launch
make stop     # quit the app; every tapped app returns to normal immediately
make test     # run the self-tests
make debug    # same as run, but with diagnostics in the unified log
```

The first launch asks for permission to record system audio. Granting it is what makes the
mixer work at all; see [Permissions](#permissions).

### All targets

| Target | What it does |
|---|---|
| `make build` | Compile only |
| `make bundle` | Build and assemble `build/VolumeMixer.app` |
| `make sign` | Bundle and code sign (falls back to ad-hoc with a warning) |
| `make run` | Sign and launch |
| `make debug` | Launch with `VOLUMEMIXER_DEBUG=1` for per-IO-proc diagnostics |
| `make stop` | Quit a running instance |
| `make test` | Run the self-tests |
| `make clean` | Remove `.build` and `build` |
| `make cert-help` | How to create a local signing identity |
| `make dist-setup` | How to set up notarised distribution |
| `make dist` | Sign, notarise and staple a shareable zip |

## Signing

The audio capture permission is tied to the app's code signature. With an ad-hoc signature
(`codesign -s -`) every rebuild produces a new cdhash, so macOS treats each build as a new
app and asks for permission again.

Create a stable local identity once:

1. Open **Keychain Access**
2. **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `VolumeMixer Dev`, Identity Type: *Self Signed Root*, Certificate Type: *Code Signing*
4. Verify: `security find-identity -v -p codesigning`

`make sign` picks it up automatically. Override the name with `make sign SIGN_ID="..."`.

## Permissions

VolumeMixer needs **System Audio Recording** (`kTCCServiceAudioCapture`). It does not need
screen recording, and it does not need microphone access.

macOS has no public API to read or request this permission, so the app calls
`TCCAccessPreflight` / `TCCAccessRequest` through `dlsym` and degrades gracefully if those
symbols ever disappear — the system prompts on its own when the first tap starts.

This matters more than it looks. A tap is created with `muteBehavior = .mutedWhenTapped`,
which pulls the app's audio out of the normal output path whether or not we are allowed to
receive the samples. If permission were denied and nothing noticed, every tapped app would be
silenced for good. A failsafe watches for that: if a tapped app is playing and no tap has
delivered a single non-silent sample within 10 seconds, everything is torn down and the UI
says why.

### Microphone

An aggregate device inherits its sub-device's input streams. On a headset that means the
microphone shows up in the aggregate, which is why macOS asks about microphone access.
`kAudioSubDeviceInputChannelsKey` looks like the way to drop those channels, but the HAL
ignores it at creation time — verified on macOS 26.6 with the key alone and paired with
`kAudioSubDeviceOutputChannelsKey`. The header describes it as a report of state, not a
directive.

Two things make this harmless: the IO proc skips those channels entirely, and the app never
grants itself microphone access. If you deny the microphone prompt, nothing breaks.

## How it works

```
App process ──► Process Tap (mutedWhenTapped) ──► Aggregate Device (private)
                                                   ├── main sub-device = physical output
                                                   └── sub-tap (drift compensation)
                                                         │
                                  IO proc: out[i] = in[i] × ramped gain
                                                         ▼
                                                  Physical output device
```

One aggregate device per tapped app. A shared aggregate with several sub-taps would have to be
rebuilt — interrupting *every* app — each time one app starts or stops playing.

**Finding apps.** `kAudioHardwarePropertyProcessObjectList` gives every process coreaudiod
knows about. Helper processes are grouped under the outermost `.app` in their executable path,
so `Google Chrome Helper (Renderer).app` lands under `Google Chrome.app`. An app earns a row
the first time it opens an output stream and keeps it until its process exits — pausing Spotify
does not make its slider vanish mid-drag.

Note that this state is **polled once a second**. Property listeners on
`kAudioProcessPropertyIsRunningOutput` do not fire reliably, so relying on them alone means an
app that starts playing is simply never noticed.

**Rendering.** The IO proc reads the tap's channels, multiplies by a gain ramped over 20 ms and
writes to the output device in the same cycle. It allocates nothing, takes no locks, logs
nothing and never touches a Swift object — gain and meter values move through atomics, and all
mutable state lives in manually managed memory.

The tap's channels are **not** at the start of the input buffer list: an aggregate device lists
its sub-device's input streams first, so on a device with inputs the microphone comes before
the tap. The offset is computed per cycle.

**Staying alive.** Taps are rebuilt when the output device or its sample rate changes, when the
machine wakes from sleep, when an app starts playing from a process the tap does not cover, and
when an IO proc stops running while its app is still playing.

## Master volume

The master control does one of two things depending on the output device:

| | Device has software volume | Device does not |
|---|---|---|
| What changes | The device's own volume | Gain on each tapped app |
| Volume keys | Slider follows them | Unaffected |
| Control Center | Same value | Unaffected |
| Covers system alert sounds | Yes | Yes, if they have been tapped |

Many USB headsets — the SteelSeries Arctis range among them — do their volume in hardware and
expose nothing to macOS. Hover the master row to see which mode is active.

## Project layout

```
Package.swift                     swift-tools 6.0, macOS 14.4, depends on swift-atomics
Makefile                          build / sign / run / test / dist
Resources/Info.plist              LSUIElement, NSAudioCaptureUsageDescription
Sources/
  VolumeMixerCore/                pure, testable logic
    AppGrouping.swift             executable path → owning .app bundle
    GainRamp.swift                click-free gain smoothing
  VolumeMixer/
    VolumeMixerApp.swift          @main, MenuBarExtra, teardown on quit
    Audio/
      CoreAudioUtils.swift        property helpers, listeners, OSStatus → Error
      AudioProcessMonitor.swift   which apps have audio, and grouping
      ProcessTap.swift            tap lifecycle
      AggregateOutput.swift       aggregate device + IO proc lifecycle
      AppTapController.swift      one app: tap, aggregate, real-time rendering
      MixerEngine.swift           orchestration, device changes, failsafes
      SystemOutput.swift          output device queries, device volume and mute
      AudioCapturePermission.swift TCC preflight and request via dlsym
    Model/MixerViewModel.swift    observable UI state
    UI/                           popover, rows, level meters
    Support/LoginItem.swift       SMAppService registration
  SelfTest/main.swift             runs the pure-logic checks
```

### Why `SelfTest` instead of XCTest

Both XCTest and swift-testing ship with Xcode, not with the Command Line Tools. Since the
whole point is building without Xcode, the pure-logic checks run as a plain executable:
`make test`.

## Debugging

```sh
make debug
/usr/bin/log stream --predicate 'subsystem == "se.qte.volumemixer"'
```

Once a second, each tapped app reports what its IO proc actually sees:

```
output=Arctis Nova Pro Wireless uid=... rate=48000 apps=2 tapped=2 master=mixer/1.000000
  Firefox: cycles=502 frames=512 in=2buf/3ch out=1buf/2ch bail=0 inPeak=0.029
```

| Field | Meaning |
|---|---|
| `apps` / `tapped` | Rows in the list / apps under mixer control |
| `master` | `system` (device volume) or `mixer` (gain), and its value |
| `cycles` | IO proc invocations — frozen means a stalled proc |
| `in` / `out` | Buffer and channel layout per cycle |
| `bail` | 0 fine, 1 no frames, 2 no channels, 3 no channel pointer, 4 empty after clamping |
| `inPeak` | Loudest sample the tap has delivered |

Reads of the process list and its properties need no permission at all, so `apps=` is
trustworthy even before the capture permission is granted.

## Known limitations

- **Virtual output devices do not work.** Aggregate devices cannot be nested, so if your output
  is already an aggregate or a virtual driver (BlackHole, Loopback) the mixer says so and stays
  out of the way.
- **Volumes are not persisted.** They reset when the app quits.
- **No boost above 100%.**
- **Changing output device briefly interrupts tapped apps** while the aggregates are rebuilt.
- **Apps that spawn audio helpers rebuild their tap** when a new one appears, which costs a
  short gap for that app. League of Legends does this during startup.
- **Latency** is roughly one IO buffer plus the device's safety offset, about 10 ms at 48 kHz
  and 512 frames. Fine for playback, not for monitoring live input.
- **Unbundled binaries and system agents get rows too.** They never quit, so those rows stay
  for the session.

## Distribution

Sharing with other Macs realistically needs an Apple Developer Program membership. Without a
Developer ID signature and notarisation, every recipient has to right-click → Open, approve the
app in System Settings → Privacy & Security, and possibly clear the quarantine attribute by
hand.

```sh
make dist-setup                                           # one-time instructions
make dist DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
```

That signs with the hardened runtime, submits to Apple's notary service, waits, staples the
ticket and produces `build/VolumeMixer.zip`. Recipients unzip and double-click.

## License

Not yet chosen.
