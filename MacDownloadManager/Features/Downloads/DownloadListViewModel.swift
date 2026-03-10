import AppKit
import Foundation

@Observable @MainActor
final class DownloadListViewModel {
    private let repository: any DownloadRepository
    private let aria2: Aria2Client

    var downloads: [DownloadItem] = []
    var searchText = ""
    var filterOption: FilterOption = .active
    var errorMessage: String?
    var isAddURLPresented = false
    var selectedDownloadIDs: Set<UUID> = []
    var pendingDuplicate: DownloadItem?
    private var pendingDownloadParams: (url: URL, headers: [String: String], directory: String, segments: Int)?

    var filteredDownloads: [DownloadItem] {
        var items = downloads
        switch filterOption {
        case .active:
            items = items.filter { $0.isActive }
        case .completed:
            items = items.filter { $0.status == .completed }
        case .all:
            break
        }
        if !searchText.isEmpty {
            items = items.filter {
                $0.filename.localizedCaseInsensitiveContains(searchText)
                    || $0.url.absoluteString.localizedCaseInsensitiveContains(searchText)
            }
        }
        return items
    }

    init(repository: any DownloadRepository, aria2: Aria2Client) {
        self.repository = repository
        self.aria2 = aria2
    }

    func loadDownloads() async {
        do {
            let records = try await repository.fetchAll()
            downloads = records.map { DownloadItem(record: $0) }
        } catch {
            errorMessage = "Failed to load downloads: \(error.localizedDescription)"
        }
    }

    func addDownload(url: URL, headers: [String: String], directory: String, segments: Int) async {
        do {
            if let existing = try await repository.fetchByURL(url.absoluteString) {
                pendingDuplicate = DownloadItem(record: existing)
                pendingDownloadParams = (url, headers, directory, segments)
                return
            }
        } catch {
            // proceed with download if lookup fails
        }

        await performDownload(url: url, headers: headers, directory: directory, segments: segments)
    }

    func confirmDuplicate() {
        guard let params = pendingDownloadParams else { return }
        pendingDuplicate = nil
        let captured = params
        pendingDownloadParams = nil
        Task {
            await performDownload(url: captured.url, headers: captured.headers, directory: captured.directory, segments: captured.segments)
        }
    }

    func cancelDuplicate() {
        pendingDuplicate = nil
        pendingDownloadParams = nil
    }

    private func performDownload(url: URL, headers: [String: String], directory: String, segments: Int) async {
        do {
            let gid = try await aria2.addDownload(
                url: url,
                headers: headers,
                dir: directory,
                segments: segments
            )

            var headersJSON: String?
            if !headers.isEmpty, let data = try? JSONEncoder().encode(headers) {
                headersJSON = String(data: data, encoding: .utf8)
            }

            let record = DownloadRecord(
                url: url.absoluteString,
                filename: url.suggestedFilename,
                status: DownloadStatus.downloading.rawValue,
                segments: segments,
                headersJSON: headersJSON,
                filePath: directory,
                aria2Gid: gid
            )

            try await repository.save(record)
            downloads.insert(DownloadItem(record: record), at: 0)
        } catch {
            errorMessage = "Failed to add download: \(error.localizedDescription)"
        }
    }

    func pauseDownload(_ item: DownloadItem) async {
        guard let gid = item.aria2Gid else { return }
        do {
            try await aria2.pause(gid: gid)
            updateItemLocally(id: item.id) { $0.status = .paused; $0.speed = 0 }
        } catch {
            errorMessage = "Failed to pause: \(error.localizedDescription)"
        }
    }

    func resumeDownload(_ item: DownloadItem) async {
        guard let gid = item.aria2Gid else { return }
        do {
            try await aria2.resume(gid: gid)
            updateItemLocally(id: item.id) { $0.status = .downloading }
        } catch {
            errorMessage = "Failed to resume: \(error.localizedDescription)"
        }
    }

    func removeDownload(_ item: DownloadItem) async {
        if let gid = item.aria2Gid {
            if item.isActive {
                try? await aria2.forceRemove(gid: gid)
            }
            try? await aria2.removeDownloadResult(gid: gid)
        }

        do {
            try await repository.delete(id: item.id)
            downloads.removeAll { $0.id == item.id }
            selectedDownloadIDs.remove(item.id)
        } catch {
            errorMessage = "Failed to remove: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ item: DownloadItem) {
        guard let filePath = item.filePath else { return }
        let fileURL = URL(fileURLWithPath: filePath).appendingPathComponent(item.filename)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func togglePauseResume(_ item: DownloadItem) async {
        switch item.status {
        case .downloading, .waiting:
            await pauseDownload(item)
        case .paused:
            await resumeDownload(item)
        default:
            break
        }
    }

    func copyURL(_ item: DownloadItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
    }

    func updateFromAria2() async {
        do {
            let activeStatuses = try await aria2.tellActive()
            let waitingStatuses = try await aria2.tellWaiting(offset: 0, count: 100)
            let stoppedStatuses = try await aria2.tellStopped(offset: 0, count: 100)
            let allStatuses = activeStatuses + waitingStatuses + stoppedStatuses

            for status in allStatuses {
                guard let index = downloads.firstIndex(where: { $0.aria2Gid == status.gid }) else {
                    continue
                }

                let existing = downloads[index]
                let resolvedFilename = resolveFilename(from: status, fallback: existing.filename)
                let mappedStatus = mapAria2Status(status.status)

                downloads[index] = DownloadItem(
                    id: existing.id,
                    url: existing.url,
                    filename: resolvedFilename,
                    fileSize: status.totalBytes > 0 ? status.totalBytes : existing.fileSize,
                    downloadedSize: status.completedBytes,
                    progress: status.progress,
                    speed: status.speedBytesPerSec,
                    status: mappedStatus,
                    segments: existing.segments,
                    headers: existing.headers,
                    createdAt: existing.createdAt,
                    completedAt: mappedStatus == .completed ? (existing.completedAt ?? Date()) : existing.completedAt,
                    filePath: existing.filePath,
                    aria2Gid: existing.aria2Gid
                )

                if var record = try? await repository.fetchByGid(status.gid) {
                    record.progress = status.progress
                    record.fileSize = status.totalBytes > 0 ? status.totalBytes : record.fileSize
                    record.status = mappedStatus.rawValue
                    record.filename = resolvedFilename
                    if mappedStatus == .completed && record.completedAt == nil {
                        record.completedAt = Date()
                    }
                    try? await repository.update(record)
                }
            }
        } catch {
            // aria2 connection may be temporarily unavailable
        }
    }

    private func updateItemLocally(id: UUID, mutate: (inout DownloadItem) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        var item = downloads[index]
        mutate(&item)
        downloads[index] = item
    }

    private func mapAria2Status(_ status: String) -> DownloadStatus {
        switch status {
        case "active": .downloading
        case "waiting": .waiting
        case "paused": .paused
        case "complete": .completed
        case "error": .error
        case "removed": .removed
        default: .waiting
        }
    }

    private func resolveFilename(from status: Aria2Status, fallback: String) -> String {
        guard let files = status.files,
              let file = files.first,
              !file.path.isEmpty
        else {
            return fallback
        }
        return URL(fileURLWithPath: file.path).lastPathComponent
    }
}
