import Foundation
import Testing

@testable import Mac_Download_Manager

@Suite("MetalinkSupport")
struct MetalinkSupportTests {

    // MARK: - URL.isMetalinkURL

    @Test
    func isMetalinkURLTrueForMeta4() {
        let url = URL(string: "https://example.com/ubuntu.meta4")!
        #expect(url.isMetalinkURL == true)
    }

    @Test
    func isMetalinkURLTrueForMetalink() {
        let url = URL(string: "https://example.com/ubuntu.metalink")!
        #expect(url.isMetalinkURL == true)
    }

    @Test
    func isMetalinkURLFalseForZip() {
        let url = URL(string: "https://example.com/file.zip")!
        #expect(url.isMetalinkURL == false)
    }

    @Test
    func isMetalinkURLCaseInsensitive() {
        let url = URL(fileURLWithPath: "/tmp/FILE.META4")
        #expect(url.isMetalinkURL == true)
    }

    // MARK: - URLMetadataService skips HEAD for metalink

    @Test
    func fetchMetadataReturnsFallbackForMeta4WithoutNetworkCall() async {
        let service = DefaultURLMetadataService(client: FailingHeadClient())
        let url = URL(string: "https://example.com/file.meta4")!
        let metadata = await service.fetchMetadata(for: url)
        // Extension is stripped by URLMetadataService.fallbackMetadata
        #expect(metadata.filename == "file")
        #expect(metadata.fileSize == nil)
    }

    @Test
    func fetchMetadataReturnsFallbackForMetalinkWithoutNetworkCall() async {
        let service = DefaultURLMetadataService(client: FailingHeadClient())
        let url = URL(string: "https://example.com/file.metalink")!
        let metadata = await service.fetchMetadata(for: url)
        // Extension is stripped by URLMetadataService.fallbackMetadata
        #expect(metadata.filename == "file")
        #expect(metadata.fileSize == nil)
    }

    // MARK: - AddDownloadViewModel: prefillMetalinkFile

    @MainActor
    private func makeViewModel(aria2: MockAria2Controller? = nil) -> (AddDownloadViewModel, InMemoryDownloadRepository, MockAria2Controller) {
        let repo = InMemoryDownloadRepository()
        let aria = aria2 ?? MockAria2Controller(addResult: "metalink-gid")
        let settings = SettingsViewModel()
        let vm = AddDownloadViewModel(
            metadataService: DefaultURLMetadataService(),
            repository: repo,
            aria2: aria,
            settings: settings
        )
        return (vm, repo, aria)
    }

    @Test @MainActor
    func prefillMetalinkFileTransitionsToNewDownload() async {
        let (vm, _, _) = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/ubuntu.meta4")
        await vm.prefillMetalinkFile(at: url)
        guard case .newDownload = vm.state else {
            Issue.record("Expected .newDownload, got \(vm.state)")
            return
        }
    }

    @Test @MainActor
    func prefillMetalinkFileDerivesFilenameWithoutExtension() async {
        let (vm, _, _) = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/ubuntu-22.04.meta4")
        await vm.prefillMetalinkFile(at: url)
        #expect(vm.editableFilename == "ubuntu-22.04")
    }

    @Test @MainActor
    func prefillMetalinkFileStoresLocalURL() async {
        let (vm, _, _) = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/test.meta4")
        await vm.prefillMetalinkFile(at: url)
        #expect(vm.localMetalinkFileURL == url)
    }

    @Test @MainActor
    func cancelAfterPrefillClearsLocalMetalinkURL() async {
        let (vm, _, _) = makeViewModel()
        let url = URL(fileURLWithPath: "/tmp/test.meta4")
        await vm.prefillMetalinkFile(at: url)
        vm.cancel()
        #expect(vm.localMetalinkFileURL == nil)
        guard case .idle = vm.state else {
            Issue.record("Expected .idle after cancel, got \(vm.state)")
            return
        }
    }

    // MARK: - startDownload with local metalink file

    @Test @MainActor
    func startDownloadWithLocalMetalinkCreatesRecordPerGID() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let metalinkURL = tmpDir.appendingPathComponent(UUID().uuidString + ".meta4")
        let xmlContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="test.iso">
            <url>https://example.com/test.iso</url>
          </file>
        </metalink>
        """
        try xmlContent.write(to: metalinkURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: metalinkURL) }

        let aria2 = MockAria2Controller(addResult: "m-gid-1")
        let (vm, repo, _) = makeViewModel(aria2: aria2)

        await vm.prefillMetalinkFile(at: metalinkURL)
        vm.selectedDirectory = tmpDir.path

        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after startDownload, got \(vm.state)")
            return
        }

        let records = try await repo.fetchAll()
        #expect(records.count == 1)
        let saved = try #require(records.first)
        #expect(saved.aria2Gid == "m-gid-1")
        #expect(saved.url == metalinkURL.absoluteString)
    }

    @Test @MainActor
    func startDownloadWithEmptyGIDsDoesNotCreateRecords() async throws {
        // aria2 returning an empty GID array should not save any records
        // and should not fire a "Download started" notification.
        let tmpDir = FileManager.default.temporaryDirectory
        let metalinkURL = tmpDir.appendingPathComponent(UUID().uuidString + ".meta4")
        let xmlContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="test.iso">
            <url>https://example.com/test.iso</url>
          </file>
        </metalink>
        """
        try xmlContent.write(to: metalinkURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: metalinkURL) }

        let aria2 = MockAria2Controller(addResult: "ignored", metalinkAddResult: [])
        let (vm, repo, _) = makeViewModel(aria2: aria2)

        await vm.prefillMetalinkFile(at: metalinkURL)
        vm.selectedDirectory = tmpDir.path

        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle, got \(vm.state)")
            return
        }
        let records = try await repo.fetchAll()
        #expect(records.isEmpty, "No records should be saved when aria2 returns zero GIDs")
    }

    @Test @MainActor
    func startDownloadWithUnreadableMetalinkFileResetsState() async {
        let (vm, repo, _) = makeViewModel()
        let nonExistentURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID()).meta4")

        await vm.prefillMetalinkFile(at: nonExistentURL)
        vm.selectedDirectory = FileManager.default.temporaryDirectory.path

        await vm.startDownload()

        guard case .idle = vm.state else {
            Issue.record("Expected .idle after failed read, got \(vm.state)")
            return
        }
        let records = try? await repo.fetchAll()
        #expect((records ?? []).isEmpty)
    }
}

// Stub HEAD client that always throws, used to verify metalink URLs skip network I/O.
private struct FailingHeadClient: HTTPHeadClient {
    func head(url: URL, timeoutInterval: TimeInterval) async throws -> (httpResponse: HTTPURLResponse, data: Data) {
        throw URLError(.notConnectedToInternet)
    }
}
