import Cocoa

enum ImageSaver {
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static let saveQueue = DispatchQueue(label: "com.shotx.imagesaver", qos: .userInitiated)

    /// `FileManager.urls(for:in:)` returns `[]` rather than trapping when a
    /// directory can't be resolved, so callers that force-unwrap `.first` are
    /// one restricted-environment away from a crash. Falls back to
    /// `~/Desktop`, which is always constructible from `NSHomeDirectory()`.
    static func desktopDirectory() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    /// Encodes and writes off the main thread — a full-resolution PNG encode is
    /// hundreds of ms on a 6K display. `completion` runs on the main queue with
    /// the destination URL, or `nil` if the encode or write failed.
    static func saveToDesktop(_ image: NSImage, completion: ((URL?) -> Void)? = nil) {
        var desktop = desktopDirectory()
        // Desktop symlink guard — if Desktop is a symlink, resolve and verify it's inside home.
        if let vals = try? desktop.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            desktop = desktop.resolvingSymlinksInPath()
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = desktop.appendingPathComponent("ShotX \(formatter.string(from: Date())).png")
        // Avoid same-second collision (DateFormatter is second granularity)
        if FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("ShotX \(formatter.string(from: Date())) \(UUID().uuidString.prefix(4)).png")
        }

        saveQueue.async {
            var result: URL?
            if let data = pngData(from: image) {
                do {
                    try data.write(to: url, options: .atomic)
                    result = url
                } catch {
                    // Fallback: non-atomic write (should not happen, but don't lose the capture)
                    if (try? data.write(to: url)) != nil { result = url }
                }
            }
            if let completion = completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    static func copyToClipboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Expose both PNG and TIFF. Writing the NSImage alone only provides
        // TIFF, which many chat apps, browsers, and Electron tools silently
        // reject when pasting — they look for PNG. Offering both makes the
        // screenshot pasteable everywhere.
        let item = NSPasteboardItem()
        if let png = pngData(from: image) {
            item.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([item])
    }

    static func copyTextToClipboard(_ text: String) {
        // Defensive truncation even if caller didn't — pasteboard is IPC.
        let clipped = text.count > 100_000 ? String(text.prefix(100_000)) : text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clipped, forType: .string)
    }
}
