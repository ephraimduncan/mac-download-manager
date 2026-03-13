import Foundation
import Testing

@testable import Mac_Download_Manager

private actor MockURLMetadataService: URLMetadataService {
    private var result: URLMetadata
    private var delay: Duration?
    private var fetchCount = 0

    init(
        filename: String = "file.zip",
        fileSize: Int64? = 1024,
        delay: Duration? = nil
    ) {
        self.result = URLMetadata(filename: filename, fileSize: fileSize)
        self.delay = delay
    }

    func fetchMetadata(for url: URL) async -> URLMetadata {
        fetchCount += 1
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return result
    }

    func setResult(filename: String, fileSize: Int64?) {
        self.result = URLMetadata(filename: filename, fileSize: fileSize)
    }

    func getFetchCount() -> Int {
        fetchCount
    }
}

private struct FixedDiskSpaceProvider: DiskSpaceProviding {
    var availableSpace: Int64?

    func availableDiskSpace(at path: String) -> Int64? {
        availableSpace
    }
}

@Suite("AddDownloadViewModel")
struct AddDownloadViewModelTests {

    @MainActor
    private func makeViewModel(
        metadataService: URLMetadataService? = nil,
        repository: InMemoryDownloadRepository? = nil,
        aria2: MockAria2Controller? = nil,
        defaultDownloadDir: String? = nil,
        diskSpaceProvider: DiskSpaceProviding? = nil
    ) -> (AddDownloadViewModel, InMemoryDownloadRepository, MockAria2Controller) {
        let repo = repository ?? InMemoryDownloadRepository()
        let aria = aria2 ?? MockAria2Controller(addResult: "test-gid")
        let settings = SettingsViewModel()
        if let dir = defaultDownloadDir {
            settings.defaultDownloadDir = dir
        }
        let meta = metadataService ?? MockURLMetadataService()
        let dsp = diskSpaceProvider ?? FixedDiskSpaceProvider(availableSpace: 50_000_000_000)
        let vm = AddDownloadViewModel(
            metadataService: meta,
            repository: repo,
            aria2: aria,
            settings: settings,
            diskSpaceProvider: dsp
        )
        return (vm, repo, aria)
    }

    @Test @MainActor
    func initialStateIsIdleWithEmptyURL() {
        let (vm, _, _) = makeViewModel()
        guard case .idle = vm.state else {
            Issue.record("Expected .idle state, got \(vm.state)")
            return
        }
        #expect(vm.urlText == "")
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func validHTTPURLEnablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "https://example.com/file.zip"
        #expect(vm.isOKEnabled == true)
    }

    @Test @MainActor
    func invalidURLDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "ftp://example.com/file.zip"
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func trimmedURLUsedForDuplicateLookup() async {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/file.zip",
            filename: "file.zip",
            fileSize: 1024,
            status: DownloadStatus.completed.rawValue
        )
        try! await repo.save(existingRecord)

        let (vm, _, _) = makeViewModel(repository: repo)
        vm.urlText = "  https://example.com/file.zip  "

        await vm.submitURL()

        guard case .duplicateFound = vm.state else {
            Issue.record("Expected .duplicateFound, got \(vm.state)")
            return
        }
    }

    @Test @MainActor
    func cancelDuringQueryingReturnsToIdle() async {
        let metaService = MockURLMetadataService(
            filename: "file.zip",
            fileSize: 1024,
            delay: .seconds(2)
        )
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        let task = Task { @MainActor in
            await vm.submitURL()
        }

        try? await Task.sleep(for: .milliseconds(50))
        vm.cancel()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after cancel during querying, got \(vm.state)")
            task.cancel()
            return
        }
        #expect(vm.urlText == "")
        task.cancel()
    }

    @Test @MainActor
    func lateCompletionAfterCancelIsIgnored() async {
        let metaService = MockURLMetadataService(
            filename: "file.zip",
            fileSize: 1024,
            delay: .milliseconds(200)
        )
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        let task = Task { @MainActor in
            await vm.submitURL()
        }

        try? await Task.sleep(for: .milliseconds(50))
        vm.cancel()
        try? await Task.sleep(for: .milliseconds(300))

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after late completion, got \(vm.state)")
            task.cancel()
            return
        }
        task.cancel()
    }

    @Test @MainActor
    func queryingTransitionsToNewDownload() async {
        let metaService = MockURLMetadataService(filename: "downloaded.zip", fileSize: 2048)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/downloaded.zip"

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload, got \(vm.state)")
            return
        }
        #expect(metadata.filename == "downloaded.zip")
        #expect(metadata.fileSize == 2048)
        #expect(vm.editableFilename == "downloaded.zip")
    }

    @Test @MainActor
    func queryingTransitionsToDuplicateFound() async {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/existing.zip",
            filename: "existing.zip",
            fileSize: 4096,
            status: DownloadStatus.completed.rawValue,
            filePath: "/Users/test/Downloads"
        )
        try! await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "existing.zip", fileSize: 4096)
        let (vm, _, _) = makeViewModel(metadataService: metaService, repository: repo)
        vm.urlText = "https://example.com/existing.zip"

        await vm.submitURL()

        guard case .duplicateFound(let record) = vm.state else {
            Issue.record("Expected .duplicateFound, got \(vm.state)")
            return
        }
        #expect(record.url == "https://example.com/existing.zip")
    }

    @Test @MainActor
    func repeatedSubmitDuringQueryingIsIdempotent() async {
        let metaService = MockURLMetadataService(
            filename: "file.zip",
            fileSize: 1024,
            delay: .milliseconds(300)
        )
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        let task1 = Task { @MainActor in
            await vm.submitURL()
        }

        try? await Task.sleep(for: .milliseconds(50))
        await vm.submitURL()
        task1.cancel()

        let count = await metaService.getFetchCount()
        #expect(count == 1)
    }

    @Test @MainActor
    func skipClearsStateWithoutCreatingDownload() async {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/file.zip",
            filename: "file.zip",
            status: DownloadStatus.completed.rawValue
        )
        try! await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, repoUsed, _) = makeViewModel(metadataService: metaService, repository: repo)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()
        vm.skip()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after skip, got \(vm.state)")
            return
        }
        let all = try! await repoUsed.fetchAll()
        #expect(all.count == 1)
    }

    @Test @MainActor
    func forceDownloadFromDuplicateCreatesNewRecord() async throws {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            id: UUID(),
            url: "https://example.com/file.zip",
            filename: "file.zip",
            fileSize: 1024,
            status: DownloadStatus.completed.rawValue,
            filePath: "/original/path"
        )
        try await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "dup-gid")
        let (vm, repoUsed, _) = makeViewModel(
            metadataService: metaService,
            repository: repo,
            aria2: aria2
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()
        guard case .duplicateFound = vm.state else {
            Issue.record("Expected .duplicateFound, got \(vm.state)")
            return
        }

        await vm.forceDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after force download, got \(vm.state)")
            return
        }

        let all = try await repoUsed.fetchAll()
        #expect(all.count == 2)

        let original = try await repoUsed.fetch(id: existingRecord.id)
        #expect(original?.status == DownloadStatus.completed.rawValue)
    }

    @Test @MainActor
    func downloadInitiatesAria2AndSavesRecord() async throws {
        let expectedDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path()
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "new-gid-123")
        let (vm, repo, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()
        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after download, got \(vm.state)")
            return
        }

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.count == 1)
        let call = try #require(addCalls.first)
        #expect(call.url == URL(string: "https://example.com/file.zip"))
        #expect(call.dir == expectedDir)
        #expect(call.outputFileName == "file.zip")

        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        let saved = try #require(all.first)
        #expect(saved.url == "https://example.com/file.zip")
        #expect(saved.aria2Gid == "new-gid-123")
    }

    @Test @MainActor
    func downloadWithCustomFilenameAndDirectory() async throws {
        let customDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path()
        let metaService = MockURLMetadataService(filename: "original.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "custom-gid")
        let (vm, repo, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2
        )
        vm.urlText = "https://example.com/original.zip"

        await vm.submitURL()

        vm.editableFilename = "renamed.zip"
        vm.selectedDirectory = customDir

        await vm.startDownload()

        let addCalls = await aria2.recordedAddCalls()
        let call = try #require(addCalls.first)
        #expect(call.outputFileName == "renamed.zip")

        let all = try await repo.fetchAll()
        let saved = try #require(all.first)
        #expect(saved.filename == "renamed.zip")
    }

    @Test @MainActor
    func fallsBackToDownloadsDirectoryWhenSettingsPathIsTemp() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: NSTemporaryDirectory()
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        let expectedDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path()
        #expect(vm.selectedDirectory == expectedDir)
    }

    @Test @MainActor
    func fallsBackToDownloadsDirectoryWhenSettingsPathDoesNotExist() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: "/nonexistent/stale/path/that/does/not/exist"
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        let expectedDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path()
        #expect(vm.selectedDirectory == expectedDir)
    }

    @Test @MainActor
    func filenameWithPathTraversalDisablesDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()
        vm.editableFilename = "../../../etc/passwd"
        #expect(vm.isDownloadEnabled == false)
    }

    @Test @MainActor
    func downloadUsesDefaultSegmentsFromSettings() async throws {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "test-gid")
        let settings = SettingsViewModel()
        settings.defaultSegments = 16
        let repo = InMemoryDownloadRepository()
        let vm = AddDownloadViewModel(
            metadataService: metaService,
            repository: repo,
            aria2: aria2,
            settings: settings,
            diskSpaceProvider: FixedDiskSpaceProvider(availableSpace: 50_000_000_000)
        )

        vm.urlText = "https://example.com/file.zip"
        await vm.submitURL()
        await vm.startDownload()

        let addCalls = await aria2.recordedAddCalls()
        let call = try #require(addCalls.first)
        #expect(call.segments == 16)
    }

    @Test @MainActor
    func startDownloadPassesInterceptedHeaders() async throws {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "header-gid")
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2
        )
        let msg = NativeMessage(
            url: "https://example.com/file.zip",
            headers: ["cookie": "session=abc", "authorization": "Bearer tok"],
            filename: "file.zip",
            fileSize: 1024,
            referrer: "https://example.com/page"
        )
        vm.prefill(message: msg)

        await vm.submitURL()
        await vm.startDownload()

        let addCalls = await aria2.recordedAddCalls()
        let call = try #require(addCalls.first)
        #expect(call.headers["cookie"] == "session=abc")
        #expect(call.headers["authorization"] == "Bearer tok")
        #expect(call.headers["Referer"] == "https://example.com/page")
    }

    @Test @MainActor
    func forceDownloadPassesInterceptedHeaders() async throws {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/file.zip",
            filename: "file.zip",
            fileSize: 1024,
            status: DownloadStatus.completed.rawValue
        )
        try await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "dup-header-gid")
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            repository: repo,
            aria2: aria2
        )

        let msg = NativeMessage(
            url: "https://example.com/file.zip",
            headers: ["cookie": "session=xyz"],
            filename: "file.zip",
            fileSize: 1024,
            referrer: "https://example.com/ref"
        )
        vm.prefill(message: msg)

        await vm.submitURL()
        guard case .duplicateFound = vm.state else {
            Issue.record("Expected .duplicateFound")
            return
        }

        await vm.forceDownload()

        let addCalls = await aria2.recordedAddCalls()
        let call = try #require(addCalls.first)
        #expect(call.headers["cookie"] == "session=xyz")
        #expect(call.headers["Referer"] == "https://example.com/ref")
    }

    @Test @MainActor
    func interceptedFilenameUsedWhenMetadataReturnsGeneric() async {
        let metaService = MockURLMetadataService(filename: "download", fileSize: nil)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService
        )
        let msg = NativeMessage(
            url: "https://example.com/file",
            headers: nil,
            filename: "report.pdf",
            fileSize: 5000,
            referrer: nil
        )
        vm.prefill(message: msg)

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload, got \(vm.state)")
            return
        }
        #expect(vm.editableFilename == "report.pdf")
        #expect(metadata.fileSize == 5000)
    }

    @Test @MainActor
    func metadataFilenamePreferredOverInterceptedWhenNotGeneric() async {
        let metaService = MockURLMetadataService(filename: "server-name.zip", fileSize: 4096)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService
        )
        let msg = NativeMessage(
            url: "https://example.com/server-name.zip",
            headers: nil,
            filename: "browser-name.zip",
            fileSize: 1024,
            referrer: nil
        )
        vm.prefill(message: msg)

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload, got \(vm.state)")
            return
        }
        #expect(vm.editableFilename == "server-name.zip")
        #expect(metadata.fileSize == 4096)
    }

    @Test @MainActor
    func noInterceptedMessagePassesEmptyHeaders() async throws {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "no-headers-gid")
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2
        )
        vm.prefill(url: "https://example.com/file.zip")

        await vm.submitURL()
        await vm.startDownload()

        let addCalls = await aria2.recordedAddCalls()
        let call = try #require(addCalls.first)
        #expect(call.headers.isEmpty)
    }
}
