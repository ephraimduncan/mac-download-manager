import SwiftUI

struct MenuBarView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            speedHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if container.menuBarDownloads.isEmpty {
                Text("No active downloads")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(container.menuBarDownloads) { download in
                        downloadRow(download)
                        if download.id != container.menuBarDownloads.last?.id {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }

                Divider()

                Button {
                    Task { await pauseAll() }
                } label: {
                    Text("Pause All")
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                Button {
                    Task { await resumeAll() }
                } label: {
                    Text("Resume All")
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Text("Open Mac Download Manager")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }

    private var speedHeader: some View {
        HStack {
            Text("\(formattedSpeed(container.globalDownloadSpeed)) — \(container.activeDownloadCount) active")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func downloadRow(_ download: MenuBarDownload) -> some View {
        let percent = Int(download.progress * 100)
        let isPausable = download.status == "active" || download.status == "waiting"
        let isPaused = download.status == "paused"

        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(download.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if isPaused {
                        Text("Paused — \(percent)%")
                    } else if download.speed > 0 {
                        if let eta = download.formattedETA {
                            Text("\(formattedSpeed(download.speed)) — \(percent)% — \(eta) left")
                        } else {
                            Text("\(formattedSpeed(download.speed)) — \(percent)%")
                        }
                    } else {
                        Text("\(percent)%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isPausable {
                Button {
                    Task { try? await container.aria2Client.pause(gid: download.gid) }
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            } else if isPaused {
                Button {
                    Task { try? await container.aria2Client.resume(gid: download.gid) }
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
