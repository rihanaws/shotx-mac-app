import Foundation

enum DesktopIcons {
    /// Reads Finder's `CreateDesktop` preference directly. This is called from
    /// `menuNeedsUpdate`, so it must not fork a subprocess — `defaults read`
    /// plus `waitUntilExit()` blocked the main thread on every menu-bar click.
    static func isVisible() -> Bool {
        guard let finder = UserDefaults(suiteName: "com.apple.finder"),
              let value = finder.object(forKey: "CreateDesktop")
        else {
            // Default (unset) is visible.
            return true
        }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            let lowered = s.lowercased()
            return lowered == "1" || lowered == "true" || lowered == "yes"
        }
        return true
    }

    /// Writes the preference and restarts Finder. Both are subprocess forks, so
    /// the whole thing runs off the main thread; the menu item's checkmark is
    /// recomputed the next time the menu opens.
    static func setVisible(_ visible: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            writer.arguments = [
                "write", "com.apple.finder", "CreateDesktop",
                "-bool", visible ? "true" : "false"
            ]
            do {
                try writer.run()
                writer.waitUntilExit()
            } catch {
                return
            }
            guard writer.terminationStatus == 0 else { return }

            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            kill.arguments = ["Finder"]
            // Reap it — an unwaited Process leaves a zombie child behind.
            try? kill.run()
            kill.waitUntilExit()
        }
    }

    static func toggle() {
        setVisible(!isVisible())
    }
}
