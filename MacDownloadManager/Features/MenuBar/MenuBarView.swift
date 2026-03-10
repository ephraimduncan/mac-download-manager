import SwiftUI

struct MenuBarView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        speedHeader

        Divider()

        if container.menuBarDownloads.isEmpty {
            Text("No active downloads")
                .disabled(true)
        } else {
            ForEach(container.menuBarDownloads) { download in
                Text(downloadLabel(download))
                    .disabled(true)
            }

            Divider()

            Button("Pause All") {
                Task { await pauseAll() }
            }
            Button("Resume All") {
                Task { await resumeAll() }
            }
        }

        Divider()

        Button("Open Mac Download Manager") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }

    private var speedHeader: some View {
        let speedText = formattedSpeed(container.globalDownloadSpeed)
        let count = container.menuBarDownloads.count
        return Text("\(speedText) — \(count) active")
            .disabled(true)
    }

    private func downloadLabel(_ download: MenuBarDownload) -> String {
        let percent = Int(download.progress * 100)
        if download.speed > 0 {
            return "\(download.filename) — \(percent)% (\(formattedSpeed(download.speed)))"
        }
        return "\(download.filename) — \(percent)%"
    }

    private func pauseAll() async {
        for download in container.menuBarDownloads where download.status == "active" {
            try? await container.aria2Client.pause(gid: download.gid)
        }
    }

    private func resumeAll() async {
        for download in container.menuBarDownloads where download.status == "paused" {
            try? await container.aria2Client.resume(gid: download.gid)
        }
    }

    private func formattedSpeed(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
    }
}
