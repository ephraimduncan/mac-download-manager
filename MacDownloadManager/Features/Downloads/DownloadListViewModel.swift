import AppKit
import Foundation

@Observable @MainActor
final class DownloadListViewModel {
  private struct ResumeProgressSnapshot {
    let downloadedSize: Int64
    let progress: Double
  }

  private let repository: any DownloadRepository
  private let aria2: any DownloadManagingAria2
  private let notificationService: NotificationService
  private var needsAria2Reconciliation = true
  private var resumeProgressSnapshots: [UUID: ResumeProgressSnapshot] = [:]

  var downloads: [DownloadItem] = []
  var searchText = ""
  var filterOption: FilterOption = .all
  var errorMessage: String?
  var isAddURLPresented = false
  var selectedDownloadIDs: Set<UUID> = []
  var sortOrder: [KeyPathComparator<DownloadItem>] = [KeyPathComparator(\.createdAt, order: .reverse)]
  var pendingDuplicate: DownloadItem?
  private var pendingDownloadParams:
    (url: URL, headers: [String: String], directory: String, segments: Int)?

  var filteredDownloads: [DownloadItem] {
    var items = downloads
    switch filterOption {
    case .active:
      items = items.filter { $0.isActive }
    case .completed:
      items = items.filter { $0.status == .completed }
    case .paused:
      items = items.filter { $0.status == .paused }
    case .all:
      break
    }
    if !searchText.isEmpty {
      items = items.filter {
        $0.filename.localizedCaseInsensitiveContains(searchText)
          || $0.url.absoluteString.localizedCaseInsensitiveContains(searchText)
      }
    }
    items.sort(using: sortOrder)
    return items
  }

  init(repository: any DownloadRepository, aria2: any DownloadManagingAria2, notificationService: NotificationService = .shared) {
    self.repository = repository
    self.aria2 = aria2
    self.notificationService = notificationService
  }

  func loadDownloads() async {
    do {
      let records = try await repository.fetchAll()
      downloads = records.map { DownloadItem(record: $0) }
    } catch {
      errorMessage = "Failed to load downloads: \(error.localizedDescription)"
      return
    }

    needsAria2Reconciliation = true
    await updateFromAria2()
  }

  func addDownload(url: URL, headers: [String: String], directory: String, segments: Int) async {
    do {
      if let existing = try await repository.fetchByURL(url.absoluteString) {
        pendingDuplicate = DownloadItem(record: existing)
        pendingDownloadParams = (url, headers, directory, segments)
        return
      }
    } catch {
    }

    await performDownload(url: url, headers: headers, directory: directory, segments: segments)
  }

  func confirmDuplicate() {
    guard let params = pendingDownloadParams else { return }
    pendingDuplicate = nil
    let captured = params
    pendingDownloadParams = nil
    Task {
      await performDownload(
        url: captured.url, headers: captured.headers, directory: captured.directory,
        segments: captured.segments)
    }
  }

  func cancelDuplicate() {
    pendingDuplicate = nil
    pendingDownloadParams = nil
  }

  private func performDownload(
    url: URL, headers: [String: String], directory: String, segments: Int
  ) async {
    do {
      let gid = try await aria2.addDownload(
        url: url,
        headers: headers,
        dir: directory,
        segments: segments,
        outputFileName: url.suggestedFilename
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
      notificationService.postDownloadStarted(filename: url.suggestedFilename)
    } catch {
      errorMessage = "Failed to add download: \(error.localizedDescription)"
    }
  }

  func pauseDownload(_ item: DownloadItem) async {
    guard let gid = item.aria2Gid else {
      await updateItem(id: item.id) {
        $0.status = .paused
        $0.speed = 0
      }
      return
    }
    do {
      try await aria2.pause(gid: gid)
      await updateItem(id: item.id) {
        $0.status = .paused
        $0.speed = 0
      }
    } catch let error as Aria2Error where shouldRecoverMissingSession(from: error) {
      await updateItem(id: item.id) {
        $0.status = .paused
        $0.speed = 0
        $0.aria2Gid = nil
      }
    } catch {
      errorMessage = "Failed to pause: \(error.localizedDescription)"
    }
  }

  func resumeDownload(_ item: DownloadItem) async {
    if let gid = item.aria2Gid {
      do {
        try await aria2.resume(gid: gid)
        await updateItem(id: item.id) {
          $0.status = .downloading
          $0.speed = 0
        }
        return
      } catch let error as Aria2Error {
        guard shouldRecoverMissingSession(from: error) else {
          errorMessage = "Failed to resume: \(error.localizedDescription)"
          return
        }
      } catch {
        errorMessage = "Failed to resume: \(error.localizedDescription)"
        return
      }
    }

    do {
      try await recreateDownloadSession(for: item)
    } catch {
      errorMessage = "Failed to resume: \(error.localizedDescription)"
    }
  }

  func removeDownload(_ item: DownloadItem) async {
    resumeProgressSnapshots[item.id] = nil

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
      let allStatuses = try await fetchAllStatuses()
      await applyStatuses(allStatuses)

      if needsAria2Reconciliation {
        await reconcilePersistedDownloadsWithAria2(allStatuses)
      }
    } catch {
    }
  }

  private func updateItem(id: UUID, mutate: (inout DownloadItem) -> Void) async {
    guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
    var item = downloads[index]
    mutate(&item)
    downloads[index] = item
    do {
      try await repository.update(DownloadRecord(item: item))
    } catch {
      errorMessage = "Failed to persist update: \(error.localizedDescription)"
    }
  }

  private func fetchAllStatuses() async throws(Aria2Error) -> [Aria2Status] {
    let activeStatuses = try await aria2.tellActive()
    let waitingStatuses = try await aria2.tellWaiting(offset: 0, count: 100)
    let stoppedStatuses = try await aria2.tellStopped(offset: 0, count: 100)
    return activeStatuses + waitingStatuses + stoppedStatuses
  }

  private func applyStatuses(_ statuses: [Aria2Status]) async {
    for status in statuses {
      guard let index = downloads.firstIndex(where: { $0.aria2Gid == status.gid }) else {
        continue
      }

      let existing = downloads[index]
      let resolvedFilename = resolveFilename(from: status, fallback: existing.filename)
      let mappedStatus = mapAria2Status(status.status)

      if mappedStatus == .completed && existing.status != .completed {
        notificationService.postDownloadCompleted(filename: resolvedFilename)
      }
      let preservedProgress = preservedProgressIfNeeded(
        for: existing,
        completedBytes: status.completedBytes,
        progress: status.progress
      )
      let resolvedDownloadedSize = preservedProgress?.downloadedSize ?? status.completedBytes
      let resolvedProgress = preservedProgress?.progress ?? status.progress

      downloads[index] = DownloadItem(
        id: existing.id,
        url: existing.url,
        filename: resolvedFilename,
        fileSize: status.totalBytes > 0 ? status.totalBytes : existing.fileSize,
        downloadedSize: resolvedDownloadedSize,
        progress: resolvedProgress,
        speed: status.speedBytesPerSec,
        status: mappedStatus,
        segments: existing.segments,
        headers: existing.headers,
        createdAt: existing.createdAt,
        completedAt: mappedStatus == .completed
          ? (existing.completedAt ?? Date()) : existing.completedAt,
        filePath: existing.filePath,
        aria2Gid: existing.aria2Gid
      )

      do {
        if var record = try await repository.fetchByGid(status.gid) {
          record.progress = resolvedProgress
          record.fileSize = status.totalBytes > 0 ? status.totalBytes : record.fileSize
          record.status = mappedStatus.rawValue
          record.filename = resolvedFilename
          if mappedStatus == .completed && record.completedAt == nil {
            record.completedAt = Date()
          }
          try await repository.update(record)
        }
      } catch {
        errorMessage = "Failed to persist status update: \(error.localizedDescription)"
      }
    }
  }

  private func recreateDownloadSession(for item: DownloadItem) async throws(Aria2Error) {
    let directory = item.filePath ?? URL.downloadsDirectory.path(percentEncoded: false)
    let newGid = try await aria2.addDownload(
      url: item.url,
      headers: item.headers,
      dir: directory,
      segments: item.segments,
      outputFileName: item.filename
    )

    resumeProgressSnapshots[item.id] = ResumeProgressSnapshot(
      downloadedSize: item.downloadedSize,
      progress: item.progress
    )

    await updateItem(id: item.id) {
      $0.status = .downloading
      $0.speed = 0
      $0.filePath = directory
      $0.aria2Gid = newGid
    }
  }

  private func reconcilePersistedDownloadsWithAria2(_ statuses: [Aria2Status]) async {
    let knownGIDs = Set(statuses.map(\.gid))

    for item in downloads {
      guard item.status == .waiting || item.status == .downloading || item.status == .paused else {
        continue
      }
      guard let gid = item.aria2Gid, !knownGIDs.contains(gid) else {
        continue
      }

      await updateItem(id: item.id) {
        if $0.status == .waiting || $0.status == .downloading {
          $0.status = .paused
        }
        $0.speed = 0
        $0.aria2Gid = nil
      }
    }

    needsAria2Reconciliation = false
  }

  private func preservedProgressIfNeeded(
    for item: DownloadItem,
    completedBytes: Int64,
    progress: Double
  ) -> ResumeProgressSnapshot? {
    guard let snapshot = resumeProgressSnapshots[item.id] else {
      return nil
    }

    guard completedBytes < snapshot.downloadedSize else {
      resumeProgressSnapshots[item.id] = nil
      return nil
    }

    return snapshot
  }

  private func shouldRecoverMissingSession(from error: Aria2Error) -> Bool {
    switch error {
    case .requestFailed(statusCode: 400):
      return true
    case .rpcError(_, let message):
      return message.localizedCaseInsensitiveContains("not found")
    default:
      return false
    }
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
