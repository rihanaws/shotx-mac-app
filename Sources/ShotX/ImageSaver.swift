import Cocoa

enum ImageSaver {
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static let saveQueue = DispatchQueue(label: "com.shotx.imagesaver", qos: .userInitiated)

    /// Encodes and writes off the main thread — a full-resolution PNG encode is
    /// hundreds of ms on a 6K display. `completion` runs on the main queue with
    /// the destination URL, or `nil` if the encode or write failed.
    static func saveToDesktop(_ image: NSImage, completion: ((URL?) -> Void)? = nil) {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = desktop.appendingPathComponent("ShotX \(formatter.string(from: Date())).png")

        saveQueue.async {
            var result: URL?
            if let data = pngData(from: image), (try? data.write(to: url)) != nil {
                result = url
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
