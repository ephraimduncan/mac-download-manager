import Foundation

@MainActor
final class SafariDownloadMonitor {

    private static let appGroupId = "group.com.macdownloadmanager"
    private static let pendingDownloadsKey = "pendingDownloads"
    private static let pollInterval: TimeInterval = 2.0

    private var pollingTask: Task<Void, Never>?
    private let onDownloadRequest: @MainActor (NativeMessage) async -> Void

    init(onDownloadRequest: @escaping @MainActor (NativeMessage) async -> Void) {
        self.onDownloadRequest = onDownloadRequest
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPendingDownloads()
                try? await Task.sleep(for: .seconds(SafariDownloadMonitor.pollInterval))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func checkPendingDownloads() async {
        guard let defaults = UserDefaults(suiteName: SafariDownloadMonitor.appGroupId) else {
            return
        }

        guard let pending = defaults.array(forKey: SafariDownloadMonitor.pendingDownloadsKey)
            as? [[String: Any]], !pending.isEmpty
        else {
            return
        }

        defaults.removeObject(forKey: SafariDownloadMonitor.pendingDownloadsKey)

        for request in pending {
            guard let url = request["url"] as? String, !url.isEmpty else { continue }

            let headers: [String: String]? = {
                guard let raw = request["headers"] as? [String: String], !raw.isEmpty else {
                    return nil
                }
                return raw
            }()

            let filename: String? = {
                guard let name = request["filename"] as? String, !name.isEmpty else {
                    return nil
                }
                return name
            }()

            let fileSize: Int64? = {
                if let size = request["fileSize"] as? Int, size > 0 {
                    return Int64(size)
                }
                return nil
            }()

            let referrer: String? = {
                guard let ref = request["referrer"] as? String, !ref.isEmpty else {
                    return nil
                }
                return ref
            }()

            let message = NativeMessage(
                url: url,
                headers: headers,
                filename: filename,
                fileSize: fileSize,
                referrer: referrer
            )

            await onDownloadRequest(message)
        }
    }
}
