# ShotX Optimization Roadmap

Tracks the hardening effort started 2026-07-28. Phases ship independently and are ordered by impact-per-risk.

## Background

The work began from a report that ShotX made the machine feel slow, attributed to excessive threads and processes.

**That premise turned out to be wrong, and it reshaped the plan.** A sweep of all 33 source files found no polling loops, no `while true` / `usleep` / busy-waits, no `NotificationCenter` observers, and no repeating timer that runs while the app is idle. Only 4 `DispatchQueue`s exist, all stored as instance properties. Measured at idle on the release binary: **0.0% CPU, 3 threads, ~66 MB RSS, stable.**

The real causes were elsewhere:

1. **Per-recording leaks** — `SCStream` retains the recorder as its delegate while the recorder retains the stream. `stop()` never broke the cycle, so the entire recorder + `AVAssetWriter` graph leaked on *every* recording. Memory growth across a session reads as "the Mac got slow."
2. **Main-thread blocking** — a subprocess fork during menu construction, and full-resolution PNG encoding on the main queue during capture.
3. **Stuck captures** — error paths dropped the recorder without stopping it, leaving a live `SCStream` capturing with nothing consuming frames.

---

## Done

### Phase 0 — Git remote ✅
Repointed `origin` to `https://github.com/rihanaws/shotx-mac-app.git`.

### Phase 1 — Leaks ✅
Commit `3f3b0bb`, branch `fix/leaks-and-shutdown`.

| Fix | File | Was |
|---|---|---|
| SCStream retain cycle | `ScreenRecorder.swift` | `stop()` never called `removeStreamOutput` nor nil'd the stream → whole recorder graph leaked per recording |
| Self-retaining static | `HotKeyManager.swift` | Static dict held instances **strongly**, making `deinit` unreachable; also unsynchronized between the Carbon callback and `init`/`deinit` |
| Missing `deinit` | `WebcamWindow.swift` | Dropping the object without `dismiss()` left the camera running |
| Never released | `MainWindow.swift` | SwiftUI history grid stayed resident for the app's lifetime |

### Phase 2 — Stuck captures & clean shutdown ✅
Same commit.

- Both recording error paths now `stop()` the recorder before releasing it. `start()` tears itself down before rethrowing if mic capture fails after the stream went live — previously this left an `SCStream` capturing forever with the screen-recording indicator lit.
- Added `applicationShouldTerminate`: an in-flight recording is finalized instead of leaving an unplayable MP4. Idle quit keeps the immediate path (measured 0.07s); a 5s backstop prevents a hang.
- Temp files removed on failure and GIF-abort paths; stale `shotx-` scratch files swept at launch.
- `GIFConverter` fails on zero decoded frames instead of finalizing an unopenable GIF and reporting success.
- `stop()` fences through both sample queues before `markAsFinished()`, since appending after it raises an ObjC exception.

**Verified:** debug + release build clean, zero errors. Idle 0.0% CPU across three 5s samples. Quit latency 0.07s. Temp sweep removes planted orphans and leaves unrelated files alone.

**Not yet verified** (needs a GUI session): the leak fixes themselves. Proof is Instruments → Allocations across ~10 consecutive recordings — allocations should return to baseline instead of retaining one recorder graph per recording. Same for denying mic permission and confirming the screen-recording indicator clears.

---

## Next

### Phase 3 — Main-thread stalls (the felt lag)
Highest remaining user-visible impact.

- **`DesktopIcons.swift:12`** — `isVisible()` is called from `menuNeedsUpdate`, so **every menu-bar click forks `defaults read` and blocks the main thread on `waitUntilExit()`**. Replace with `UserDefaults(suiteName: "com.apple.finder")` — no subprocess at all. Keep `Process` only for the write path and move it off-main. Also fix the latent pipe deadlock (reads the pipe *after* `waitUntilExit()`), and reap the `killall`.
- **`HistoryStore.swift:88`** — full-resolution PNG encode + disk write synchronously on main on every capture. On a 6K display that is ~100 MB of intermediate TIFF and a several-hundred-ms stall exactly when the popup should appear. Move off-main; publish on main. Same for `ImageSaver.saveToDesktop` and `Annotation.swift:1054`.
- **`HistoryStore.save()`** — re-encodes and rewrites all 100 entries on every mutation, synchronously on main. Debounce and move off-main.
- **`RecordingCompletePopup.swift:43`** — synchronous `AVAssetImageGenerator.copyCGImage` with `.zero` tolerances blocks `@MainActor` before the popup appears. Use the async API with a placeholder.
- **`ClickHighlightWindow.swift:109`** — 60 Hz `needsDisplay = true` on a *fullscreen* view during recording, competing with the encoder. Restrict to the union of active ripple bounds. (Self-terminating; a recording-time cost, not an idle one.)

### Phase 4 — Correctness & crash hardening
- **`ScreenRecorder.swift:47-51,271-278`** — `sessionStarted`'s check-then-act spans two separate `stateQueue.sync` calls, so it is not atomic across the sample and audio queues. Writer references are plain `var`s written on the main actor and read concurrently; `@unchecked Sendable` silences the compiler without providing synchronization. A fast stop/start can call `startSession` twice or append after `finishWriting` → `NSInternalInconsistencyException`. Collapse into a single locked check-and-set, and replace the per-buffer `stateQueue.sync` on the hot path (every video frame and audio buffer) with an unfair lock.
- **Force unwraps** — `HistoryStore.swift:68` (in the singleton's `init`, crashes before any UI exists), `ImageSaver.swift:13`, `MainWindow.swift:338`, `RecordingCompletePopup.swift:197`.
- **`HistoryStore` is not `@MainActor`** — `entries` is `@Published` and drives SwiftUI but is written from multiple contexts with no isolation. Publishing off-main is undefined behaviour.
- **Silent failures** — `ImageSaver.swift:18` returns the URL unconditionally after `try?`, so callers show success even when nothing was written. `MainWindow.swift:346` has an empty `catch`. `HistoryStore.swift:76-81` silently discards a corrupt index, and the next write **permanently orphans every prior capture file**.
- **`ScreenCapture.swift:7-28`** — the `screen` parameter is accepted but never used; the coordinate flip is computed against `NSScreen.screens.first`, so multi-display setups capture the wrong region.
- **`RecordingController.swift:379`** — `showStopPill()` re-assigns `startDate`, making the earlier assignment dead and shortening recorded duration by the stream startup latency (200-600 ms).

### Phase 5 — Tests & CI
No test target and no CI exist today (`.github/` holds only `FUNDING.yml`).

- `ShotX` is an `.executableTarget`, which tests cannot cleanly import. Extract the pure logic into a `ShotXCore` library the executable depends on, then add a `.testTarget`.
- Cover the deterministic non-UI logic: `ScreenCapture` coordinate flip across simulated multi-display geometries, `HistoryStore` pruning and corrupt-index recovery, `ShortcutFormatter` keycode mapping, `GIFConverter` zero-frame guard, `CaptureEntry` Codable round-trip.
- Add `.github/workflows/ci.yml` — `macos-14`, `swift build -c release` + `swift test`, cache `.build`.

---

## Out of scope

Deliberately excluded from this effort: new user-facing features, migrating off deprecated `CGWindowListCreateImage` (`ScreenCapture.swift:19`, `WindowCapture.swift:56`), and bounding `PinnedImageController`'s unbounded panel array.
