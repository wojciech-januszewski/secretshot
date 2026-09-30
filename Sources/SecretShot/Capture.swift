import AppKit
import CoreGraphics

enum CaptureMode {
    case region
    case window

    var arguments: [String] {
        switch self {
        case .region: return ["-i", "-o", "-x"]
        case .window: return ["-i", "-w", "-o", "-x"]
        }
    }
}

enum Capture {

    /// Has the user granted Screen Recording? Checked *before* spawning
    /// `screencapture`, because spawning it blind makes TCC re-prompt on every
    /// single capture instead of once.
    static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt exactly once. Returns immediately; the grant
    /// only takes effect after the app is relaunched, which is a macOS rule we
    /// can't work around.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }


    /// Shells out to the system `screencapture` so we inherit Apple's own
    /// selection UI (and its crosshair, magnifier and space switching) instead
    /// of reimplementing it badly. Result lands in a temp file we delete immediately.
    static func interactive(mode: CaptureMode, completion: @escaping (CGImage?) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("secretshot-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = mode.arguments + [url.path]

        process.terminationHandler = { proc in
            defer { try? FileManager.default.removeItem(at: url) }

            // Non-zero status or a missing file means the user pressed Esc.
            guard proc.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: url.path),
                  let image = loadImage(at: url) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(image) }
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: url)
            completion(nil)
        }
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        if debugCapture, let image {
            // Opt-in only: keeping a copy of every capture would defeat the point
            // of the app. Enabled with `open … --args --debug-capture`.
            try? Redactor.pngData(image)?
                .write(to: URL(fileURLWithPath: "/tmp/secretshot-last-capture.png"))
            let report = "size=\(image.width)x\(image.height) uniform=\(isUniform(image))"
            try? report.write(toFile: "/tmp/secretshot-last-capture.txt",
                              atomically: true, encoding: .utf8)
        }
        return image
    }

    static var debugCapture: Bool {
        CommandLine.arguments.contains("--debug-capture")
    }

    /// True when every sampled pixel is identical — i.e. the capture came back
    /// blank. macOS hands back an empty frame instead of an error when Screen
    /// Recording is approved but not yet active for the running process.
    ///
    /// Sampled at 128² with averaging turned on: downscaling further lets
    /// CoreGraphics subsample, and on a dark UI with sparse text every sample can
    /// land on identical background and fake a blank frame.
    static func isUniform(_ image: CGImage) -> Bool {
        let side = 128
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt32.self, capacity: side * side)
        let first = pixels[0]
        for i in 1..<(side * side) where pixels[i] != first { return false }
        return true
    }

    static func imageFromPasteboard() -> CGImage? {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func copyToPasteboard(_ image: CGImage) {
        guard let data = Redactor.pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }
}

/// Watches the clipboard so the muscle-memory shortcut (⌃⌘⇧4) still gets scanned.
/// Polling `changeCount` is the only supported way — there is no pasteboard notification.
final class PasteboardWatcher {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// Set when *we* write to the pasteboard, so our own output doesn't retrigger a scan.
    private var ignoreNextChange = false

    var onImage: ((CGImage) -> Void)?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func suppressNextChange() {
        ignoreNextChange = true
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if ignoreNextChange {
            ignoreNextChange = false
            return
        }
        guard let image = Capture.imageFromPasteboard() else { return }
        onImage?(image)
    }
}
