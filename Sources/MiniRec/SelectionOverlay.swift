import AppKit

/// A dimmed overlay on every screen. Drag an area, then press Return or click Record.
/// Esc cancels.
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
            window.level = .screenSaver
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
            placeButton()
        }
    }
    private var anchor: CGPoint?
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)

    init(overlay: SelectionOverlay, screen: NSScreen, scale: CGFloat) {
        self.overlay = overlay
        self.screen = screen
        self.scale = scale
        super.init(frame: .zero)
        recordButton.bezelStyle = .push
        recordButton.keyEquivalent = "\r"
        recordButton.target = self
        recordButton.action = #selector(record)
        recordButton.isHidden = true
        addSubview(recordButton)
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

    private func placeButton() {
        recordButton.isHidden = selection == nil
        guard let s = selection else { return }
        recordButton.sizeToFit()
        let size = recordButton.frame.size
        // Below the area when there is room, else inside its bottom edge.
        var y = s.maxY + 8
        if y + size.height > bounds.maxY { y = s.maxY - size.height - 8 }
        recordButton.frame.origin = CGPoint(x: min(max(s.midX - size.width / 2, 0), bounds.maxX - size.width), y: y)
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
