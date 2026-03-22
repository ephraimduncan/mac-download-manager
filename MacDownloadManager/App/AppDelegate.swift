import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pollingTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?
    private var safariDownloadMonitor: SafariDownloadMonitor?

    private var container: DependencyContainer {
        DependencyContainer.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        container.notificationService.requestAuthorization()
        startAria2()
        startSocketServer()
        registerNativeMessagingManifest()
        startSafariDownloadMonitor()
        startPolling()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard container.activeDownloadCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Downloads are active"
        alert.informativeText = "Quitting will pause all active downloads. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task {
            try? await container.aria2Client.pauseAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingTask?.cancel()
        safariDownloadMonitor?.stop()
        container.processManager.terminate()
        container.socketServer.stop()
        endDownloadActivity()
    }

    private func startAria2() {
        let downloadDir = URL.downloadsDirectory.path(percentEncoded: false)
        do {
            try container.processManager.launch(
                secret: container.aria2Secret,
                port: container.aria2Port,
                downloadDir: downloadDir,
                maxConcurrent: 5
            )
        } catch {
            print("Failed to launch aria2c: \(error)")
        }
    }

    private func startSocketServer() {
        let appSupportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Mac Download Manager")

        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        let socketPath = appSupportDir.appendingPathComponent("helper.sock").path

        container.socketServer.onMessage = { [weak self] message in
            guard let self else {
                return NativeResponse(accepted: false, error: "App delegate deallocated", activeCount: nil)
            }
            return await self.handleNativeMessage(message)
        }

        do {
            try container.socketServer.start(socketPath: socketPath)
        } catch {
            print("Failed to start socket server: \(error)")
        }
    }

    private func handleNativeMessage(_ message: NativeMessage) async -> NativeResponse {
        guard URL(string: message.url) != nil else {
            return NativeResponse(accepted: false, error: "Invalid URL", activeCount: nil)
        }

        container.pendingExtensionDownload = PendingExtensionDownload(id: UUID(), message: message)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.title == "Mac Download Manager" }) ?? NSApp.windows.first(where: { !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            container.openMainWindow?()
        }

        return NativeResponse(accepted: true, error: nil, activeCount: container.activeDownloadCount)
    }

    private func registerNativeMessagingManifest() {
        let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/NativeMessagingHelper"
        NativeMessagingRegistration.registerAll(helperPath: helperPath)
    }

    private func startSafariDownloadMonitor() {
        safariDownloadMonitor = SafariDownloadMonitor { [weak self] message in
            guard let self else { return }
            let response = await self.handleNativeMessage(message)
            if !response.accepted {
                print("Safari download request failed: \(response.error ?? "unknown error")")
            }
        }
        safariDownloadMonitor?.start()
    }

    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.pollAria2Status()
            }
        }
    }

    private func pollAria2Status() async {
        do {
            let stat = try await container.aria2Client.getGlobalStat()
            let activeCount = Int(stat.numActive) ?? 0
            container.activeDownloadCount = activeCount
            container.globalDownloadSpeed = Int64(stat.downloadSpeed) ?? 0

            let active = try await container.aria2Client.tellActive()
            let waiting = try await container.aria2Client.tellWaiting(offset: 0, count: 100)

            container.menuBarDownloads = (active + waiting).map { status in
                let filename = status.files?.first.map {
                    URL(fileURLWithPath: $0.path).lastPathComponent
                } ?? status.gid

                return MenuBarDownload(
                    id: status.gid,
                    filename: filename,
                    progress: status.progress,
                    speed: status.speedBytesPerSec,
                    gid: status.gid,
                    status: status.status,
                    totalLength: status.totalBytes,
                    completedLength: status.completedBytes
                )
            }

            if activeCount > 0 {
                beginDownloadActivity()
            } else {
                endDownloadActivity()
            }
        } catch {
        }
    }

    private func beginDownloadActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Active downloads in progress"
        )
    }

    private func endDownloadActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
