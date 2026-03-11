import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pollingTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?

    private var container: DependencyContainer {
        DependencyContainer.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startAria2()
        startSocketServer()
        registerNativeMessagingManifest()
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
        guard let url = URL(string: message.url) else {
            return NativeResponse(accepted: false, error: "Invalid URL", activeCount: nil)
        }

        var headers = message.headers ?? [:]
        if let referrer = message.referrer, !referrer.isEmpty {
            headers["Referer"] = referrer
        }

        let filename = message.filename ?? url.suggestedFilename
        let downloadDir = URL.downloadsDirectory.path(percentEncoded: false)

        do {
            let gid = try await container.aria2Client.addDownload(
                url: url,
                headers: headers,
                dir: downloadDir,
                segments: 16,
                outputFileName: filename
            )

            var headersJSON: String?
            if !headers.isEmpty, let data = try? JSONEncoder().encode(headers) {
                headersJSON = String(data: data, encoding: .utf8)
            }

            let record = DownloadRecord(
                url: url.absoluteString,
                filename: filename,
                fileSize: message.fileSize,
                status: DownloadStatus.downloading.rawValue,
                segments: 16,
                headersJSON: headersJSON,
                filePath: downloadDir,
                aria2Gid: gid
            )

            try await container.repository.save(record)
            return NativeResponse(accepted: true, error: nil, activeCount: container.activeDownloadCount)
        } catch {
            return NativeResponse(accepted: false, error: error.localizedDescription, activeCount: nil)
        }
    }

    private func registerNativeMessagingManifest() {
        let chromeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")

        try? FileManager.default.createDirectory(at: chromeDir, withIntermediateDirectories: true)

        let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/NativeMessagingHelper"

        struct NativeManifest: Encodable {
            let name: String
            let description: String
            let path: String
            let type: String
            let allowed_origins: [String]
        }

        let manifest = NativeManifest(
            name: "com.macdownloadmanager.helper",
            description: "Mac Download Manager Native Messaging Host",
            path: helperPath,
            type: "stdio",
            allowed_origins: ["chrome-extension://YOUR_EXTENSION_ID/"]
        )

        let manifestPath = chromeDir.appendingPathComponent("com.macdownloadmanager.helper.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestPath)
        }
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
                    status: status.status
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
