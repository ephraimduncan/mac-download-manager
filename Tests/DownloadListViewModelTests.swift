import Foundation
import Testing

@testable import Mac_Download_Manager

actor MockAria2Controller: DownloadManagingAria2 {
  struct AddCall: Equatable {
    let url: URL
    let headers: [String: String]
    let dir: String
    let segments: Int
    let outputFileName: String?
  }

  private var activeStatuses: [Aria2Status]
  private var waitingStatuses: [Aria2Status]
  private var stoppedStatuses: [Aria2Status]
  private let addResult: String
  private let pauseError: Aria2Error?
  private let resumeError: Aria2Error?

  private var resumedGIDs: [String] = []
  private var addCalls: [AddCall] = []
  private var statusFailuresBeforeSuccess: Int

  init(
    activeStatuses: [Aria2Status] = [],
    waitingStatuses: [Aria2Status] = [],
    stoppedStatuses: [Aria2Status] = [],
    addResult: String = "new-gid",
    pauseError: Aria2Error? = nil,
    statusFailuresBeforeSuccess: Int = 0,
    resumeError: Aria2Error? = nil
  ) {
    self.activeStatuses = activeStatuses
    self.waitingStatuses = waitingStatuses
    self.stoppedStatuses = stoppedStatuses
    self.addResult = addResult
    self.pauseError = pauseError
    self.statusFailuresBeforeSuccess = statusFailuresBeforeSuccess
    self.resumeError = resumeError
  }

  func addDownload(
    url: URL,
    headers: [String: String],
    dir: String,
    segments: Int,
    outputFileName: String?
  ) async throws(Aria2Error) -> String {
    addCalls.append(
      AddCall(
        url: url,
        headers: headers,
        dir: dir,
        segments: segments,
        outputFileName: outputFileName
      ))
    return addResult
  }

  func pause(gid: String) async throws(Aria2Error) {
    if let pauseError {
      throw pauseError
    }
  }

  func pauseAll() async throws(Aria2Error) {}

  func resume(gid: String) async throws(Aria2Error) {
    resumedGIDs.append(gid)
    if let resumeError {
      throw resumeError
    }
  }

  func forceRemove(gid: String) async throws(Aria2Error) {}

  func removeDownloadResult(gid: String) async throws(Aria2Error) {}

  func tellActive() async throws(Aria2Error) -> [Aria2Status] {
    if statusFailuresBeforeSuccess > 0 {
      statusFailuresBeforeSuccess -= 1
      throw .connectionFailed(underlying: URLError(.cannotConnectToHost))
    }
    return activeStatuses
  }

  func tellWaiting(offset: Int, count: Int) async throws(Aria2Error) -> [Aria2Status] {
    return waitingStatuses
  }

  func tellStopped(offset: Int, count: Int) async throws(Aria2Error) -> [Aria2Status] {
    return stoppedStatuses
  }

  private var addTorrentCalls: [(data: Data, dir: String)] = []

  func addTorrent(data: Data, dir: String) async throws(Aria2Error) -> String {
    addTorrentCalls.append((data: data, dir: dir))
    return addResult
  }

  func recordedAddTorrentCalls() -> [(data: Data, dir: String)] {
    addTorrentCalls
  }

  func setStatuses(
    active: [Aria2Status] = [],
    waiting: [Aria2Status] = [],
    stopped: [Aria2Status] = []
  ) {
    activeStatuses = active
    waitingStatuses = waiting
    stoppedStatuses = stopped
  }

  func recordedResumes() -> [String] {
    resumedGIDs
  }

  func recordedAddCalls() -> [AddCall] {
    addCalls
  }
}

private func makeStatus(
  gid: String,
  status: String,
  totalLength: String,
  completedLength: String,
  downloadSpeed: String = "0"
) -> Aria2Status {
  Aria2Status(
    gid: gid,
    status: status,
    totalLength: totalLength,
    completedLength: completedLength,
    downloadSpeed: downloadSpeed,
    files: nil,
    errorCode: nil,
    errorMessage: nil,
    followedBy: nil
  )
}

@Suite("DownloadListViewModel")
struct DownloadListViewModelTests {
  @Test @MainActor
  func loadDownloadsClearsMissingGIDForRelaunchedApp() async throws {
    let repository = InMemoryDownloadRepository()
    let record = DownloadRecord(
      url: "https://example.com/archive.zip",
      filename: "archive.zip",
      progress: 0.42,
      status: DownloadStatus.downloading.rawValue,
      segments: 8,
      filePath: "/tmp/downloads",
      aria2Gid: "stale-gid"
    )
    try await repository.save(record)

    let aria2 = MockAria2Controller()
    let viewModel = DownloadListViewModel(repository: repository, aria2: aria2)

    await viewModel.loadDownloads()

    let loaded = try #require(viewModel.downloads.first)
    #expect(loaded.status == .paused)
    #expect(loaded.aria2Gid == nil)

    let persisted = try await repository.fetch(id: record.id)
    #expect(persisted?.status == DownloadStatus.paused.rawValue)
    #expect(persisted?.aria2Gid == nil)
  }

  @Test @MainActor
  func updateFromAria2ReconcilesMissingGIDAfterAriaStartsLate() async throws {
    let repository = InMemoryDownloadRepository()
    let record = DownloadRecord(
      url: "https://example.com/archive.zip",
      filename: "archive.zip",
      progress: 0.42,
      status: DownloadStatus.downloading.rawValue,
      segments: 8,
      filePath: "/tmp/downloads",
      aria2Gid: "stale-gid"
    )
    try await repository.save(record)

    let aria2 = MockAria2Controller(statusFailuresBeforeSuccess: 1)
    let viewModel = DownloadListViewModel(repository: repository, aria2: aria2)

    await viewModel.loadDownloads()

    let initial = try #require(viewModel.downloads.first)
    #expect(initial.status == .downloading)
    #expect(initial.aria2Gid == "stale-gid")

    await viewModel.updateFromAria2()

    let updated = try #require(viewModel.downloads.first)
    #expect(updated.status == .paused)
    #expect(updated.aria2Gid == nil)

    let persisted = try await repository.fetch(id: record.id)
    #expect(persisted?.status == DownloadStatus.paused.rawValue)
    #expect(persisted?.aria2Gid == nil)
  }

  @Test @MainActor
  func pauseDownloadClearsStaleGIDWhenAriaRejectsPause() async throws {
    let repository = InMemoryDownloadRepository()
    let record = DownloadRecord(
      url: "https://example.com/archive.zip",
      filename: "archive.zip",
      progress: 0.42,
      status: DownloadStatus.downloading.rawValue,
      segments: 8,
      filePath: "/tmp/downloads",
      aria2Gid: "stale-gid"
    )
    try await repository.save(record)

    let aria2 = MockAria2Controller(pauseError: .requestFailed(statusCode: 400))
    let viewModel = DownloadListViewModel(repository: repository, aria2: aria2)
    let item = DownloadItem(record: record)
    viewModel.downloads = [item]

    await viewModel.pauseDownload(item)

    let updated = try #require(viewModel.downloads.first)
    #expect(updated.status == .paused)
    #expect(updated.aria2Gid == nil)
    #expect(viewModel.errorMessage == nil)

    let persisted = try await repository.fetch(id: record.id)
    #expect(persisted?.status == DownloadStatus.paused.rawValue)
    #expect(persisted?.aria2Gid == nil)
  }

  @Test @MainActor
  func resumeDownloadRecreatesSessionWhenAriaRejectsPersistedGID() async throws {
    let repository = InMemoryDownloadRepository()
    let record = DownloadRecord(
      url: "https://example.com/archive.zip",
      filename: "archive.zip",
      progress: 0.42,
      status: DownloadStatus.paused.rawValue,
      segments: 12,
      filePath: "/tmp/downloads",
      aria2Gid: "stale-gid"
    )
    try await repository.save(record)

    let aria2 = MockAria2Controller(
      addResult: "fresh-gid",
      resumeError: .requestFailed(statusCode: 400)
    )
    let viewModel = DownloadListViewModel(repository: repository, aria2: aria2)
    let item = DownloadItem(record: record)
    viewModel.downloads = [item]

    await viewModel.resumeDownload(item)

    let updated = try #require(viewModel.downloads.first)
    #expect(updated.status == .downloading)
    #expect(updated.aria2Gid == "fresh-gid")
    #expect(updated.filePath == "/tmp/downloads")

    let persisted = try await repository.fetch(id: record.id)
    #expect(persisted?.status == DownloadStatus.downloading.rawValue)
    #expect(persisted?.aria2Gid == "fresh-gid")

    let resumedGIDs = await aria2.recordedResumes()
    #expect(resumedGIDs == ["stale-gid"])

    let addCalls = await aria2.recordedAddCalls()
    #expect(addCalls.count == 1)
    #expect(addCalls.first?.url == URL(string: "https://example.com/archive.zip"))
    #expect(addCalls.first?.dir == "/tmp/downloads")
    #expect(addCalls.first?.segments == 12)
    #expect(addCalls.first?.outputFileName == "archive.zip")
  }

  @Test @MainActor
  func recreatedResumeKeepsExistingProgressUntilAriaCatchesUp() async throws {
    let repository = InMemoryDownloadRepository()
    let record = DownloadRecord(
      url: "https://example.com/archive.zip",
      filename: "archive.zip",
      fileSize: 1000,
      progress: 0.42,
      status: DownloadStatus.paused.rawValue,
      segments: 12,
      filePath: "/tmp/downloads",
      aria2Gid: "stale-gid"
    )
    try await repository.save(record)

    let aria2 = MockAria2Controller(
      addResult: "fresh-gid",
      resumeError: .requestFailed(statusCode: 400)
    )
    let viewModel = DownloadListViewModel(repository: repository, aria2: aria2)
    let item = DownloadItem(record: record)
    viewModel.downloads = [item]

    await viewModel.resumeDownload(item)

    await aria2.setStatuses(active: [
      makeStatus(
        gid: "fresh-gid",
        status: "active",
        totalLength: "1000",
        completedLength: "0",
        downloadSpeed: "256"
      )
    ])
    await viewModel.updateFromAria2()

    let preserved = try #require(viewModel.downloads.first)
    #expect(preserved.downloadedSize == 420)
    #expect(preserved.progress == 0.42)

    await aria2.setStatuses(active: [
      makeStatus(
        gid: "fresh-gid",
        status: "active",
        totalLength: "1000",
        completedLength: "600",
        downloadSpeed: "256"
      )
    ])
    await viewModel.updateFromAria2()

    let updated = try #require(viewModel.downloads.first)
    #expect(updated.downloadedSize == 600)
    #expect(updated.progress == 0.6)
  }
}
