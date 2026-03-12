import Foundation
import Testing

@testable import Mac_Download_Manager

// MARK: - Mock URLMetadataService

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

// MARK: - Disk Space Provider

private struct FixedDiskSpaceProvider: DiskSpaceProviding {
    var availableSpace: Int64?

    func availableDiskSpace(at path: String) -> Int64? {
        availableSpace
    }
}

// MARK: - Tests

@Suite("AddDownloadViewModel")
struct AddDownloadViewModelTests {

    // MARK: - Helpers

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

    // MARK: VAL-ADD-001: Initial modal state

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

    // MARK: VAL-ADD-002: URL validation enables OK

    @Test @MainActor
    func validHTTPURLEnablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "https://example.com/file.zip"
        #expect(vm.isOKEnabled == true)
    }

    @Test @MainActor
    func validHTTPSchemeEnablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "http://example.com/file.zip"
        #expect(vm.isOKEnabled == true)
    }

    @Test @MainActor
    func emptyURLDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = ""
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func whitespaceOnlyURLDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "   "
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func missingSchemeDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "example.com/file.zip"
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func nonHTTPSchemeDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "ftp://example.com/file.zip"
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func schemeOnlyHTTPSURLDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "https://"
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func schemeOnlyHTTPURLDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "http://"
        #expect(vm.isOKEnabled == false)
    }

    @Test @MainActor
    func malformedURLDisablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "not a url at all"
        #expect(vm.isOKEnabled == false)
    }

    // MARK: VAL-ADD-003: Whitespace trimming and propagation

    @Test @MainActor
    func whitespaceAroundValidURLIsTrimmedAndEnablesOK() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "  https://example.com/file.zip  "
        #expect(vm.isOKEnabled == true)
    }

    @Test @MainActor
    func trimmedURLUsedForHeadRequest() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "  https://example.com/file.zip  "

        await vm.submitURL()

        let count = await metaService.getFetchCount()
        #expect(count == 1)
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

    // MARK: VAL-ADD-004: Cancel dismisses without action

    @Test @MainActor
    func cancelFromIdleClearsState() {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "https://example.com/file.zip"
        vm.cancel()
        guard case .idle = vm.state else {
            Issue.record("Expected .idle state after cancel")
            return
        }
        #expect(vm.urlText == "")
    }

    // MARK: VAL-ADD-005: OK transitions to querying state

    @Test @MainActor
    func submitURLTransitionsToQueryingState() async {
        let metaService = MockURLMetadataService(
            filename: "file.zip",
            fileSize: 1024,
            delay: .milliseconds(500)
        )
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        let task = Task { @MainActor in
            await vm.submitURL()
        }

        try? await Task.sleep(for: .milliseconds(50))

        guard case .querying = vm.state else {
            Issue.record("Expected .querying state, got \(vm.state)")
            task.cancel()
            return
        }

        task.cancel()
    }

    // MARK: VAL-QUERY-001: Loading state properties

    @Test @MainActor
    func queryingStateExistsDuringMetadataFetch() async {
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
        guard case .querying = vm.state else {
            Issue.record("Expected .querying state during HEAD request, got \(vm.state)")
            task.cancel()
            return
        }

        task.cancel()
    }

    // MARK: VAL-QUERY-006: Cancel during querying aborts cleanly

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

    // MARK: VAL-QUERY-007: Querying completes to duplicate check or new download

    @Test @MainActor
    func queryingTransitionsToNewDownloadWhenNoDuplicate() async {
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
    }

    @Test @MainActor
    func queryingTransitionsToDuplicateFoundWhenExists() async {
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
        #expect(record.filename == "existing.zip")
    }

    // MARK: VAL-QUERY-008: No duplicate submissions during querying

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

    // MARK: VAL-DUP-001: Duplicate detection trigger

    @Test @MainActor
    func duplicateDetectionUsesExactURLMatch() async {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/file.zip",
            filename: "file.zip",
            status: DownloadStatus.completed.rawValue
        )
        try! await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService, repository: repo)

        vm.urlText = "https://example.com/file.zip?v=2"
        await vm.submitURL()

        guard case .newDownload = vm.state else {
            Issue.record("Expected .newDownload for different URL, got \(vm.state)")
            return
        }
    }

    // MARK: VAL-DUP-003: SKIP dismisses without adding

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

    // MARK: VAL-DUP-004: DOWNLOAD forces a new download

    @Test @MainActor
    func downloadFromDuplicateCreatesNewRecordWithoutMutatingExisting() async throws {
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
            aria2: aria2,
            defaultDownloadDir: NSTemporaryDirectory()
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
        #expect(original?.filePath == "/original/path")

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.count == 1)
    }

    // MARK: VAL-DUP-005: Close/X behaves like SKIP

    @Test @MainActor
    func cancelFromDuplicateBehavesLikeSkip() async {
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
        vm.cancel()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after cancel from duplicate, got \(vm.state)")
            return
        }

        let all = try! await repoUsed.fetchAll()
        #expect(all.count == 1)
    }

    // MARK: VAL-NEW-001: Pre-filled filename from metadata

    @Test @MainActor
    func newDownloadPreFillsFilenameFromMetadata() async {
        let metaService = MockURLMetadataService(filename: "report.pdf", fileSize: 5000)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/report.pdf"

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload, got \(vm.state)")
            return
        }
        #expect(vm.editableFilename == "report.pdf")
        #expect(metadata.fileSize == 5000)
    }

    // MARK: VAL-NEW-002: Editable filename field

    @Test @MainActor
    func editableFilenameCanBeModified() async {
        let metaService = MockURLMetadataService(filename: "original.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/original.zip"

        await vm.submitURL()

        vm.editableFilename = "custom-name.zip"
        #expect(vm.editableFilename == "custom-name.zip")
        #expect(vm.isDownloadEnabled == true)
    }

    @Test @MainActor
    func emptyFilenameDisablesDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        vm.editableFilename = ""
        #expect(vm.isDownloadEnabled == false)
    }

    @Test @MainActor
    func whitespaceOnlyFilenameDisablesDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        vm.editableFilename = "   "
        #expect(vm.isDownloadEnabled == false)
    }

    // MARK: VAL-NEW-004: Default directory from settings

    @Test @MainActor
    func defaultDirectoryFromSettings() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: NSTemporaryDirectory()
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        #expect(vm.selectedDirectory == NSTemporaryDirectory())
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
    func fallsBackToDownloadsDirectoryWhenSettingsEmpty() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: ""
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        let expectedDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path()
        #expect(vm.selectedDirectory == expectedDir)
    }

    // MARK: VAL-NEW-005: File size and disk space display

    @Test @MainActor
    func fileSizeFromMetadataIsAvailable() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 5_000_000)
        let dsp = FixedDiskSpaceProvider(availableSpace: 100_000_000_000)
        let (vm, _, _) = makeViewModel(metadataService: metaService, diskSpaceProvider: dsp)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload")
            return
        }
        #expect(metadata.fileSize == 5_000_000)
        #expect(vm.availableDiskSpace != nil)
        #expect(vm.availableDiskSpace == 100_000_000_000)
    }

    @Test @MainActor
    func nilFileSizeWhenMetadataHasNoSize() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: nil)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload")
            return
        }
        #expect(metadata.fileSize == nil)
    }

    // MARK: VAL-NEW-006: Cancel dismisses without downloading

    @Test @MainActor
    func cancelFromNewDownloadDoesNotStartDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "test-gid")
        let (vm, _, _) = makeViewModel(metadataService: metaService, aria2: aria2)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()
        vm.cancel()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after cancel from new download")
            return
        }

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.isEmpty)
    }

    // MARK: VAL-NEW-007: DOWNLOAD starts the download

    @Test @MainActor
    func downloadInitiatesAria2AndSavesRecord() async throws {
        let tmpDir = NSTemporaryDirectory()
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "new-gid-123")
        let (vm, repo, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2,
            defaultDownloadDir: tmpDir
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        guard case .newDownload = vm.state else {
            Issue.record("Expected .newDownload")
            return
        }

        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after download, got \(vm.state)")
            return
        }

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.count == 1)
        let call = try #require(addCalls.first)
        #expect(call.url == URL(string: "https://example.com/file.zip"))
        #expect(call.dir == tmpDir)
        #expect(call.outputFileName == "file.zip")

        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        let saved = try #require(all.first)
        #expect(saved.url == "https://example.com/file.zip")
        #expect(saved.filename == "file.zip")
        #expect(saved.filePath == tmpDir)
        #expect(saved.aria2Gid == "new-gid-123")
    }

    @Test @MainActor
    func downloadWithCustomFilenameAndDirectory() async throws {
        let tmpDir = NSTemporaryDirectory()
        let metaService = MockURLMetadataService(filename: "original.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "custom-gid")
        let (vm, repo, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2,
            defaultDownloadDir: tmpDir
        )
        vm.urlText = "https://example.com/original.zip"

        await vm.submitURL()

        vm.editableFilename = "renamed.zip"
        vm.selectedDirectory = tmpDir

        await vm.startDownload()

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.count == 1)
        let call = try #require(addCalls.first)
        #expect(call.dir == tmpDir)
        #expect(call.outputFileName == "renamed.zip")

        let all = try await repo.fetchAll()
        let saved = try #require(all.first)
        #expect(saved.filename == "renamed.zip")
        #expect(saved.filePath == tmpDir)
    }

    // MARK: VAL-NEW-008: Directory change updates disk space

    @Test @MainActor
    func directoryChangeUpdatesDiskSpace() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let dsp = FixedDiskSpaceProvider(availableSpace: 100_000_000_000)
        let (vm, _, _) = makeViewModel(metadataService: metaService, diskSpaceProvider: dsp)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        #expect(vm.availableDiskSpace == 100_000_000_000)

        vm.selectedDirectory = "/new/dir"
        #expect(vm.availableDiskSpace == 100_000_000_000) // same fixed value from provider
    }

    // MARK: VAL-NEW-010: Filename sanitization

    @Test @MainActor
    func filenameWithPathSeparatorsIsSanitized() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "test-gid")
        let (vm, _, _) = makeViewModel(metadataService: metaService, aria2: aria2)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        vm.editableFilename = "../../../etc/passwd"

        #expect(vm.isDownloadEnabled == false)
    }

    @Test @MainActor
    func filenameWithSlashesIsSanitized() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        vm.editableFilename = "path/to/file.zip"
        #expect(vm.isDownloadEnabled == false)
    }

    // MARK: VAL-NEW-011: Invalid directory validation

    @Test @MainActor
    func unwritableDirectoryDisablesDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        vm.selectedDirectory = "/usr/bin"
        #expect(vm.isDownloadEnabled == false)
    }

    @Test @MainActor
    func unwritableDirectoryBlocksStartDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "test-gid")
        let (vm, repo, _) = makeViewModel(metadataService: metaService, aria2: aria2)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        vm.selectedDirectory = "/usr/bin"

        await vm.startDownload()

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.isEmpty)

        let all = try! await repo.fetchAll()
        #expect(all.isEmpty)
    }

    @Test @MainActor
    func emptyDirectoryDisablesDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()

        vm.selectedDirectory = ""
        #expect(vm.isDownloadEnabled == false)
    }

    // MARK: VAL-CROSS-001: Full new download flow

    @Test @MainActor
    func fullNewDownloadFlow() async throws {
        let tmpDir = NSTemporaryDirectory()
        let metaService = MockURLMetadataService(filename: "app.dmg", fileSize: 50_000_000)
        let aria2 = MockAria2Controller(addResult: "cross-gid")
        let dsp = FixedDiskSpaceProvider(availableSpace: 100_000_000_000)
        let (vm, repo, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2,
            defaultDownloadDir: tmpDir,
            diskSpaceProvider: dsp
        )

        vm.urlText = "https://example.com/app.dmg"
        #expect(vm.isOKEnabled == true)

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload, got \(vm.state)")
            return
        }
        #expect(metadata.filename == "app.dmg")
        #expect(metadata.fileSize == 50_000_000)
        #expect(vm.editableFilename == "app.dmg")
        #expect(vm.selectedDirectory == tmpDir)
        #expect(vm.availableDiskSpace == 100_000_000_000)

        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after download")
            return
        }
        #expect(vm.urlText == "")
        #expect(vm.editableFilename == "")

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.count == 1)

        let all = try await repo.fetchAll()
        #expect(all.count == 1)
    }

    // MARK: VAL-CROSS-002: Full duplicate detection flow

    @Test @MainActor
    func fullDuplicateDetectionFlow() async {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/dup.zip",
            filename: "dup.zip",
            fileSize: 2048,
            status: DownloadStatus.completed.rawValue,
            filePath: "/existing/path"
        )
        try! await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "dup.zip", fileSize: 2048)
        let (vm, repoUsed, _) = makeViewModel(metadataService: metaService, repository: repo)

        vm.urlText = "https://example.com/dup.zip"
        #expect(vm.isOKEnabled == true)

        await vm.submitURL()

        guard case .duplicateFound(let record) = vm.state else {
            Issue.record("Expected .duplicateFound, got \(vm.state)")
            return
        }
        #expect(record.url == "https://example.com/dup.zip")
        #expect(record.filename == "dup.zip")

        vm.skip()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after skip")
            return
        }

        let all = try! await repoUsed.fetchAll()
        #expect(all.count == 1)
    }

    // MARK: VAL-CROSS-003: Full duplicate force-download flow

    @Test @MainActor
    func fullDuplicateForceDownloadFlow() async throws {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/dup.zip",
            filename: "dup.zip",
            fileSize: 2048,
            status: DownloadStatus.completed.rawValue,
            filePath: "/existing/path"
        )
        try await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "dup.zip", fileSize: 2048)
        let aria2 = MockAria2Controller(addResult: "dup-force-gid")
        let (vm, repoUsed, _) = makeViewModel(
            metadataService: metaService,
            repository: repo,
            aria2: aria2,
            defaultDownloadDir: NSTemporaryDirectory()
        )

        vm.urlText = "https://example.com/dup.zip"
        await vm.submitURL()

        guard case .duplicateFound = vm.state else {
            Issue.record("Expected .duplicateFound")
            return
        }

        await vm.forceDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after force download")
            return
        }

        let all = try await repoUsed.fetchAll()
        #expect(all.count == 2)

        let original = try await repoUsed.fetch(id: existingRecord.id)
        #expect(original?.status == DownloadStatus.completed.rawValue)

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.count == 1)
    }

    // MARK: VAL-CROSS-004: HEAD failure fallback flow

    @Test @MainActor
    func headFailureFallbackFlow() async throws {
        let tmpDir = NSTemporaryDirectory()
        let metaService = MockURLMetadataService(filename: "large.iso", fileSize: nil)
        let aria2 = MockAria2Controller(addResult: "fallback-gid")
        let (vm, repo, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2,
            defaultDownloadDir: tmpDir
        )

        vm.urlText = "https://example.com/files/large.iso"
        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload for fallback")
            return
        }
        #expect(metadata.filename == "large.iso")
        #expect(metadata.fileSize == nil)

        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after download")
            return
        }

        let addCalls = await aria2.recordedAddCalls()
        #expect(addCalls.count == 1)

        let all = try await repo.fetchAll()
        #expect(all.count == 1)
    }

    // MARK: VAL-CROSS-006: Clean state reset after terminal actions

    @Test @MainActor
    func stateResetAfterCancel() async {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "https://example.com/file.zip"
        vm.cancel()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle")
            return
        }
        #expect(vm.urlText == "")
        #expect(vm.editableFilename == "")
    }

    @Test @MainActor
    func stateResetAfterSkip() async {
        let repo = InMemoryDownloadRepository()
        let existingRecord = DownloadRecord(
            url: "https://example.com/file.zip",
            filename: "file.zip",
            status: DownloadStatus.completed.rawValue
        )
        try! await repo.save(existingRecord)

        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(metadataService: metaService, repository: repo)
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()
        vm.skip()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after skip")
            return
        }
        #expect(vm.urlText == "")
        #expect(vm.editableFilename == "")
    }

    @Test @MainActor
    func stateResetAfterDownload() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: NSTemporaryDirectory()
        )
        vm.urlText = "https://example.com/file.zip"

        await vm.submitURL()
        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after download")
            return
        }
        #expect(vm.urlText == "")
        #expect(vm.editableFilename == "")
    }

    @Test @MainActor
    func reopeningAfterTerminalActionStartsFresh() async {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: NSTemporaryDirectory()
        )

        vm.urlText = "https://example.com/file.zip"
        await vm.submitURL()
        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle")
            return
        }
        #expect(vm.urlText == "")
        #expect(vm.editableFilename == "")
        #expect(vm.isOKEnabled == false)
    }

    // MARK: - Additional edge cases

    @Test @MainActor
    func submitURLWithInvalidURLDoesNothing() async {
        let (vm, _, _) = makeViewModel()
        vm.urlText = "not-a-url"
        await vm.submitURL()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle for invalid URL submit")
            return
        }
    }

    @Test @MainActor
    func downloadUsesDefaultSegmentsFromSettings() async throws {
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "test-gid")
        let settings = SettingsViewModel()
        settings.defaultSegments = 16
        settings.defaultDownloadDir = NSTemporaryDirectory()

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

    // MARK: - Intercepted message prefill tests

    @Test @MainActor
    func prefillMessageSetsURLText() {
        let (vm, _, _) = makeViewModel()
        let msg = NativeMessage(
            url: "https://example.com/file.zip",
            headers: ["cookie": "session=abc"],
            filename: "file.zip",
            fileSize: 1024,
            referrer: "https://example.com/"
        )
        vm.prefill(message: msg)
        #expect(vm.urlText == "https://example.com/file.zip")
    }

    @Test @MainActor
    func startDownloadPassesInterceptedHeaders() async throws {
        let tmpDir = NSTemporaryDirectory()
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "header-gid")
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2,
            defaultDownloadDir: tmpDir
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
            aria2: aria2,
            defaultDownloadDir: NSTemporaryDirectory()
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
            metadataService: metaService,
            defaultDownloadDir: NSTemporaryDirectory()
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
    func interceptedFileSizeUsedWhenMetadataHasNoSize() async {
        let metaService = MockURLMetadataService(filename: "doc.pdf", fileSize: nil)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: NSTemporaryDirectory()
        )
        let msg = NativeMessage(
            url: "https://example.com/doc.pdf",
            headers: nil,
            filename: nil,
            fileSize: 2048,
            referrer: nil
        )
        vm.prefill(message: msg)

        await vm.submitURL()

        guard case .newDownload(let metadata) = vm.state else {
            Issue.record("Expected .newDownload, got \(vm.state)")
            return
        }
        #expect(metadata.fileSize == 2048)
    }

    @Test @MainActor
    func metadataFilenamePreferredOverInterceptedWhenNotGeneric() async {
        let metaService = MockURLMetadataService(filename: "server-name.zip", fileSize: 4096)
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            defaultDownloadDir: NSTemporaryDirectory()
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
        let tmpDir = NSTemporaryDirectory()
        let metaService = MockURLMetadataService(filename: "file.zip", fileSize: 1024)
        let aria2 = MockAria2Controller(addResult: "no-headers-gid")
        let (vm, _, _) = makeViewModel(
            metadataService: metaService,
            aria2: aria2,
            defaultDownloadDir: tmpDir
        )
        vm.prefill(url: "https://example.com/file.zip")

        await vm.submitURL()
        await vm.startDownload()

        let addCalls = await aria2.recordedAddCalls()
        let call = try #require(addCalls.first)
        #expect(call.headers.isEmpty)
    }
}
