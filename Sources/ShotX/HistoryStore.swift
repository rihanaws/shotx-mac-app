import Cocoa
import Combine
import AVFoundation
import ImageIO
import os.log

struct CaptureEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case image, video, gif
    }

    let id: UUID
    let filename: String
    let createdAt: Date
    let width: CGFloat
    let height: CGFloat
    let kind: Kind
    let duration: TimeInterval?

    init(
        id: UUID = UUID(),
        filename: String,
        createdAt: Date,
        width: CGFloat,
        height: CGFloat,
        kind: Kind = .image,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
        self.width = width
        self.height = height
        self.kind = kind
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let rawFilename = try c.decode(String.self, forKey: .filename)
        // Strict whitelist: UUID + known extension, no path separators.
        // Any traversal attempt (../, /, \) fails decode → whole file quarantined.
        guard rawFilename == (rawFilename as NSString).lastPathComponent,
              !rawFilename.contains("/"), !rawFilename.contains("\\"), !rawFilename.contains(".."),
              rawFilename.range(of: #"^[0-9A-Fa-f\-]+\.(png|mp4|gif)$"#, options: .regularExpression) != nil
        else {
            throw DecodingError.dataCorruptedError(forKey: .filename, in: c, debugDescription: "invalid filename")
        }
        filename = rawFilename
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        let rawW = try c.decode(CGFloat.self, forKey: .width)
        let rawH = try c.decode(CGFloat.self, forKey: .height)
        // Clamp dimensions to sane range; NaN/inf/negative/huge are rejected.
        guard rawW.isFinite, rawH.isFinite, rawW > 0, rawH > 0, rawW <= 16384, rawH <= 16384 else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "invalid dimensions")
        }
        width = rawW
        height = rawH
        // Backwards compat: older entries lack `kind` and `duration`.
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .image
        let rawDuration: TimeInterval? = try? c.decode(TimeInterval.self, forKey: .duration)
        if let d = rawDuration {
            guard d.isFinite, d >= 0, d <= 36000 else {
                throw DecodingError.dataCorruptedError(forKey: .duration, in: c, debugDescription: "invalid duration")
            }
            duration = d
        } else {
            duration = nil
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [CaptureEntry] = []

    private let maxEntries = 100
    private let historyDir: URL
    private let indexURL: URL

    /// Serial queue for index encoding + disk writes. `save()` used to re-encode
    /// all 100 entries synchronously on main on every mutation.
    private let ioQueue = DispatchQueue(label: "com.shotx.history.io", qos: .utility)
    /// Coalesces bursts of mutations into a single index write.
    private var pendingSave: DispatchWorkItem?
    private static let saveDebounce: TimeInterval = 0.4

    /// In-memory cache of downsampled thumbnails, keyed by entry ID. Auto-evicts
    /// on memory pressure via NSCache's built-in behaviour.
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        c.totalCostLimit = 50 * 1024 * 1024 // ~50 MB — bounds memory even with many thumbs
        return c
    }()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let root = appSupport.appendingPathComponent("ShotX", isDirectory: true)
        historyDir = root.appendingPathComponent("History", isDirectory: true)
        indexURL = root.appendingPathComponent("history.json")
        ensureHistoryDirIsSafe()
        load()
    }

    /// Ensures historyDir is a real directory, not a symlink to an attacker-chosen location.
    private func ensureHistoryDirIsSafe() {
        let fm = FileManager.default
        // If the dir (or its parent ShotX) is a symlink, remove the link and recreate.
        for url in [historyDir.deletingLastPathComponent(), historyDir] {
            if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
               vals.isSymbolicLink == true {
                os_log("ShotX: removing symlinked directory at %{public}@", log: .default, type: .fault, url.path)
                try? fm.removeItem(at: url)
            }
        }
        try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        // Re-check after creation — if it is still a symlink, creation followed the link.
        if let vals = try? historyDir.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            os_log("ShotX: historyDir still symlinked after create — removing", log: .default, type: .fault)
            try? fm.removeItem(at: historyDir)
            try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        }
    }

    /// A missing index (first launch) is expected and leaves `entries` at its
    /// empty default. A *present but undecodable* index is different — every
    /// capture file referenced by it is still sitting in `historyDir`, and if
    /// we silently start from `[]`, the next `save()` overwrites `history.json`
    /// with only the newly-added entries, permanently orphaning every prior
    /// capture. So a corrupt index is renamed aside instead of being read
    /// through — it never gets the chance to be overwritten, and a future
    /// version could offer to recover files from `historyDir` against it.
    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        guard let decoded = try? JSONDecoder().decode([CaptureEntry].self, from: data) else {
            let backupURL = indexURL.deletingLastPathComponent()
                .appendingPathComponent("history.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: backupURL)
            pruneCorruptBackups()
            os_log("ShotX: history.json corrupt — quarantined to %{public}@", log: .default, type: .fault, backupURL.lastPathComponent)
            return
        }
        // Post-decode hardening: count cap + silent drop of any entry that somehow
        // still violates invariants (defense in depth if JSON was hand-edited).
        var filtered = decoded
        if filtered.count > maxEntries * 2 {
            os_log("ShotX: history.json has %d entries (cap %d) — truncating", log: .default, type: .fault, filtered.count, maxEntries)
            filtered = Array(filtered.prefix(maxEntries * 2))
        }
        // Filter by finite dimensions / duration and jailed filename (again)
        filtered = filtered.filter { e in
            e.width.isFinite && e.height.isFinite && e.width > 0 && e.height > 0 && e.width <= 16384 && e.height <= 16384
                && e.filename == (e.filename as NSString).lastPathComponent
                && !e.filename.contains("/") && !e.filename.contains("\\")
        }
        if filtered.count != decoded.count {
            os_log("ShotX: dropped %d invalid history entries", log: .default, type: .fault, decoded.count - filtered.count)
        }
        // Enforce maxEntries on load as well
        if filtered.count > maxEntries {
            filtered = Array(filtered.prefix(maxEntries))
        }
        entries = filtered
        // Keep only last 3 corrupt backups
    }

    private func pruneCorruptBackups() {
        let dir = indexURL.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let corrupt = contents.filter { $0.lastPathComponent.hasPrefix("history.corrupt-") }
            .sorted { ($0.path) < ($1.path) }
        if corrupt.count > 3 {
            for old in corrupt.prefix(corrupt.count - 3) {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }

    /// Debounced, off-main index write. The snapshot is taken on the calling
    /// (main) thread so `entries` is never read across threads; encoding and
    /// the disk write happen on `ioQueue`.
    private func save() {
        pendingSave?.cancel()
        let snapshot = entries
        let url = indexURL
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        pendingSave = work
        ioQueue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Writes the index immediately, blocking until it lands. Used at
    /// termination so a debounced write in flight isn't lost.
    func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = entries
        let url = indexURL
        ioQueue.sync {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Registers the capture and returns its entry immediately; the PNG encode
    /// and disk write happen off-main. Callers get a valid `fileURL(for:)`
    /// right away (the filename is a UUID known up front), but the file appears
    /// on disk a moment later.
    ///
    /// A full-resolution encode is ~100 MB of intermediate TIFF on a 6K display
    /// and used to stall main for several hundred ms exactly when the
    /// post-capture popup should appear.
    @discardableResult
    func add(_ image: NSImage) -> CaptureEntry? {
        let entry = CaptureEntry(
            filename: "\(UUID().uuidString).png",
            createdAt: Date(),
            width: image.size.width,
            height: image.size.height,
            kind: .image
        )
        let url = historyDir.appendingPathComponent(entry.filename)
        register(entry)

        ioQueue.async {
            guard let png = ImageSaver.pngData(from: image),
                  (try? png.write(to: url)) != nil
            else {
                // Encode or write failed — drop the entry so the grid doesn't
                // show a permanently broken tile.
                DispatchQueue.main.async { self.remove(entry) }
                return
            }
        }
        return entry
    }

    @discardableResult
    func add(videoAt sourceURL: URL, duration: TimeInterval, dimensions: CGSize) -> CaptureEntry? {
        let entry = CaptureEntry(
            filename: "\(UUID().uuidString).mp4",
            createdAt: Date(),
            width: dimensions.width,
            height: dimensions.height,
            kind: .video,
            duration: duration
        )
        return moveIntoHistory(sourceURL: sourceURL, entry: entry)
    }

    @discardableResult
    func add(gifAt sourceURL: URL, duration: TimeInterval, dimensions: CGSize) -> CaptureEntry? {
        let entry = CaptureEntry(
            filename: "\(UUID().uuidString).gif",
            createdAt: Date(),
            width: dimensions.width,
            height: dimensions.height,
            kind: .gif,
            duration: duration
        )
        return moveIntoHistory(sourceURL: sourceURL, entry: entry)
    }

    private func moveIntoHistory(sourceURL: URL, entry: CaptureEntry) -> CaptureEntry? {
        let dest = fileURL(for: entry)
        // Validate source is a regular file, not symlink/dir
        if let vals = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           vals.isSymbolicLink == true || vals.isRegularFile == false {
            os_log("ShotX: refusing non-regular source %{public}@", log: .default, type: .fault, sourceURL.path)
            return nil
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: sourceURL, to: dest)
        } catch {
            // Fall back to copy if move fails (different volumes)
            do { try FileManager.default.copyItem(at: sourceURL, to: dest) }
            catch { return nil }
        }
        register(entry)
        return entry
    }

    private func register(_ entry: CaptureEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            for old in entries.suffix(from: maxEntries) {
                let url = fileURL(for: old)
                // Only delete regular files inside historyDir
                if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                   vals.isRegularFile == true, vals.isSymbolicLink != true {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func fileURL(for entry: CaptureEntry) -> URL {
        // Jail to historyDir: strip any path components even if decode was bypassed.
        let safeName = (entry.filename as NSString).lastPathComponent
        let url = historyDir.appendingPathComponent(safeName).standardized
        // Prefix check — if jail escapes, return a harmless sentinel inside historyDir.
        let resolvedHistory = historyDir.resolvingSymlinksInPath().standardized.path
        let resolvedURL = url.resolvingSymlinksInPath().standardized.path
        if !resolvedURL.hasPrefix(resolvedHistory + "/") && resolvedURL != resolvedHistory {
            os_log("ShotX: blocked traversal for filename %{public}@", log: .default, type: .fault, entry.filename)
            return historyDir.appendingPathComponent(UUID().uuidString + ".blocked")
        }
        return url
    }

    func image(for entry: CaptureEntry) -> NSImage? {
        let url = fileURL(for: entry)
        // Guard against decompression bomb even for history-owned files
        if entry.kind == .image || entry.kind == .gif {
            if let vals = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = vals.fileSize, size > 100 * 1024 * 1024 {
                return nil
            }
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int, w * h > 50_000_000 {
                return nil
            }
        }
        switch entry.kind {
        case .image, .gif:
            return NSImage(contentsOf: url)
        case .video:
            return VideoThumbnail.firstFrame(of: url)
        }
    }

    /// Returns a small, decoded, cached thumbnail suitable for the history grid.
    /// Decodes on a background queue; first call per entry hits disk, subsequent
    /// calls return from the in-memory cache. `@MainActor` so NSImage? doesn't
    /// have to cross an actor boundary when returned to the SwiftUI caller.
    @MainActor
    func thumbnail(for entry: CaptureEntry, maxDim: CGFloat = 300) async -> NSImage? {
        let key = entry.id.uuidString as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        let url = fileURL(for: entry)
        let kind = entry.kind

        let image: NSImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let img: NSImage?
                switch kind {
                case .image, .gif:
                    img = HistoryStore.downsampledImage(at: url, maxDim: maxDim)
                case .video:
                    img = HistoryStore.downsampledVideoFrame(at: url, maxDim: maxDim)
                }
                continuation.resume(returning: img)
            }
        }

        if let image = image {
            thumbnailCache.setObject(image, forKey: key)
        }
        return image
    }

    /// Explicitly `nonisolated` so it keeps running on the background queue
    /// it's dispatched to in `thumbnail(for:maxDim:)` above rather than
    /// hopping to main just because the enclosing type is `@MainActor`.
    private static nonisolated func downsampledImage(at url: URL, maxDim: CGFloat) -> NSImage? {
        // Pre-check file size / dimensions to avoid decoding a bomb
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = vals.fileSize, size > 100 * 1024 * 1024 {
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, w * h > 50_000_000 {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim * 2, // 2x for Retina
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let pointSize = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        return NSImage(cgImage: cg, size: pointSize)
    }

    private static nonisolated func downsampledVideoFrame(at url: URL, maxDim: CGFloat) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDim * 2, height: maxDim * 2)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        let pointSize = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        return NSImage(cgImage: cg, size: pointSize)
    }

    func remove(_ entry: CaptureEntry) {
        let url = fileURL(for: entry)
        if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           vals.isRegularFile == true, vals.isSymbolicLink != true {
            try? FileManager.default.removeItem(at: url)
        }
        thumbnailCache.removeObject(forKey: entry.id.uuidString as NSString)
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        for e in entries {
            let url = fileURL(for: e)
            if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               vals.isRegularFile == true, vals.isSymbolicLink != true {
                try? FileManager.default.removeItem(at: url)
            }
        }
        thumbnailCache.removeAllObjects()
        entries.removeAll()
        save()
    }
}
