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

- `AppDelegate.swift` — `@MainActor`, status bar, menu, 4 Carbon hotkeys, all capture entry points
- `ScreenRecorder.swift` — ScreenCaptureKit `SCStream` + `AVAssetWriter` encoding
- `RecordingController.swift` — `@MainActor` singleton orchestrating the record flow
- `Annotation.swift` — largest file (~1070 lines); annotation tools, canvas, toolbar
- `HistoryStore.swift` — `@MainActor`, capture index (`history.json`) + files in Application Support, capped at 100 entries
- Everything else is one window/panel controller per file

Most controllers are lazily created and nil'd on dismiss. Singletons: `HistoryStore`, `RecordingController`, `PinnedImageController`, `ToastController`, `AllInOneController`, `ShortcutStore`, `SoundStore`, `SoundEffect`, `UpdaterController`.

## Conventions

- No dependency injection — singletons via `.shared`
- Windows are `orderOut(nil)` + reference nil'd, not `close()`d
- Swift 5 language mode, no strict concurrency by default, but UI-only types (`AppDelegate`, `HistoryStore`, `AnnotationWindowController`, `PinnedImageController`, `MainWindowController`) are explicitly `@MainActor` since Phase 4 rather than relying on "runs on main in practice." `MainActor.assumeIsolated { }` is the escape hatch for contexts the compiler can't see are main-isolated (e.g. `main.swift` top-level code, `SCStream`/`AVCaptureSession` delegate callbacks known to land on main); concurrency warnings from AVFoundation captures (`WebcamWindow.swift`, `ScreenRecorder.swift`'s non-exhaustive switch) are pre-existing and tolerated.
- The recorder's hot path (`ScreenRecorder.handleVideo`/`handleSystemAudio`, called per frame/buffer) uses `OSAllocatedUnfairLock` instead of `DispatchQueue.sync` for state shared across the sample/audio queues — cheaper, and makes check-then-act atomic (see `tryStartSession()`).
- Sequencing sometimes uses hardcoded `asyncAfter` delays rather than real synchronization

## Performance notes

The app is **not** thread-heavy at idle — measured 0.0% CPU, 3 threads, ~66 MB RSS. There are no polling loops, no busy-waits, and no idle timers. Only 4 `DispatchQueue`s exist, all instance properties.

Historical slowdowns traced to two things, not thread count:
1. **Main-thread blocking** — fixed in Phase 3: `DesktopIcons` no longer forks a subprocess on the menu-bar read path, and PNG encode/index-write/thumbnail-decode work moved off `HistoryStore.add`, `ImageSaver.saveToDesktop`, and `RecordingCompletePopup` onto background queues.
2. **Per-recording leaks** — the SCStream retain cycle (fixed, see roadmap)

When touching the recording path, remember `SCStream` retains its delegate/output strongly. Always `removeStreamOutput` before dropping the stream.

When touching `HistoryStore`, remember `save()` is debounced (400ms) and runs off-main — call `flushPendingSave()` before anything that must observe the index on disk immediately (e.g. app termination).

## Dependencies

- `Sparkle` (SwiftPM) — auto-update framework, pinned via `from:` range in `Package.swift`.
- `website/` — separate npm project (marketing site), not part of the app build. Has its own `package.json`/`package-lock.json`.

No CI runs dependency audits yet (Phase 5). If GitHub reports Dependabot alerts, there's no automatic gate blocking them — check `gh api repos/<owner>/<repo>/dependabot/alerts` and fix manually; for `website/`, bumping the `vite` semver range in `package.json` and reinstalling has been enough to clear transitive advisories (esbuild/babel/postcss all sit under vite).

## Settings

`SettingsView` (`MainWindow.swift`) is a `ScrollView { VStack(spacing:14) }` with `SettingsCard` tiles (34×34 icon `cornerRadius 9` `tint.opacity(0.14)`). Cards: **Sound** (`speaker.wave.2.fill` orange, `SoundStore` `isShutterEnabled` `UserDefaults` `com.shotx.shutterSoundEnabled` default ON, `Toggle .switch`), **Shortcuts** (`command` blue, 4 `ShortcutRecorder` rows), **About** (`info.circle.fill` gray). `SoundStore` is `@MainActor ObservableObject` mirroring `ShortcutStore`'s `didSet -> persist` pattern; `SoundEffect.playShutter()` early-returns when disabled.

## Roadmap

See `ROADMAP.md` for what has been done and what is next.
