# ShotX

macOS menu-bar screenshot and screen-recording app. Swift + SwiftPM, no Xcode project.

## Build & run

```bash
swift build                  # debug
swift build -c release       # release
./.build/release/ShotX       # run the bare binary
./Scripts/build-app.sh       # assemble dist/ShotX.app (universal, signed)
./Scripts/launch.sh          # rebuild-if-stale, pkill, relaunch
```

There is no `Info.plist` in the repo — `Scripts/build-app.sh` generates it inline via heredoc (`LSUIElement = true`, Sparkle keys, usage strings).

**Signing gotcha:** the build script ad-hoc signs (`-`) by default, which resets the Screen Recording TCC grant on every rebuild. Run `Scripts/create-signing-cert.sh` once and use a stable identity, otherwise permission churn looks like a regression.

## Architecture

Entry is `main.swift` (top-level code, no `@main`) → `AppDelegate`. The app is an accessory/agent: no Dock icon, everything hangs off an `NSStatusItem`.

- `AppDelegate.swift` — status bar, menu, 4 Carbon hotkeys, all capture entry points
- `ScreenRecorder.swift` — ScreenCaptureKit `SCStream` + `AVAssetWriter` encoding
- `RecordingController.swift` — `@MainActor` singleton orchestrating the record flow
- `Annotation.swift` — largest file (~1070 lines); annotation tools, canvas, toolbar
- `HistoryStore.swift` — capture index (`history.json`) + files in Application Support, capped at 100 entries
- Everything else is one window/panel controller per file

Most controllers are lazily created and nil'd on dismiss. Singletons: `HistoryStore`, `RecordingController`, `PinnedImageController`, `ToastController`, `AllInOneController`, `ShortcutStore`, `SoundEffect`, `UpdaterController`.

## Conventions

- No dependency injection — singletons via `.shared`
- Windows are `orderOut(nil)` + reference nil'd, not `close()`d
- Swift 5 language mode, no strict concurrency. `MainActor.assumeIsolated { }` is the established escape hatch; concurrency warnings from AVFoundation captures are pre-existing and tolerated
- Sequencing sometimes uses hardcoded `asyncAfter` delays rather than real synchronization

## Performance notes

The app is **not** thread-heavy at idle — measured 0.0% CPU, 3 threads, ~66 MB RSS. There are no polling loops, no busy-waits, and no idle timers. Only 4 `DispatchQueue`s exist, all instance properties.

Historical slowdowns traced to two things, not thread count:
1. **Main-thread blocking** — subprocess forks during menu construction, full-resolution PNG encoding on the main queue
2. **Per-recording leaks** — the SCStream retain cycle (fixed, see roadmap)

When touching the recording path, remember `SCStream` retains its delegate/output strongly. Always `removeStreamOutput` before dropping the stream.

## Roadmap

See `ROADMAP.md` for what has been done and what is next.
