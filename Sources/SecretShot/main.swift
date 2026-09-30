import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var regionHotKey: HotKey?
    private var windowHotKey: HotKey?
    private let watcher = PasteboardWatcher()
    private var preview: PreviewWindowController?
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye.slash",
                                          accessibilityDescription: "SecretShot")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()

        regionHotKey = HotKey(keyCode: HotKeyDefaults.regionKeyCode,
                              modifiers: HotKeyDefaults.regionModifiers) { [weak self] in
            self?.capture(mode: .region)
        }
        windowHotKey = HotKey(keyCode: HotKeyDefaults.windowKeyCode,
                              modifiers: HotKeyDefaults.windowModifiers) { [weak self] in
            self?.capture(mode: .window)
        }

        watcher.onImage = { [weak self] image in self?.process(image) }
        if Settings.shared.watchPasteboard { watcher.start() }

        // `SecretShot --check-permission` reports what TCC thinks of *this* bundle.
        // Written to a file rather than stdout because it has to be launched via
        // `open` — started from a terminal, TCC attributes the call to the terminal.
        if CommandLine.arguments.contains("--check-permission") {
            let report = """
                screenRecording=\(Capture.hasScreenRecordingAccess)
                bundlePath=\(Bundle.main.bundlePath)
                bundleID=\(Bundle.main.bundleIdentifier ?? "nil")
                """
            try? report.write(toFile: "/tmp/secretshot-permission.txt",
                              atomically: true, encoding: .utf8)
        }

        // `SecretShot --selftest-capture` performs a real non-interactive capture
        // and reports whether it came back usable. Needed because
        // CGPreflightScreenCaptureAccess() can report true while the capture
        // itself is still refused — only an actual frame settles it.
        if CommandLine.arguments.contains("--selftest-capture") {
            runCaptureSelfTest()
        }

        // `SecretShot --demo path.png` opens the review window straight away,
        // so preview layout can be checked without triggering a real capture.
        if let index = CommandLine.arguments.firstIndex(of: "--demo"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                process(image)
            }
        }
    }

    // MARK: - Pipeline

    @objc private func captureRegion() { capture(mode: .region) }
    @objc private func captureWindow() { capture(mode: .window) }

    private func capture(mode: CaptureMode) {
        guard !isBusy else { return }
        guard Capture.hasScreenRecordingAccess else {
            presentPermissionHelp()
            return
        }
        isBusy = true
        Capture.interactive(mode: mode) { [weak self] image in
            guard let self else { return }
            self.isBusy = false
            guard let image else { return } // user pressed Esc in the picker
            self.process(image)
        }
    }

    @objc private func scanClipboard() {
        guard let image = Capture.imageFromPasteboard() else {
            notify(title: "Nothing to scan", body: "The clipboard has no image in it.")
            return
        }
        process(image)
    }

    private func process(_ image: CGImage) {
        guard preview == nil else { return }

        // A blank frame usually means macOS refused the capture without saying so.
        // Flagged rather than blocked: a genuinely flat selection is legitimate, and
        // refusing to show it would be worse than an empty window.
        let warning = Capture.isUniform(image)
            ? "capture looks blank — if that's wrong, quit and reopen SecretShot"
            : nil

        setStatusSymbol("eye.slash.circle.fill")

        let enabled = Settings.shared.enabledRules
        DispatchQueue.global(qos: .userInitiated).async {
            let detections = (try? Scanner.scan(image: image, enabled: enabled)) ?? []
            DispatchQueue.main.async { [weak self] in
                self?.showPreview(image: image, detections: detections, warning: warning)
            }
        }
    }

    private func showPreview(image: CGImage, detections: [Detection], warning: String?) {
        setStatusSymbol("eye.slash")
        let controller = PreviewWindowController(image: image, detections: detections, warning: warning)
        controller.onFinish = { [weak self] result in
            guard let self else { return }
            self.preview = nil
            guard let result else { return }
            // Our own write must not retrigger the watcher into a scan loop.
            self.watcher.suppressNextChange()
            Capture.copyToPasteboard(result)
            self.flashDone()
        }
        preview = controller
        controller.show()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Capture Region…", #selector(captureRegion), key: HotKeyDefaults.regionDisplay))
        menu.addItem(item("Capture Window…", #selector(captureWindow), key: HotKeyDefaults.windowDisplay))
        menu.addItem(item("Scan Clipboard Image", #selector(scanClipboard)))
        menu.addItem(.separator())

        let watch = item("Watch Clipboard", #selector(toggleWatch))
        watch.state = Settings.shared.watchPasteboard ? .on : .off
        menu.addItem(watch)

        let verify = item("Verify After Redaction", #selector(toggleVerify))
        verify.state = Settings.shared.verifyAfterRedaction ? .on : .off
        menu.addItem(verify)

        let styleItem = NSMenuItem(title: "Redaction Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for style in RedactionStyle.allCases {
            let entry = item(style.title, #selector(setStyle(_:)))
            entry.representedObject = style.rawValue
            entry.state = Settings.shared.style == style ? .on : .off
            styleMenu.addItem(entry)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let detectItem = NSMenuItem(title: "Detect", action: nil, keyEquivalent: "")
        let detectMenu = NSMenu()
        let enabled = Settings.shared.enabledRules
        for rule in Detectors.all {
            let entry = item(rule.label, #selector(toggleRule(_:)))
            entry.representedObject = rule.id
            entry.state = enabled.contains(rule.id) ? .on : .off
            detectMenu.addItem(entry)
        }
        detectItem.submenu = detectMenu
        menu.addItem(detectItem)

        menu.addItem(.separator())
        if Capture.hasScreenRecordingAccess {
            menu.addItem(item("Screen Recording: granted", nil))
        } else {
            menu.addItem(item("Screen Recording: not granted — clipboard mode only",
                              #selector(showPermissionHelp)))
        }
        menu.addItem(item("Everything runs on this Mac", nil))
        menu.items.last?.isEnabled = false
        menu.addItem(item("Quit SecretShot", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = action != nil
        if !key.isEmpty {
            // Shown as a hint only — the real binding is the Carbon global hotkey.
            entry.attributedTitle = hintTitle(title, hint: key)
        }
        return entry
    }

    private func hintTitle(_ title: String, hint: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title + "   ")
        result.append(NSAttributedString(string: hint, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]))
        return result
    }

    @objc private func toggleWatch() {
        Settings.shared.watchPasteboard.toggle()
        if Settings.shared.watchPasteboard { watcher.start() } else { watcher.stop() }
        rebuildMenu()
    }

    @objc private func toggleVerify() {
        Settings.shared.verifyAfterRedaction.toggle()
        rebuildMenu()
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = RedactionStyle(rawValue: raw) else { return }
        Settings.shared.style = style
        rebuildMenu()
    }

    @objc private func toggleRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.toggleRule(id)
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Feedback

    private func setStatusSymbol(_ name: String) {
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "SecretShot")
        statusItem.button?.image?.isTemplate = true
    }

    private func flashDone() {
        setStatusSymbol("checkmark.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setStatusSymbol("eye.slash")
        }
    }

    private func runCaptureSelfTest() {
        let url = URL(fileURLWithPath: "/tmp/secretshot-selftest.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]   // whole screen, no interaction
        try? process.run()
        process.waitUntilExit()

        var report = "preflight=\(Capture.hasScreenRecordingAccess)\n"
        report += "exitCode=\(process.terminationStatus)\n"
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            report += "size=\(image.width)x\(image.height)\n"
            report += "uniform=\(Capture.isUniform(image))\n"
        } else {
            report += "image=unreadable\n"
        }
        try? report.write(toFile: "/tmp/secretshot-selftest.txt",
                          atomically: true, encoding: .utf8)
    }

    @objc private func showPermissionHelp() { presentPermissionHelp() }

    /// Replaces the raw TCC prompt — which reappears on every capture while the
    /// app is ad-hoc signed — with one explanation and a way out.
    private func presentPermissionHelp() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "SecretShot needs Screen Recording"
        alert.informativeText = """
            Capturing with \(HotKeyDefaults.regionDisplay) needs the Screen Recording \
            permission, because that's how macOS gates reading the screen.

            If you keep being asked again and again: this build is ad-hoc signed, and \
            macOS ties the permission to the app's signature, which changes on every \
            rebuild. Run Tools/make-signing-cert.sh once to make it stick.

            Clipboard mode needs no permission at all — take a screenshot with ⌃⌘⇧4 \
            and SecretShot will scan whatever lands on the clipboard.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Use Clipboard Mode")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Capture.requestScreenRecordingAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            if !Settings.shared.watchPasteboard {
                Settings.shared.watchPasteboard = true
                watcher.start()
                rebuildMenu()
            }
            notify(title: "Clipboard mode is on",
                   body: "Take a screenshot with ⌃⌘⇧4 and SecretShot will scan it automatically.")
        default:
            break
        }
    }

    private func notify(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
