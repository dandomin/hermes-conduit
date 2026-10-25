//
//  TranscriptPictureMemory.swift
//  Conduit
//
//  What a chat picture needs on its first frame when its row scrolls back
//  into view (#1238): the decoded picture while it is still in memory, else
//  at least its size, so the row takes its final height at once. A row that
//  mounted as a "Loading image…" line and grew a few frames later moved
//  everything under it while the user scrolled up through a long chat.
//
//  Sizes are kept on the phone next to the pictures, read once off the main
//  thread, so a body only ever looks one up in memory.
//

import UIKit

@MainActor
enum TranscriptPictureMemory {
    /// Past this many sizes the memo starts again; a size is a few bytes.
    static let sizeLimit = 4000

    /// Decoded pictures from Hermes' `MEDIA:` paths, by their
    /// `TranscriptImageCache` key. Bounded by decoded size; NSCache evicts
    /// under memory pressure, and the files on disk stay.
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Shown sizes by key: a kept picture's cache key, or a photo's path.
    private static var sizes: [String: CGSize] = [:]
    private static var loadedKeptSizes = false
    private static var pendingSave: Task<Void, Never>?
    /// Moves on with every `forgetAll`, so a read or save from before it
    /// brings nothing back.
    private static var generation = 0

    static var defaultSizesFile: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TranscriptImageSizes.plist")
    }

    static func image(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    static func remember(_ image: UIImage, for key: String) {
        images.setObject(image, forKey: key as NSString, cost: bitmapCost(of: image))
        rememberSize(image.size, for: key)
    }

    static func size(for key: String) -> CGSize? {
        sizes[key]
    }

    static func rememberSize(_ size: CGSize, for key: String, savingTo file: URL? = defaultSizesFile) {
        guard size.width > 0, size.height > 0, sizes[key] != size else { return }
        if sizes.count >= sizeLimit, sizes[key] == nil { sizes.removeAll() }
        sizes[key] = size
        if let file { scheduleSave(to: file) }
    }

    /// Reads the sizes kept from earlier launches, once, off the main
    /// thread. Sizes remembered meanwhile win.
    static func loadKeptSizes(from file: URL = defaultSizesFile) async {
        guard !loadedKeptSizes else { return }
        loadedKeptSizes = true
        let started = generation
        let kept = await Task.detached(priority: .utility) { readSizes(from: file) }.value
        guard generation == started else { return }
        let room = max(0, sizeLimit - sizes.count)
        for (key, size) in kept.prefix(room) where sizes[key] == nil {
            sizes[key] = size
        }
    }

    /// Everything goes with the kept files (sign-out, Delete Saved Chats).
    static func forgetAll(sizesFile file: URL = defaultSizesFile) {
        generation += 1
        pendingSave?.cancel()
        pendingSave = nil
        images.removeAllObjects()
        sizes.removeAll()
        io.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Writes the sizes a second after the last new one, off the main
    /// thread.
    private static func scheduleSave(to file: URL) {
        pendingSave?.cancel()
        let started = generation
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, generation == started else { return }
            let snapshot = sizes
            io.async { writeSizes(snapshot, to: file) }
        }
    }

    /// Saves and removals of the sizes file, in the order they were asked
    /// for: a save already under way when the sizes are forgotten can't
    /// land after the removal.
    private nonisolated static let io = DispatchQueue(label: "TranscriptPictureMemory.io", qos: .utility)

    nonisolated static func writeSizes(_ sizes: [String: CGSize], to file: URL) {
        let plist = sizes.mapValues { [Double($0.width), Double($0.height)] }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated static func readSizes(from file: URL) -> [String: CGSize] {
        guard let data = try? Data(contentsOf: file),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [Double]]
        else { return [:] }
        return plist.compactMapValues { pair in
            guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return nil }
            return CGSize(width: pair[0], height: pair[1])
        }
    }

    private static func bitmapCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}
