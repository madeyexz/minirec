import AVFoundation
import ServiceManagement
import SwiftUI

/// User choices, stored in UserDefaults. The SwiftUI view and the recorder read the same keys.
struct Settings {
    enum Format: String { case mp4, frames }
    /// Clipboard: save in ~/Movies/MiniRec and copy the file. Folder: save in the chosen folder only.
    enum Destination: String { case clipboard, folder }

    var format: Format
    var destination: Destination
    var retina: Bool
    var fps: Int
    var frameInterval: Double
    var systemAudio: Bool
    var microphoneID: String
    var showCursor: Bool
    var useCmdShift5: Bool
    var hideMenuBarIcon: Bool

    /// Registered once: registering posts UserDefaults.didChangeNotification, which makes the app load settings again.
    private static let registerDefaults: Void = UserDefaults.standard.register(defaults: [
        "format": Format.mp4.rawValue, "destination": Destination.clipboard.rawValue, "folderPath": "", "retina": false, "fps": 30, "frameInterval": 1.0,
        "systemAudio": true, "microphoneID": "", "showCursor": true, "useCmdShift5": false,
        "hideMenuBarIcon": false,
    ])

    static func load() -> Settings {
        _ = registerDefaults
        let d = UserDefaults.standard
        return Settings(
            format: Format(rawValue: d.string(forKey: "format") ?? "") ?? .mp4,
            destination: Destination(rawValue: d.string(forKey: "destination") ?? "") ?? .clipboard,
            retina: d.bool(forKey: "retina"),
            fps: d.integer(forKey: "fps"),
            frameInterval: d.double(forKey: "frameInterval"),
            systemAudio: d.bool(forKey: "systemAudio"),
            microphoneID: d.string(forKey: "microphoneID") ?? "",
            showCursor: d.bool(forKey: "showCursor"),
            useCmdShift5: d.bool(forKey: "useCmdShift5"),
            hideMenuBarIcon: d.bool(forKey: "hideMenuBarIcon")
        )
    }

    static let defaultFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MiniRec", isDirectory: true)

    /// Where recordings are saved: the chosen folder in Folder mode, else ~/Movies/MiniRec.
    static var saveFolder: URL {
        _ = registerDefaults
        let d = UserDefaults.standard
        guard d.string(forKey: "destination") == Destination.folder.rawValue,
              let path = d.string(forKey: "folderPath"), !path.isEmpty else { return defaultFolder }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }
}

struct SettingsView: View {
    @AppStorage("format") private var format = Settings.Format.mp4.rawValue
    @AppStorage("destination") private var destination = Settings.Destination.clipboard.rawValue
    @AppStorage("folderPath") private var folderPath = ""
    @AppStorage("frameInterval") private var frameInterval = 1.0
    @AppStorage("retina") private var retina = false
    @AppStorage("fps") private var fps = 30
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("microphoneID") private var microphoneID = ""
    @AppStorage("showCursor") private var showCursor = true
    @AppStorage("useCmdShift5") private var useCmdShift5 = false
    @AppStorage("hideMenuBarIcon") private var hideMenuBarIcon = false
    /// macOS owns this setting (System Settings › General › Login Items), so read it from there.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var microphones = Settings.microphones()

    var body: some View {
        Form {
            Toggle(isOn: $useCmdShift5) {
                Text("Record with ⇧⌘5")
                Text(useCmdShift5 ? "The macOS screenshot toolbar shortcut is off."
                                  : "Replaces the macOS screenshot toolbar shortcut. Otherwise ⇧⌘7.")
            }
            Picker("Export", selection: $format) {
                Text("MP4 video").tag(Settings.Format.mp4.rawValue)
                Text("Image frames").tag(Settings.Format.frames.rawValue)
            }
            Picker("Save to", selection: $destination) {
                Text("Clipboard").tag(Settings.Destination.clipboard.rawValue)
                Text("Folder").tag(Settings.Destination.folder.rawValue)
            }
            if destination == Settings.Destination.folder.rawValue {
                LabeledContent {
                    Button("Choose…", action: chooseFolder)
                } label: {
                    Text("Folder")
                    Text((folderPath.isEmpty ? Settings.defaultFolder.path : folderPath)
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if format == Settings.Format.frames.rawValue {
                Picker("One frame every", selection: $frameInterval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                }
            }
            Picker("Resolution", selection: $retina) {
                Text("Standard (1×, smaller)").tag(false)
                Text("Retina (full)").tag(true)
            }
            Picker("Frame rate", selection: $fps) {
                Text("15 fps").tag(15)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Toggle(isOn: $hideMenuBarIcon) {
                Text("Hide menu bar icon")
                Text("Open MiniRec again to show Settings.")
            }
            Toggle("Show cursor", isOn: $showCursor)
            Toggle("Record system sound", isOn: $systemAudio)
            Picker("Microphone", selection: $microphoneID) {
                Text("None").tag("")
                ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = Settings.saveFolder
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }
}
