import SwiftUI
import ServiceManagement

@Observable @MainActor
final class SettingsViewModel {
    @ObservationIgnored @AppStorage("defaultSegments") var defaultSegments: Int = 8
    @ObservationIgnored @AppStorage("defaultDownloadDir") var defaultDownloadDir: String = URL.downloadsDirectory.path()
    @ObservationIgnored @AppStorage("maxBandwidth") var maxBandwidth: Int = 0
    @ObservationIgnored @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @ObservationIgnored @AppStorage("interceptFileTypes") var interceptFileTypes: String = "zip,dmg,iso,pkg,tar.gz,7z,rar,mp4,mkv,avi,mov,mp3,flac,exe,msi,deb,AppImage"
    @ObservationIgnored @AppStorage("interceptMinSize") var interceptMinSizeMB: Int = 1
    @ObservationIgnored @AppStorage("interceptEnabled") var interceptEnabled: Bool = true

    private let aria2: Aria2Client?

    var errorMessage: String?

    var fileTypesArray: [String] {
        get { interceptFileTypes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        set { interceptFileTypes = newValue.joined(separator: ",") }
    }

    var bandwidthLimited: Bool {
        get { maxBandwidth > 0 }
        set {
            if !newValue { maxBandwidth = 0 }
            else if maxBandwidth == 0 { maxBandwidth = 1024 }
        }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    init(aria2: Aria2Client? = nil) {
        self.aria2 = aria2
    }

    func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin.toggle()
        }
    }

    func selectDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the default download location"

        if panel.runModal() == .OK, let url = panel.url {
            defaultDownloadDir = url.path()
        }
    }

    func applyBandwidthLimit() async {
        guard let aria2 else { return }
        let limitString = maxBandwidth > 0 ? "\(maxBandwidth)K" : "0"
        do {
            try await aria2.changeGlobalOption(options: ["max-overall-download-limit": limitString])
        } catch {
            errorMessage = "Failed to apply bandwidth limit: \(error.localizedDescription)"
        }
    }

    func resetFilterDefaults() {
        interceptFileTypes = "zip,dmg,iso,pkg,tar.gz,7z,rar,mp4,mkv,avi,mov,mp3,flac,exe,msi,deb,AppImage"
        interceptMinSizeMB = 1
        interceptEnabled = true
    }
}
