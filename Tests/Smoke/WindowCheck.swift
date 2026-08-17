import AppKit
import CoreGraphics
import Foundation

// Does the application's window draw its *content*?
//
// This exists because of a defect nothing else caught. With a machine selected,
// the window drew its toolbar and nothing else: no sidebar rows, no header, no
// restore points. Every view body ran with correct data, the process sat at 0%
// CPU, and nothing was logged. Twenty-five integration tests and two review
// passes missed it, and so did two later attempts at a headless check —
// measuring the views in an NSHostingView gives identical numbers with and
// without the defect. That was verified, not assumed.
//
// What found it was launching the app and looking at the window, so that is
// what this does.
//
// The one thing it must get right is *where* it looks. A first version measured
// the whole window and passed a deliberately emptied build, because the title
// bar and toolbar alone account for a quarter of the pixels. The content area
// below them is the part that was blank, so that is the part measured.

struct WindowInfo {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
}

func windows(ownedBy owner: String) -> [WindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list.compactMap { entry in
        guard entry[kCGWindowOwnerName as String] as? String == owner,
              let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let raw = entry[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary)
        else { return nil }
        return WindowInfo(id: id, title: title, bounds: rect)
    }
}

/// Everything below the toolbar, which is the region a broken layout empties.
func contentArea(of image: CGImage, toolbarPoints: CGFloat = 56) -> CGImage? {
    // The capture is in pixels and the toolbar height is in points.
    let backingScale = NSScreen.main?.backingScaleFactor ?? 2
    let top = Int(toolbarPoints * backingScale)
    guard image.height > top + 40 else { return nil }
    return image.cropping(to: CGRect(
        x: 0, y: top, width: image.width, height: image.height - top
    ))
}

/// The share of pixels that differ from the single most common colour.
///
/// A pane that rendered nothing is one flat fill and scores near zero; rows,
/// text and controls score far higher.
func contentRatio(of image: CGImage) -> Double {
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return 0 }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Bucketed: anti-aliasing and the gradients a modern interface uses would
    // otherwise make even an empty pane look varied.
    var counts: [UInt32: Int] = [:]
    var total = 0
    for index in stride(from: 0, to: pixels.count, by: 16) {
        let r = UInt32(pixels[index] >> 3)
        let g = UInt32(pixels[index + 1] >> 3)
        let b = UInt32(pixels[index + 2] >> 3)
        counts[(r << 10) | (g << 5) | b, default: 0] += 1
        total += 1
    }
    guard total > 0, let dominant = counts.values.max() else { return 0 }
    return 1.0 - (Double(dominant) / Double(total))
}

func capture(_ window: WindowInfo) -> CGImage? {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("usm-smoke-\(window.id).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l\(window.id)", file.path]
    try? task.run()
    task.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: file) }

    // Read the bytes rather than handing CGImageSource the URL: decoding is
    // lazy, so deleting the file first yields a blank image and a test that
    // fails on a perfectly healthy window.
    guard task.terminationStatus == 0,
          let data = try? Data(contentsOf: file),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return image
}
