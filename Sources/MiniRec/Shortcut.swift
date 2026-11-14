import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut. Carbon hot keys need no Accessibility permission.
/// The shortcut stays registered until the object is released.
final class HotKey {
    private static var handler: (() -> Void)?
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.handler = handler
        if !HotKey.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.installed = true
        }
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x4D52_4543, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}

/// The macOS shortcut ⇧⌘5 ("Screenshot and recording options") is symbolic hot key 184.
/// Apple does not document this setting; System Settings › Keyboard › Keyboard Shortcuts ›
/// Screenshots shows and changes the same value.
enum SystemScreenshotShortcut {
    static func setEnabled(_ enabled: Bool) {
        let entry = """
            <dict><key>enabled</key><\(enabled)/><key>value</key><dict><key>parameters</key>\
            <array><integer>53</integer><integer>23</integer><integer>1179648</integer></array>\
            <key>type</key><string>standard</string></dict></dict>
            """
        DispatchQueue.global().async {
            run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", "184", entry])
            // Applies the change now, without a logout.
            run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
        }
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
