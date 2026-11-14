import AppKit

/// A dimmed overlay on every screen. Drag an area, then press Return or click Record.
/// Esc cancels. The toolbar under the area shows and changes the saved settings, so they stay
/// for the next recording.
final class SelectionOverlay {
    struct Selection {
        let screen: NSScreen
        /// In the screen's points, with the origin at its top-left corner.
        let rect: CGRect
    }

    private var windows: [NSWindow] = []
    private let pixelScale: (NSScreen) -> CGFloat
    private let completion: (Selection?) -> Void

    init(pixelScale: @escaping (NSScreen) -> CGFloat, completion: @escaping (Selection?) -> Void) {
        self.pixelScale = pixelScale
        self.completion = completion
    }

    func show() {
        for screen in NSScreen.screens {
            let window = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            // Below pop-up menus, so the microphone menu shows above the overlay.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(overlay: self, screen: screen, scale: pixelScale(screen))
            view.frame = CGRect(origin: .zero, size: screen.frame.size)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        // Make the panel under the pointer the key window, so Esc and Return work at once.
        // The panels do not activate MiniRec, so the app you were using stays in front.
        let mouse = NSEvent.mouseLocation
        windows.first { $0.frame.contains(mouse) }?.makeKeyAndOrderFront(nil)
    }

    fileprivate func clearOtherSelections(except view: SelectionView) {
        for case let other as SelectionView in windows.map(\.contentView) where other !== view {
            other.selection = nil
        }
    }

    fileprivate func finish(_ selection: Selection?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion(selection)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    unowned let overlay: SelectionOverlay
    let screen: NSScreen
    let scale: CGFloat
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            placeToolbar()
        }
    }
    private var anchor: CGPoint?
    private let toolbar = NSVisualEffectView()
    private let formatControl = NSSegmentedControl(labels: ["MP4", "Frames"], trackingMode: .selectOne, target: nil, action: nil)
    private let destinationControl = NSSegmentedControl(labels: ["Clipboard", "Folder"], trackingMode: .selectOne, target: nil, action: nil)
    private let soundButton = NSButton()
    private let micButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)

    init(overlay: SelectionOverlay, screen: NSScreen, scale: CGFloat) {
        self.overlay = overlay
        self.screen = screen
        self.scale = scale
        super.init(frame: .zero)
        let settings = Settings.load()

        formatControl.selectedSegment = settings.format == .frames ? 1 : 0
        formatControl.toolTip = "Export an MP4 video or image frames"
        formatControl.target = self
        formatControl.action = #selector(setFormat)

        destinationControl.selectedSegment = settings.destination == .folder ? 1 : 0
        let folder = (UserDefaults.standard.string(forKey: "folderPath").flatMap { $0.isEmpty ? nil : $0 }
            ?? Settings.defaultFolder.path).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        destinationControl.toolTip = "Copy to the clipboard, or save in \(folder)"
        destinationControl.target = self
        destinationControl.action = #selector(setDestination)

        soundButton.title = "Sound"
        soundButton.imagePosition = .imageLeading
        soundButton.bezelStyle = .push
        soundButton.setButtonType(.pushOnPushOff)
        soundButton.state = settings.systemAudio ? .on : .off
        soundButton.toolTip = "Record system sound"
        soundButton.target = self
        soundButton.action = #selector(setSound)
        showSoundState()

        micButton.addItem(withTitle: "No Mic")
        micButton.lastItem?.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: nil)
        micButton.lastItem?.representedObject = ""
        for mic in Settings.microphones() {
            micButton.addItem(withTitle: mic.localizedName)
            micButton.lastItem?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
            micButton.lastItem?.representedObject = mic.uniqueID
        }
        micButton.selectItem(at: max(micButton.indexOfItem(withRepresentedObject: settings.microphoneID), 0))
        micButton.toolTip = "Microphone"
        micButton.target = self
        micButton.action = #selector(setMicrophone)
        micButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true

        recordButton.bezelStyle = .push
        recordButton.keyEquivalent = "\r"
        recordButton.target = self
        recordButton.action = #selector(record)

        let stack = NSStackView(views: [formatControl, destinationControl, soundButton, micButton, recordButton])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        toolbar.material = .hudWindow
        toolbar.state = .active
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.masksToBounds = true
        toolbar.frame.size = toolbar.fittingSize
        toolbar.isHidden = true
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        overlay.clearOtherSelections(except: self)
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                           width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
            .intersection(bounds).integral
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        if let s = selection, s.width < 8 || s.height < 8 { selection = nil }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay.finish(nil) } // Esc
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { overlay.finish(nil) }

    @objc private func record() {
        guard let selection else { return }
        overlay.finish(.init(screen: screen, rect: selection))
    }

    private func placeToolbar() {
        toolbar.isHidden = selection == nil
        guard let s = selection else { return }
        let size = toolbar.frame.size
        // Below the area when there is room, else inside its bottom edge.
        var y = s.maxY + 8
        if y + size.height > bounds.maxY { y = s.maxY - size.height - 8 }
        toolbar.frame.origin = CGPoint(x: min(max(s.midX - size.width / 2, 0), bounds.maxX - size.width), y: y)
    }

    // Each control writes the saved setting at once, so the next selection starts with it.

    @objc private func setFormat() {
        UserDefaults.standard.set((formatControl.selectedSegment == 1 ? Settings.Format.frames : .mp4).rawValue, forKey: "format")
    }

    @objc private func setDestination() {
        UserDefaults.standard.set((destinationControl.selectedSegment == 1 ? Settings.Destination.folder : .clipboard).rawValue,
                                  forKey: "destination")
    }

    @objc private func setSound() {
        UserDefaults.standard.set(soundButton.state == .on, forKey: "systemAudio")
        showSoundState()
    }

    @objc private func setMicrophone() {
        UserDefaults.standard.set(micButton.selectedItem?.representedObject as? String ?? "", forKey: "microphoneID")
    }

    private func showSoundState() {
        let on = soundButton.state == .on
        soundButton.image = NSImage(systemSymbolName: on ? "speaker.wave.2.fill" : "speaker.slash", accessibilityDescription: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let s = selection else {
            drawLabel("Drag to select an area to record  ·  Esc to cancel", centeredAt: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSColor.clear.setFill()
        s.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: s.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        let size = "\(Int(s.width * scale) & ~1) × \(Int(s.height * scale) & ~1)"
        drawLabel(size, centeredAt: CGPoint(x: s.midX, y: max(s.minY - 16, 12)))
    }

    private func drawLabel(_ text: String, centeredAt center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let box = CGRect(x: center.x - size.width / 2 - 6, y: center.y - size.height / 2 - 3,
                         width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        str.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }
}

