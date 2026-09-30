import Foundation
import Vision
import CoreGraphics

/// One thing to hide. `rect` is in Vision's normalized space:
/// 0…1, origin bottom-left — same convention CoreGraphics draws in,
/// so it maps to both the preview view and the output bitmap without flipping.
struct Detection: Identifiable, Equatable {
    let id = UUID()
    let ruleID: String
    let label: String
    /// OCR'd text — kept only in memory, never written anywhere.
    let text: String
    var rect: CGRect
    var enabled: Bool = true
    /// True for boxes the user drew by hand rather than ones we found.
    var manual: Bool = false

    static func == (a: Detection, b: Detection) -> Bool { a.id == b.id }
}

enum Scanner {

    /// Runs OCR entirely on-device and returns every region matching an enabled rule.
    /// Nothing leaves the process — Vision has no network path.
    static func scan(image: CGImage, enabled: Set<String>) throws -> [Detection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" tokens like ghp_xxx into words. Must stay off.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US", "pl-PL"]
        request.minimumTextHeight = 0.0

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        // Admin panels are tables: the label ("Serial Number:") and the value sit in
        // separate columns, which Vision returns as separate observations. Context
        // therefore has to be spatial — everything on the same horizontal band —
        // not just the characters of one line.
        let lines: [(text: String, box: CGRect, candidate: VNRecognizedText)] =
            observations.compactMap { obs in
                guard let c = obs.topCandidates(1).first else { return nil }
                return (c.string, obs.boundingBox, c)
            }

        var detections: [Detection] = []
        for line in lines {
            let context = rowContext(for: line.box, in: lines)
            let candidate = line.candidate
            for match in Detectors.scan(line: line.text, context: context, enabled: enabled) {
                guard let box = try? candidate.boundingBox(for: match.range) else { continue }
                detections.append(
                    Detection(ruleID: match.ruleID,
                              label: match.ruleLabel,
                              text: match.text,
                              rect: pad(box.boundingBox))
                )
            }
        }
        return merge(detections)
    }

    /// All text sharing a horizontal band with `box`, joined. This is what lets a
    /// value in the right-hand column see the label in the left-hand one.
    private static func rowContext(for box: CGRect,
                                   in lines: [(text: String, box: CGRect, candidate: VNRecognizedText)]) -> String {
        lines
            .filter { abs($0.box.midY - box.midY) < max($0.box.height, box.height) * 0.6 }
            .sorted { $0.box.minX < $1.box.minX }
            .map(\.text)
            .joined(separator: " ")
    }

    /// OCR boxes hug the glyphs; a little bleed guarantees no readable pixel survives.
    private static func pad(_ rect: CGRect) -> CGRect {
        let dx = max(rect.width * 0.02, 0.002)
        let dy = max(rect.height * 0.18, 0.004)
        return rect.insetBy(dx: -dx, dy: -dy)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Two rules hitting adjacent parts of the same line produce touching boxes;
    /// merging them keeps the preview readable and the redaction solid.
    private static func merge(_ detections: [Detection]) -> [Detection] {
        var result: [Detection] = []
        for d in detections {
            if let i = result.firstIndex(where: { overlaps($0.rect, d.rect) && $0.ruleID == d.ruleID }) {
                result[i].rect = result[i].rect.union(d.rect)
            } else {
                result.append(d)
            }
        }
        return result
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        // Same text line, horizontally adjacent or intersecting.
        guard abs(a.midY - b.midY) < max(a.height, b.height) * 0.6 else { return false }
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return gap < 0.005
    }
}
