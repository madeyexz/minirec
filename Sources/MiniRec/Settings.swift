import AVFoundation
import SwiftUI

/// User choices, stored in UserDefaults. The SwiftUI view and the recorder read the same keys.
struct Settings {
    enum Format: String { case mp4, frames }

    var format: Format
    var retina: Bool
    var fps: Int
    var frameInterval: Double
    var systemAudio: Bool
    var microphoneID: String
    var showCursor: Bool
    var useCmdShift5: Bool

    /// Registered once: registering posts UserDefaults.didChangeNotification, which makes the app load settings again.
    private static let registerDefaults: Void = UserDefaults.standard.register(defaults: [
        "format": Format.mp4.rawValue, "retina": false, "fps": 30, "frameInterval": 1.0,
        "systemAudio": true, "microphoneID": "", "showCursor": true, "useCmdShift5": false,
    ])

    static func load() -> Settings {
        _ = registerDefaults
        let d = UserDefaults.standard
        return Settings(
            format: Format(rawValue: d.string(forKey: "format") ?? "") ?? .mp4,
            retina: d.bool(forKey: "retina"),
            fps: d.integer(forKey: "fps"),
            frameInterval: d.double(forKey: "frameInterval"),
            systemAudio: d.bool(forKey: "systemAudio"),
            microphoneID: d.string(forKey: "microphoneID") ?? "",
            showCursor: d.bool(forKey: "showCursor"),
            useCmdShift5: d.bool(forKey: "useCmdShift5")
        )
    }

    static var saveFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniRec", isDirectory: true)
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }
}

struct SettingsView: View {
    @AppStorage("format") private var format = Settings.Format.mp4.rawValue
    @AppStorage("frameInterval") private var frameInterval = 1.0
    @AppStorage("retina") private var retina = false
    @AppStorage("fps") private var fps = 30
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("microphoneID") private var microphoneID = ""
    @AppStorage("showCursor") private var showCursor = true
    @AppStorage("useCmdShift5") private var useCmdShift5 = false
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
}
