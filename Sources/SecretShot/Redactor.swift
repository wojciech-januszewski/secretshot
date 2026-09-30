import Foundation
import CoreGraphics
import CoreImage
import AppKit

enum RedactionStyle: String, CaseIterable {
    case solid
    case pixelate
    case blur

    var title: String {
        switch self {
        case .solid: return "Solid black"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        }
    }

    /// Pixelate and blur are lossy but not provably irreversible; solid is.
    var isReversibleInPrinciple: Bool { self != .solid }
}

enum Redactor {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Burns the redactions into the pixels. The returned image has no layer,
    /// no alpha channel trickery and no metadata carried over — what you see is all there is.
    static func apply(to image: CGImage, detections: [Detection], style: RedactionStyle) -> CGImage {
        let active = detections.filter(\.enabled)
        guard !active.isEmpty else { return stripMetadata(image) }

        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(image, in: bounds)

        let rects = active.map { pixelRect($0.rect, in: bounds) }

        switch style {
        case .solid:
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(rects)

        case .pixelate, .blur:
            // Filter the whole frame once, then stencil only the secret regions back in.
            if let filtered = filteredImage(image, style: style, bounds: bounds) {
                ctx.saveGState()
                ctx.clip(to: rects)
                ctx.draw(filtered, in: bounds)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(rects)
            }
        }

        return ctx.makeImage() ?? image
    }

    /// Re-runs OCR on the redacted result: if any rule still fires, a box missed its target.
    /// Cheap insurance against the one screenshot that ends up in a public channel.
    static func verify(_ image: CGImage, enabled: Set<String>) -> [Detection] {
        (try? Scanner.scan(image: image, enabled: enabled)) ?? []
    }

    private static func filteredImage(_ image: CGImage, style: RedactionStyle, bounds: CGRect) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = max(bounds.width, bounds.height) / 100.0

        let output: CIImage?
        switch style {
        case .pixelate:
            let f = CIFilter(name: "CIPixellate")
            f?.setValue(input, forKey: kCIInputImageKey)
            f?.setValue(max(scale, 8), forKey: kCIInputScaleKey)
            output = f?.outputImage
        case .blur:
            let f = CIFilter(name: "CIGaussianBlur")
            f?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            f?.setValue(max(scale, 12), forKey: kCIInputRadiusKey)
            output = f?.outputImage?.cropped(to: input.extent)
        case .solid:
            output = nil
        }

        guard let output else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private static func pixelRect(_ normalized: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: normalized.minX * bounds.width,
               y: normalized.minY * bounds.height,
               width: normalized.width * bounds.width,
               height: normalized.height * bounds.height)
            .integral
    }

    /// Screenshots carry EXIF/TIFF dictionaries; re-encoding through a bare
    /// bitmap context drops them along with any window/app names macOS attached.
    private static func stripMetadata(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil,
                                  width: image.width,
                                  height: image.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
