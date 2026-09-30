import AppKit
import CoreGraphics

// Renders a fake admin-panel screenshot, runs the real pipeline over it and
// reports what was caught, what leaked and what fired on innocent text.
// Run: ./Tools/selftest.sh

struct Line {
    let text: String
    /// Substring that must end up inside a redaction box. nil = must stay untouched.
    let secret: String?
}

let lines: [Line] = [
    Line(text: "Computer Inventory — MacBook Pro 16\"", secret: nil),
    Line(text: "Serial Number: C02XK1YZQ6L4", secret: "C02XK1YZQ6L4"),
    Line(text: "Assigned User: anna.kowalska@example.com", secret: "anna.kowalska@example.com"),
    Line(text: "Manager: piotr.nowak@example.com", secret: "piotr.nowak@example.com"),
    Line(text: "Last IP: 34.118.90.12", secret: "34.118.90.12"),
    Line(text: "Wi-Fi MAC: 3C:22:FB:9A:11:0E", secret: "3C:22:FB:9A:11:0E"),
    Line(text: "API token: ghp_aB3dEfGh1JkLmN0pQrStUvWxYz012345", secret: "ghp_aB3dEfGh1JkLmN0pQrStUvWxYz012345"),
    Line(text: "OPENAI_KEY=sk-proj-9xKQm2Lp0ZvT4rN8wYb1Ac", secret: "sk-proj-9xKQm2Lp0ZvT4rN8wYb1Ac"),
    Line(text: "aws key AKIAIOSFODNN7EXAMPLE rotated", secret: "AKIAIOSFODNN7EXAMPLE"),
    Line(text: "password: Tr0ub4dor&3xK", secret: "Tr0ub4dor&3xK"),
    Line(text: "Card 4111 1111 1111 1111 on file", secret: "4111 1111 1111 1111"),
    Line(text: "OS Version 15.4.1 build 24E263", secret: nil),
    Line(text: "Local gateway 192.168.1.1 reachable", secret: nil),
    Line(text: "Policy DEPLOYMENT succeeded 12 times", secret: nil),
]

// MARK: - Render a screenshot-like PNG

func renderImage() -> CGImage {
    let width = 900, height = 40 + lines.count * 34
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
        .foregroundColor: NSColor.black,
    ]
    for (i, line) in lines.enumerated() {
        let y = CGFloat(height - 34 - i * 34)
        line.text.draw(at: NSPoint(x: 24, y: y), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

// MARK: - Run

let image = renderImage()
let enabled = Set(Detectors.all.filter(\.defaultEnabled).map(\.id))

let detections: [Detection]
do {
    detections = try Scanner.scan(image: image, enabled: enabled)
} catch {
    print("OCR failed: \(error)")
    exit(1)
}

print("── Detections (\(detections.count)) ─────────────────────────")
for d in detections.sorted(by: { $0.rect.maxY > $1.rect.maxY }) {
    print(String(format: "  %-22s %@", (d.label as NSString).utf8String!, d.text))
}

// Did every expected secret get covered, and did anything innocent get hit?
var missed: [String] = []
var falsePositives: [String] = []
let caught = detections.map(\.text)

for line in lines {
    if let secret = line.secret {
        let normalized = secret.replacingOccurrences(of: " ", with: "")
        let hit = caught.contains { c in
            let cn = c.replacingOccurrences(of: " ", with: "")
            return cn.contains(normalized) || normalized.contains(cn) && cn.count > 4
        }
        if !hit { missed.append(secret) }
    }
}
for d in detections {
    let belongsToSecretLine = lines.contains { line in
        guard let secret = line.secret else { return false }
        let a = d.text.replacingOccurrences(of: " ", with: "")
        let b = secret.replacingOccurrences(of: " ", with: "")
        return a.contains(b) || b.contains(a)
    }
    if !belongsToSecretLine { falsePositives.append("\(d.label): \(d.text)") }
}

print("\n── Missed (\(missed.count)) ─────────────────────────────────")
missed.forEach { print("  ✗ \($0)") }
print("\n── False positives (\(falsePositives.count)) ────────────────")
falsePositives.forEach { print("  ! \($0)") }

// Redact, then re-OCR the output: nothing should still read as a secret.
let redacted = Redactor.apply(to: image, detections: detections, style: .solid)
let leftovers = Redactor.verify(redacted, enabled: enabled)
print("\n── After redaction ─────────────────────────────────")
print("  leftovers still readable: \(leftovers.count)")
leftovers.forEach { print("  ‼ \($0.label): \($0.text)") }

let out = URL(fileURLWithPath: "build/selftest-redacted.png")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
if let data = Redactor.pngData(redacted) {
    try? data.write(to: out)
    print("\n  wrote \(out.path)")
}
if let data = Redactor.pngData(image) {
    try? data.write(to: URL(fileURLWithPath: "build/selftest-original.png"))
}

exit(missed.isEmpty && leftovers.isEmpty ? 0 : 1)
