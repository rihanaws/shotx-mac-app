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

### Phase 3 — Main-thread stalls (the felt lag) ✅

| Fix | File | Was |
|---|---|---|
| No subprocess on the read path | `DesktopIcons.swift` | `isVisible()` runs from `menuNeedsUpdate`, so every menu-bar click forked `defaults read` and blocked main on `waitUntilExit()`. Now reads `UserDefaults(suiteName: "com.apple.finder")` directly. The latent pipe deadlock (read *after* `waitUntilExit()`) is gone with the pipe. |
| Write path off-main + reaped | `DesktopIcons.swift` | `setVisible` forked twice on main and never waited on `killall`, leaving a zombie. Now runs on a background queue and waits on both; the write is skipped if `defaults` exits non-zero. |
| Async PNG encode | `HistoryStore.add(_:)` | Full-resolution encode + write ran synchronously on main on every capture (~100 MB of intermediate TIFF on a 6K display). The entry is now returned immediately — the filename is a UUID known up front — and the encode happens on `ioQueue`. A failed encode removes the entry rather than leaving a broken tile. |
| Debounced index write | `HistoryStore.save()` | Re-encoded and rewrote all 100 entries on main on every mutation. Now snapshots on main, coalesces at 400 ms, and encodes/writes on `ioQueue`. `flushPendingSave()` forces it out from `applicationShouldTerminate`. |
| Async desktop save | `ImageSaver.saveToDesktop` | Encoded and wrote on main. Now off-main with a main-queue completion carrying the URL — which also makes the failure observable instead of the old unconditional-return-after-`try?`. `Annotation`'s save surfaces a toast on failure. |
| Async popup thumbnail | `RecordingCompletePopup.swift` | `copyCGImage` with `.zero` tolerances decodes from the preceding keyframe and blocked `@MainActor` right before the popup appeared. The popup now shows immediately and the frame fades in via `RecordingThumbnailState`; the task is cancelled on dismiss. |
| Bounded invalidation | `ClickHighlightWindow.swift` | 60 Hz `needsDisplay = true` on a *fullscreen* view during recording, competing with the encoder. Now `setNeedsDisplay(_:)` over the union of active ripple bounds, and `draw` skips ripples outside `dirtyRect`. |

**Verified:** clean release build from scratch, zero errors, no new warnings (the two remaining are pre-existing — `ScreenRecorder.swift:308`, `WebcamWindow.swift`). The `UserDefaults` read was checked against the old `defaults read` semantics across unset / `false` / `true`.

**Not yet verified** (needs a GUI session): that the menu opens without a hitch, the post-capture popup appears immediately, and the recording popup's thumbnail fades in rather than delaying the panel.

---

## Next

### Phase 4 — Correctness & crash hardening
- **`ScreenRecorder.swift:47-51,271-278`** — `sessionStarted`'s check-then-act spans two separate `stateQueue.sync` calls, so it is not atomic across the sample and audio queues. Writer references are plain `var`s written on the main actor and read concurrently; `@unchecked Sendable` silences the compiler without providing synchronization. A fast stop/start can call `startSession` twice or append after `finishWriting` → `NSInternalInconsistencyException`. Collapse into a single locked check-and-set, and replace the per-buffer `stateQueue.sync` on the hot path (every video frame and audio buffer) with an unfair lock.
- **Force unwraps** — `HistoryStore.swift:68` (in the singleton's `init`, crashes before any UI exists), `ImageSaver.swift:13`, `MainWindow.swift:338`, `RecordingCompletePopup.swift:197`.
- **`HistoryStore` is not `@MainActor`** — `entries` is `@Published` and drives SwiftUI but is written from multiple contexts with no isolation. Publishing off-main is undefined behaviour.
- **Silent failures** — `ImageSaver.saveToDesktop` is now fixed (Phase 3: the completion reports `nil` on failure), but only `Annotation` acts on it; `PostCapturePopup`, `PinnedImage`, and `MainWindow` still ignore the result. `MainWindow.swift:346` has an empty `catch`. `HistoryStore.swift:76-81` silently discards a corrupt index, and the next write **permanently orphans every prior capture file**.
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
