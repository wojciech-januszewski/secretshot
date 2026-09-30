import AppKit
import CoreGraphics

// Validator unit tests plus an end-to-end OCR pass over the new rule types.
// Run: ./Tools/rulestest.sh

var failures = 0
func check(_ label: String, _ got: Bool, _ want: Bool) {
    if got == want {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label) — got \(got), want \(want)")
        failures += 1
    }
}

print("── PESEL checksum + date ───────────────────────────")
check("90051512340 (valid)",            Detectors.peselValid("90051512340"), true)
check("90051512341 (bad check digit)",  Detectors.peselValid("90051512341"), false)
check("90991512340 (month 99)",         Detectors.peselValid("90991512340"), false)
check("48123456789 (phone-like)",       Detectors.peselValid("48123456789"), false)
check("00000000000 (all zeros)",        Detectors.peselValid("00000000000"), false)
check("1234567890 (10 digits)",         Detectors.peselValid("1234567890"),  false)

print("\n── NIP checksum ────────────────────────────────────")
check("1234563218 (valid)",             Detectors.nipValid("1234563218"), true)
check("1234563219 (bad check digit)",   Detectors.nipValid("1234563219"), false)
check("0000000000 (all zeros)",         Detectors.nipValid("0000000000"), true)

print("\n── Polish identifiers ──────────────────────────────")
// Vectors computed from the published algorithms, not invented.
check("NRB 61109010140000071219812874",  Detectors.nrbValid("61109010140000071219812874"), true)
check("NRB same, one digit changed",     Detectors.nrbValid("61109010140000071219812875"), false)
check("NRB 25 digits",                   Detectors.nrbValid("6110901014000007121981287"),  false)
check("ID card ABC412345",               Detectors.idCardValid("ABC412345"), true)
check("ID card ABC512345 (bad check)",   Detectors.idCardValid("ABC512345"), false)
check("ID card MAC123456 (asset tag)",   Detectors.idCardValid("MAC123456"), false)
check("REGON 123456785",                 Detectors.regonValid("123456785"), true)
check("REGON 123456786 (bad check)",     Detectors.regonValid("123456786"), false)

print("\n── End-to-end OCR ──────────────────────────────────")

let lines: [(String, Bool)] = [
    ("Disk Encryption — FileVault 2", false),
    ("Individual Recovery Key: K7M2-9QX4-JH3T-BV8N-5RWZ-2CDF", true),
    ("PESEL: 90051512340", true),
    ("NIP: 1234563218", true),
    ("BitLocker: 123456-234567-345678-456789-567890-678901-789012-890123", true),
    ("db url https://admin:Sup3rS3cret@db.internal:5432", true),
    ("hook https://hooks.slack.com/services/T00/B11/XyZ123abc", true),
    ("stripe sk_" + "live_51HxYzAbCdEfGhIjKlMnOpQr", true),
    ("google GOCSPX-aB3dEfGh1JkLmN0pQrStUvWx", true),
    ("npm npm_aB3dEfGh1JkLmN0pQrStUvWxYz0123456789", true),
    ("mfa otpauth://totp/Acme:anna?secret=JBSWY3DPEHPK3PXP", true),
    ("Order number 90051512999 shipped", false),
    ("Build 123456-234567 completed", false),
    ("Policy ID 4021 executed 12 times", false),
    ("Konto: 61 1090 1014 0000 0712 1981 2874", true),
    ("Dowod osobisty: ABC412345", true),
    ("REGON: 123456785", true),
    ("Asset tag MAC123456 in stock", false),
]

func render() -> CGImage {
    let width = 1100, rowHeight = 34
    let height = 30 + lines.count * rowHeight
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
        .foregroundColor: NSColor.black,
    ]
    for (i, line) in lines.enumerated() {
        line.0.draw(at: NSPoint(x: 20, y: CGFloat(height - 30 - i * rowHeight)), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

let image = render()
let enabled = Set(Detectors.all.filter(\.defaultEnabled).map(\.id))
let detections = (try? Scanner.scan(image: image, enabled: enabled)) ?? []

print("  detected \(detections.count):")
for d in detections.sorted(by: { $0.rect.maxY > $1.rect.maxY }) {
    print("    \(d.label): \(d.text)")
}

// Compare through a glyph-confusion map: OCR reads "Kl" as "K1" and mangles
// base32 into lookalikes, so a literal substring test reports phantom misses
// even when the redaction box covers exactly the right pixels.
func canonical(_ s: String) -> String {
    let fixes: [Character: Character] = ["O": "0", "I": "1", "L": "1", "S": "5",
                                         "B": "8", "Z": "2", "G": "6"]
    return String(s.uppercased().compactMap { c -> Character? in
        guard c.isLetter || c.isNumber else { return nil }
        return fixes[c] ?? c
    })
}

// Every line flagged `true` must be covered; every line flagged `false` must not be.
print()
for (text, shouldHit) in lines {
    let haystack = canonical(text)
    // Prefix match: Vision sometimes emits Cyrillic lookalikes mid-token (Н for H,
    // Р for P), so the tail of a detection may not survive canonicalisation even
    // though the box covers the right pixels.
    let hit = detections.contains {
        let needle = canonical($0.text)
        // 16 chars, not 8: a BitLocker key starts "123456234567…", which an
        // unrelated "Build 123456-234567" line matches on a short prefix.
        return needle.count > 6 && haystack.contains(needle.prefix(16))
    }
    if hit != shouldHit {
        print("  \(shouldHit ? "MISSED" : "FALSE POSITIVE"): \(text)")
        failures += 1
    }
}

let redacted = Redactor.apply(to: image, detections: detections, style: .solid)
try? Redactor.pngData(redacted)?.write(to: URL(fileURLWithPath: "build/rulestest-redacted.png"))
let leftovers = Redactor.verify(redacted, enabled: enabled)
print("  leftovers after redaction: \(leftovers.count)")
if !leftovers.isEmpty { failures += 1 }

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
