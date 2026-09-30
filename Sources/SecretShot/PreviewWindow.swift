import AppKit
import CoreGraphics

/// The image plus its redaction boxes. Non-flipped on purpose: AppKit's
/// bottom-left origin matches Vision's normalized space, so no coordinate flip
/// is needed anywhere between OCR, preview and the final bitmap.
final class RedactionView: NSView {

    var image: CGImage? { didSet { needsDisplay = true } }
    var detections: [Detection] = [] { didSet { needsDisplay = true; onChange?() } }
    var onChange: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?

    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?
    private var hoveredID: UUID?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    /// Aspect-fit box the image actually occupies. The window can be wider than
    /// the image (the footer's intrinsic width wins), and stretching a screenshot
    /// to fill that would both look wrong and misplace every redaction box.
    var imageRect: CGRect {
        guard let image, image.width > 0, image.height > 0 else { return bounds }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(bounds)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: imageRect)

        for detection in detections {
            let rect = denormalize(detection.rect)
            if detection.enabled {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.92).cgColor)
                ctx.fill(rect)
                ctx.setStrokeColor(strokeColor(for: detection).cgColor)
                ctx.setLineWidth(detection.id == hoveredID ? 2.5 : 1.5)
                ctx.stroke(rect)
            } else {
                // Revealed: dashed outline so you can see what you chose to expose.
                ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(detection.id == hoveredID ? 2.5 : 1.5)
                ctx.setLineDash(phase: 0, lengths: [5, 3])
                ctx.stroke(rect)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        if let origin = dragOrigin, let current = dragCurrent {
            let rect = CGRect(x: min(origin.x, current.x),
                              y: min(origin.y, current.y),
                              width: abs(current.x - origin.x),
                              height: abs(current.y - origin.y))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect)
        }
    }

    private func strokeColor(for detection: Detection) -> NSColor {
        detection.manual ? .systemBlue : .systemGreen
    }

    // MARK: - Coordinate mapping

    private func denormalize(_ rect: CGRect) -> CGRect {
        let frame = imageRect
        return CGRect(x: frame.minX + rect.minX * frame.width,
                      y: frame.minY + rect.minY * frame.height,
                      width: rect.width * frame.width,
                      height: rect.height * frame.height)
    }

    private func normalize(_ rect: CGRect) -> CGRect {
        let frame = imageRect
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - frame.minX) / frame.width,
                      y: (rect.minY - frame.minY) / frame.height,
                      width: rect.width / frame.width,
                      height: rect.height / frame.height)
    }

    private func detection(at point: CGPoint) -> Int? {
        // Reverse order so the most recently added box wins an overlap.
        detections.indices.reversed().first { denormalize(detections[$0].rect).contains(point) }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = detection(at: point).map { detections[$0].id }
        if newHover != hoveredID {
            hoveredID = newHover
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = detection(at: point) {
            if event.modifierFlags.contains(.option) {
                detections.remove(at: index)
            } else {
                detections[index].enabled.toggle()
            }
            return
        }
        dragOrigin = point
        dragCurrent = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil; dragCurrent = nil; needsDisplay = true }
        guard let origin = dragOrigin, let current = dragCurrent else { return }
        let rect = CGRect(x: min(origin.x, current.x),
                          y: min(origin.y, current.y),
                          width: abs(current.x - origin.x),
                          height: abs(current.y - origin.y))
        // A drag that runs off the edge shouldn't create a box outside the image.
        let clamped = rect.intersection(imageRect)
        guard clamped.width > 6, clamped.height > 6 else { return }
        detections.append(Detection(ruleID: "manual",
                                    label: "Manual",
                                    text: "",
                                    rect: normalize(clamped),
                                    manual: true))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(36), UInt16(76): // Return, keypad Enter
            onConfirm?()
        case UInt16(53): // Escape
            onCancel?()
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
                onSave?()
                return
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                setAll(enabled: detections.contains { !$0.enabled })
            case "h":
                setAll(enabled: true)
            default:
                super.keyDown(with: event)
            }
        }
    }

    private func setAll(enabled: Bool) {
        for i in detections.indices { detections[i].enabled = enabled }
    }
}

/// Modal-ish review window. Nothing reaches the clipboard until you press ⏎.
final class PreviewWindowController: NSWindowController, NSWindowDelegate {

    private let original: CGImage
    private let imageView = RedactionView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var verifyPassesRun = 0
    private var didFinish = false

    /// Called with the final redacted image, or nil when the user bailed out.
    var onFinish: ((CGImage?) -> Void)?

    private let warning: String?

    init(image: CGImage, detections: [Detection], warning: String? = nil) {
        self.original = image
        self.warning = warning

        // Place on whichever display the user just dragged the selection on —
        // NSScreen.main is unreliable for an .accessory app with no windows yet.
        let screen = PreviewWindowController.screenUnderMouse()
        let visible = screen.visibleFrame

        // A Retina capture's CGImage is in PIXELS; window geometry is in POINTS.
        // Without this divide the window comes out 2x too big and gets pushed offscreen.
        let pointWidth = CGFloat(image.width) / screen.backingScaleFactor
        let pointHeight = CGFloat(image.height) / screen.backingScaleFactor

        let maxSize = CGSize(width: visible.width * 0.85, height: visible.height * 0.85 - Self.footerHeight)
        let scale = min(maxSize.width / pointWidth, maxSize.height / pointHeight, 1.0)
        let imageSize = CGSize(width: max((pointWidth * scale).rounded(), 200),
                               height: max((pointHeight * scale).rounded(), 120))

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: max(imageSize.width, 520),
                                                            height: imageSize.height + Self.footerHeight)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SecretShot — review before copying"
        window.isReleasedWhenClosed = false
        window.level = .floating

        super.init(window: window)

        imageView.image = image
        imageView.detections = detections
        imageView.onChange = { [weak self] in self?.updateStatus() }
        imageView.onConfirm = { [weak self] in self?.confirm() }
        imageView.onCancel = { [weak self] in self?.cancel() }
        imageView.onSave = { [weak self] in self?.save() }

        buildLayout(imageSize: imageSize)
        window.delegate = self
        center(window, on: visible)
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static let footerHeight: CGFloat = 52

    private static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Centre within the target screen, then clamp so no edge lands offscreen.
    /// Without the clamp a window taller than the display gets a negative origin
    /// and simply never appears.
    private func center(_ window: NSWindow, on visible: CGRect) {
        let size = window.frame.size
        var origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), max(visible.maxX - size.width, visible.minX))
        origin.y = min(max(origin.y, visible.minY), max(visible.maxY - size.height, visible.minY))
        window.setFrameOrigin(origin)
    }

    private func buildLayout(imageSize: CGSize) {
        guard let window else { return }

        let container = NSView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        let footer = NSVisualEffectView()
        footer.material = .headerView
        footer.blendingMode = .withinWindow
        footer.state = .active
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // Let the label truncate instead of forcing the window wider than the image.
        statusLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let copyButton = NSButton(title: "Copy  ⏎", target: self, action: #selector(confirm))
        copyButton.keyEquivalent = "\r"
        copyButton.bezelStyle = .rounded
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        let stack = NSStackView(views: [statusLabel, NSView(), cancelButton, saveButton, copyButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        footer.addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.heightAnchor.constraint(equalToConstant: imageSize.height),

            footer.topAnchor.constraint(equalTo: imageView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),

            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        window.contentView = container
        window.makeFirstResponder(imageView)
    }

    private func updateStatus() {
        let hidden = imageView.detections.filter(\.enabled)
        let revealed = imageView.detections.count - hidden.count
        let types = Set(hidden.map(\.label)).sorted().joined(separator: ", ")

        var parts: [String] = ["\(hidden.count) hidden"]
        if revealed > 0 { parts.append("\(revealed) revealed") }
        if !types.isEmpty { parts.append(types) }
        parts.append("click = toggle · drag = add · ⌥click = delete")
        statusLabel.stringValue = parts.joined(separator: "  ·  ")

        if let warning {
            statusLabel.stringValue = "⚠ " + warning + "  ·  " + statusLabel.stringValue
            statusLabel.textColor = .systemOrange
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(imageView)
    }

    // MARK: - Actions

    @objc private func confirm() {
        let style = Settings.shared.style
        let result = Redactor.apply(to: original, detections: imageView.detections, style: style)

        // Second opinion: OCR the redacted output and see if anything still reads.
        if Settings.shared.verifyAfterRedaction, verifyPassesRun < 1 {
            verifyPassesRun += 1
            let leftovers = Redactor.verify(result, enabled: Settings.shared.enabledRules)
            if !leftovers.isEmpty {
                imageView.detections.append(contentsOf: leftovers)
                presentVerifyWarning(count: leftovers.count)
                return
            }
        }

        finish(with: result)
    }

    private func presentVerifyWarning(count: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(count) more secret\(count == 1 ? "" : "s") still readable"
        alert.informativeText = """
            A verification pass re-read the redacted image and found text that still \
            matches a rule. The new regions have been added to the preview. \
            Review them and press ⏎ again.
            """
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }

    @objc private func save() {
        let result = Redactor.apply(to: original, detections: imageView.detections, style: Settings.shared.style)
        guard let data = Redactor.pngData(result) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "redacted.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
            self?.finish(with: result)
        }
    }

    @objc private func cancel() {
        finish(with: nil)
    }

    private func finish(with image: CGImage?) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(image)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing via the red dot counts as cancelling.
        finish(with: nil)
    }
}
