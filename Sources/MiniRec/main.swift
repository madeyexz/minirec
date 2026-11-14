import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, selecting, recording, busy }

    private var state = State.idle
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var hotKey: HotKey?
    private var recordItem: NSMenuItem!
    private var usesCmdShift5: Bool?
    private var iconVisible = true
    private let updater = Updater()
    private var overlay: SelectionOverlay?
    private var recorder: Recorder?
    private var settings = Settings.load()
    private var border: NSWindow?
    private var timer: Timer?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        recordItem = menu.addItem(withTitle: "Record Area", action: #selector(recordArea), keyEquivalent: "7")
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MiniRec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }

        statusItem.button?.target = self
        statusItem.button?.action = #selector(stopFromStatusItem)
        statusItem.button?.imagePosition = .imageLeading
        showIdle()

        applySettings()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.applySettings()
        }

        updater.onReady = { [weak self] in if self?.state == .idle { self?.updater.installPending() } }
        updater.start()
    }

    // MARK: Flow: idle → selecting → recording → idle

    @objc private func recordArea() { toggle() }

    @objc private func stopFromStatusItem() { if state == .recording { stop() } }

    private func toggle() {
        switch state {
        case .idle: select()
        case .recording: stop()
        case .selecting, .busy: break
        }
    }

    private func select() {
        state = .selecting
        settings = Settings.load()
        let retina = settings.retina
        overlay = SelectionOverlay(pixelScale: { retina ? $0.backingScaleFactor : 1 }) { [weak self] selection in
            guard let self else { return }
            overlay = nil
            if let selection { start(selection) } else { showIdle() }
        }
        overlay?.show()
    }

    private func start(_ selection: SelectionOverlay.Selection) {
        state = .busy
        let settings = settings
        let scale = settings.retina ? selection.screen.backingScaleFactor : 1
        let width = Int(selection.rect.width * scale) & ~1
        let height = Int(selection.rect.height * scale) & ~1
        let displayID = selection.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let url = Settings.saveFolder.appendingPathComponent(Self.fileName())

        Task { @MainActor in
            do {
                if !settings.microphoneID.isEmpty, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    throw Self.error("Allow MiniRec to use the microphone in System Settings › Privacy & Security › Microphone, or choose None in Settings.")
                }
                try FileManager.default.createDirectory(at: Settings.saveFolder, withIntermediateDirectories: true)
                let recorder = try Recorder(url: url, width: width, height: height, settings: settings)
                recorder.onStreamError = { error in self.streamFailed(error) }
                try await recorder.start(displayID: displayID, rect: selection.rect, width: width, height: height, settings: settings)
                self.recorder = recorder
                showBorder(around: selection)
                showRecording()
            } catch {
                try? FileManager.default.removeItem(at: url)
                showIdle()
                Self.alert(error)
            }
        }
    }

    private func stop() {
        guard let recorder else { return }
        self.recorder = nil
        state = .busy
        border?.orderOut(nil)
        border = nil
        timer?.invalidate()
        statusItem.button?.title = ""
        statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Saving")
        let settings = settings

        Task { @MainActor in
            do {
                let video = try await recorder.stop()
                var files = [video]
                if settings.format == .frames {
                    files = try await FrameExporter.export(video: video, interval: settings.frameInterval)
                }
                if settings.destination == .clipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(files as [NSURL])
                }
                NSSound(named: "Pop")?.play()
            } catch {
                Self.alert(error)
            }
            showIdle()
        }
    }

    private func streamFailed(_ error: Error) {
        guard state == .recording else { return }
        stop() // keep what was recorded
        if (error as NSError).code != SCStreamError.userStopped.rawValue { Self.alert(error) }
    }

    // MARK: UI

    private func showIdle() {
        state = .idle
        timer?.invalidate()
        statusItem.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MiniRec")
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = nil
        if updater.pending != nil { updater.installPending() }
    }

    private func applySettings() {
        // Setting isVisible writes to UserDefaults, which calls this again before isVisible changes,
        // so compare with the value set last.
        let visible = !Settings.load().hideMenuBarIcon
        if visible != iconVisible {
            iconVisible = visible
            statusItem.isVisible = visible
        }
        applyShortcut()
    }

    /// With the menu bar icon hidden, opening MiniRec again (from Finder or Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// ⇧⌘7 by default. With "Record with ⇧⌘5" on, MiniRec turns off the macOS ⇧⌘5
    /// shortcut and uses ⇧⌘5. Turning the setting off gives ⇧⌘5 back to macOS.
    private func applyShortcut() {
        let use5 = Settings.load().useCmdShift5
        guard use5 != usesCmdShift5 else { return }
        let changed = usesCmdShift5 != nil
        usesCmdShift5 = use5
        // At launch, only turn the macOS shortcut off; do not turn on one that the user turned off.
        if use5 || changed { SystemScreenshotShortcut.setEnabled(!use5) }
        hotKey = nil
        hotKey = HotKey(keyCode: use5 ? kVK_ANSI_5 : kVK_ANSI_7, modifiers: cmdKey | shiftKey) { [weak self] in self?.toggle() }
        recordItem.keyEquivalent = use5 ? "5" : "7"
    }

    @objc private func checkForUpdates() { updater.check(userInitiated: true) }

    /// While recording, a click on the menu bar icon stops the recording.
    private func showRecording() {
        state = .recording
        statusItem.menu = nil
        statusItem.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        statusItem.button?.contentTintColor = .systemRed
        let start = Date()
        let tick = { [weak self] in
            let s = Int(Date().timeIntervalSince(start))
            self?.statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
    }

    /// A red frame just outside the recorded area. It is not in the recording.
    private func showBorder(around selection: SelectionOverlay.Selection) {
        let screen = selection.screen.frame, r = selection.rect
        let frame = CGRect(x: screen.minX + r.minX, y: screen.maxY - r.maxY, width: r.width, height: r.height)
            .insetBy(dx: -3, dy: -3)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = 2
        window.contentView = view
        window.orderFrontRegardless()
        border = window
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Settings.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.saveFolder)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "MiniRec Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private static func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(f.string(from: Date())).mp4"
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MiniRec", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func alert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "MiniRec could not record"
        alert.informativeText = error.localizedDescription
        if (error as NSError).code == SCStreamError.userDeclined.rawValue {
            alert.informativeText = "Allow MiniRec in System Settings › Privacy & Security › Screen & System Audio Recording, then open MiniRec again."
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
