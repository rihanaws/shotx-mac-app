import Cocoa
import Combine

/// Persists the shutter-sound toggle. Mirrors `ShortcutStore`'s
/// `ObservableObject + @Published didSet -> UserDefaults` pattern so the
/// Settings toggle and `SoundEffect` stay in sync without extra wiring.
///
/// Default is `true` (sound on) to preserve current behavior for existing users.
@MainActor
final class SoundStore: ObservableObject {
    static let shared = SoundStore()

    @Published var isShutterEnabled: Bool {
        didSet { Self.persist(isShutterEnabled) }
    }

    private let key = "com.shotx.shutterSoundEnabled"

    init() {
        // `bool(forKey:)` returns false when absent — we need to distinguish
        // "never set" (default ON) from "explicitly off".
        if UserDefaults.standard.object(forKey: key) == nil {
            isShutterEnabled = true
        } else {
            isShutterEnabled = UserDefaults.standard.bool(forKey: key)
        }
    }

    private static func persist(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "com.shotx.shutterSoundEnabled")
    }
}
