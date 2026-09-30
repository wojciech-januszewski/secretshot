import AppKit
import Vision
import CoreGraphics

// Reproduces a Jamf-style dark two-column inventory table and dumps what Vision
// actually returns, so detection can be fixed against real OCR output instead of
// against what the layout looks like to a human.
// Run: ./Tools/jamftest.sh

let rows: [(String, String)] = [
    ("Make:", "Apple"),
    ("Model:", "MacBook Air (M1, 2020)"),
    ("Model Identifier:", "MacBookAir10,1"),
    ("UDID:", "8EF78972-0585-5773-AABA-791043CCCBD5"),
    ("Serial Number:", "FVFH9012Q6L7"),
    ("Number of Processors:", "1"),
    ("Processor Type:", "Apple M1"),
    ("Architecture Type:", "arm64"),
    ("Primary MAC Address:", "B0:BE:83:17:35:BA"),
    ("Secondary MAC Address:", "A4:83:E7:2C:19:0F"),
    ("Assigned User:", "anna.kowalska@example.com"),
    ("Last IP Address:", "34.118.90.12"),
]

func render() -> CGImage {
    let width = 1330, rowHeight = 48, top = 60
    let height = top + rows.count * rowHeight + 20
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Jamf's dark theme, alternating row striping.
    NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.16, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for i in 0..<rows.count where i % 2 == 0 {
        NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.21, alpha: 1).setFill()
        NSRect(x: 0, y: CGFloat(height - top - (i + 1) * rowHeight),
               width: CGFloat(width), height: CGFloat(rowHeight)).fill()
    }

    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor(white: 0.78, alpha: 1),
    ]
    let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 15),
        .foregroundColor: NSColor.white,
    ]
    "Hardware".draw(at: NSPoint(x: 300, y: CGFloat(height - 40)),
                    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20),
                                     .foregroundColor: NSColor.white])
    for (i, row) in rows.enumerated() {
        let y = CGFloat(height - top - (i + 1) * rowHeight + 14)
        row.0.draw(at: NSPoint(x: 302, y: y), withAttributes: labelAttrs)
        row.1.draw(at: NSPoint(x: 586, y: y), withAttributes: valueAttrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

let image = render()
try? Redactor.pngData(image)?.write(to: URL(fileURLWithPath: "build/jamftest.png"))

// 1. Raw OCR: are label and value one observation or two?
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US", "pl-PL"]
try! VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

print("── Raw OCR observations ────────────────────────────")
for obs in (request.results ?? []) {
    guard let c = obs.topCandidates(1).first else { continue }
    let b = obs.boundingBox
    print(String(format: "  x=%.3f…%.3f y=%.3f  %@", b.minX, b.maxX, b.midY, c.string))
}

// 2. What the current rules catch.
let enabled = Set(Detectors.all.filter(\.defaultEnabled).map(\.id))
let detections = (try? Scanner.scan(image: image, enabled: enabled)) ?? []
print("\n── Detected with default rules (\(detections.count)) ──────────")
for d in detections { print("  \(d.label): \(d.text)") }

let expected = ["8EF78972-0585-5773-AABA-791043CCCBD5", "FVFH9012Q6L7",
                "B0:BE:83:17:35:BA", "A4:83:E7:2C:19:0F",
                "anna.kowalska@example.com", "34.118.90.12"]
// Compare through the same glyph-confusion map the detector uses: OCR may have
// read "B0:BE" as "BO:BE", and the box still covers the right pixels.
func canonical(_ s: String) -> String {
    let fixes: [Character: Character] = ["O": "0", "o": "0", "I": "1", "l": "1",
                                         "S": "5", "B": "8", "Z": "2", "G": "6"]
    return String(s.uppercased().compactMap { c -> Character? in
        if c == " " || c == "-" || c == ":" { return nil }
        return fixes[c] ?? c
    })
}

let redacted = Redactor.apply(to: image, detections: detections, style: .solid)
try? Redactor.pngData(redacted)?.write(to: URL(fileURLWithPath: "build/jamftest-redacted.png"))
let leftovers = Redactor.verify(redacted, enabled: enabled)
print("\n── After redaction: \(leftovers.count) still readable ──")

print("\n── Missed ──────────────────────────────────────────")
var missed = 0
for e in expected {
    let want = canonical(e)
    let hit = detections.contains { canonical($0.text).contains(want.prefix(8)) }
    if !hit { print("  ✗ \(e)"); missed += 1 }
}
if missed == 0 { print("  (none — all \(expected.count) covered)") }
exit(missed == 0 ? 0 : 1)
