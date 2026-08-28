import Cocoa

final class SoundEffect {
    static let shared = SoundEffect()

    private let shutter: NSSound?

    init() {
        shutter = SoundEffect.loadShutter()
    }

    func playShutter() {
        // Respect Settings → Sound toggle (default ON). Check on the main actor
        // without capturing self across isolation boundaries.
        let enabled = MainActor.assumeIsolated { SoundStore.shared.isShutterEnabled }
        guard enabled else { return }
        shutter?.stop()
        shutter?.play()
    }

    private static func loadShutter() -> NSSound? {
        let candidatePaths = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
            "/System/Library/Audio/UISounds/screen-capture.caf"
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path),
               let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
        }
        // Fall back to a built-in system sound that ships with all macOS versions.
        return NSSound(named: "Tink")
    }
}
