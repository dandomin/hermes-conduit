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

import ImageIO
import UIKit

@MainActor
enum TranscriptPictureMemory {
    /// Past this many sizes the memo starts again; a size is a few bytes,
    /// and a miss costs one header read.
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

    /// Shown sizes by key. A nil value records a probe that found no file,
    /// so a picture never loaded isn't looked for on every redraw.
    private static var sizes: [String: CGSize?] = [:]

    static func image(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    static func remember(_ image: UIImage, for key: String) {
        images.setObject(image, forKey: key as NSString, cost: bitmapCost(of: image))
        rememberSize(image.size, for: key)
    }

    static func rememberSize(_ size: CGSize, for key: String) {
        guard size.width > 0, size.height > 0 else { return }
        store(size, for: key)
    }

    /// The picture's size: remembered from this launch, else read from the
    /// header of the file `file` names (the picture kept on the phone, or
    /// the photo itself), once per key.
    static func size(for key: String, probing file: () -> URL?) -> CGSize? {
        if let entry = sizes[key] { return entry }
        let size = file().flatMap(pixelSize(of:))
        store(size, for: key)
        return size
    }

    /// Everything goes with the kept files (sign-out, Delete Saved Chats).
    static func forgetAll() {
        images.removeAllObjects()
        sizes.removeAll()
    }

    /// Width and height as the picture is shown, upright: ImageIO's
    /// thumbnails apply the EXIF orientation, so a quarter turn swaps them.
    /// Reads the header only, nothing is decoded.
    nonisolated static func pixelSize(of file: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // 5 to 8 are the transposed orientations.
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private static func store(_ size: CGSize?, for key: String) {
        if sizes.count >= sizeLimit, sizes.index(forKey: key) == nil { sizes.removeAll() }
        sizes[key] = .some(size)
    }

    private static func bitmapCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}
