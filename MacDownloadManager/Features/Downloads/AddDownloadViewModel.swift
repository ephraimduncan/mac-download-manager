import Foundation

protocol DiskSpaceProviding: Sendable {
    func availableDiskSpace(at path: String) -> Int64?
}

struct SystemDiskSpaceProvider: DiskSpaceProviding {
    func availableDiskSpace(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }
}

@Observable @MainActor
final class AddDownloadViewModel {

    // MARK: - State

    enum State: Sendable {
        case idle
        case querying
        case duplicateFound(DownloadRecord)
        case newDownload(URLMetadata)
    }

    private(set) var state: State = .idle
    var urlText: String = ""
    var editableFilename: String = ""

    var selectedDirectory: String = "" {
        didSet {
            refreshDiskSpace()
        }
    }

    private(set) var directoryOptions: [String] = []
    private(set) var availableDiskSpace: Int64?

    var isOKEnabled: Bool {
        guard case .idle = state else { return false }
        return isValidHTTPURL(urlText)
    }

    var isDownloadEnabled: Bool {
        guard case .newDownload = state else { return false }
        return isValidFilename(editableFilename)
            && !selectedDirectory.isEmpty
            && fileManager.isWritableFile(atPath: selectedDirectory)
    }

    // MARK: - Dependencies

    private let metadataService: any URLMetadataService
    private let repository: any DownloadRepository
    private let aria2: any DownloadManagingAria2
    private let settings: SettingsViewModel
    private let notificationService: NotificationService
    private let diskSpaceProvider: any DiskSpaceProviding
    private let fileManager: FileManager

    private var queryGeneration: Int = 0
    private var resolvedMetadata: URLMetadata?
    private var trimmedURLString: String = ""
    private var interceptedMessage: NativeMessage?

    // MARK: - Init

    init(
        metadataService: any URLMetadataService,
        repository: any DownloadRepository,
        aria2: any DownloadManagingAria2,
        settings: SettingsViewModel,
        notificationService: NotificationService = .shared,
        diskSpaceProvider: any DiskSpaceProviding = SystemDiskSpaceProvider(),
        fileManager: FileManager = .default
    ) {
        self.metadataService = metadataService
        self.repository = repository
        self.aria2 = aria2
        self.settings = settings
        self.notificationService = notificationService
        self.diskSpaceProvider = diskSpaceProvider
        self.fileManager = fileManager
    }

    // MARK: - Actions

    func submitURL() async {
        guard case .idle = state else { return }

        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidHTTPURL(trimmed), let url = URL(string: trimmed) else { return }

        trimmedURLString = trimmed
        queryGeneration += 1
        let generation = queryGeneration

        state = .querying

        let metadata = await metadataService.fetchMetadata(for: url)

        guard generation == queryGeneration, case .querying = state else { return }

        resolvedMetadata = metadata

        do {
            if let existing = try await repository.fetchByURL(trimmed) {
                guard generation == queryGeneration, case .querying = state else { return }
                state = .duplicateFound(existing)
                return
            }
        } catch {
        }

        guard generation == queryGeneration, case .querying = state else { return }

        let dir = resolveDefaultDirectory()
        directoryOptions = buildDirectoryOptions(defaultDir: dir)
        selectedDirectory = dir

        var filename = metadata.filename
        var fileSize = metadata.fileSize
        if let msg = interceptedMessage {
            if let msgFilename = msg.filename, !msgFilename.isEmpty, (filename == "download" || filename.isEmpty) {
                filename = sanitizeFilename(msgFilename)
            }
            if fileSize == nil, let msgSize = msg.fileSize, msgSize > 0 {
                fileSize = msgSize
            }
        }
        let enrichedMetadata = URLMetadata(filename: filename, fileSize: fileSize)
        resolvedMetadata = enrichedMetadata

        editableFilename = filename
        state = .newDownload(enrichedMetadata)
    }

    func cancel() {
        queryGeneration += 1
        resetState()
    }

    func skip() {
        resetState()
    }

    func forceDownload() async {
        guard case .duplicateFound = state else { return }

        guard let metadata = resolvedMetadata,
              let url = URL(string: trimmedURLString) else {
            resetState()
            return
        }

        let dir = resolveDefaultDirectory()
        let filename = metadata.filename
        let segments = settings.defaultSegments
        let headers = buildHeaders()

        do {
            let gid = try await aria2.addDownload(
                url: url,
                headers: headers,
                dir: dir,
                segments: segments,
                outputFileName: filename
            )

            var headersJSON: String?
            if !headers.isEmpty, let data = try? JSONEncoder().encode(headers) {
                headersJSON = String(data: data, encoding: .utf8)
            }

            let record = DownloadRecord(
                url: trimmedURLString,
                filename: filename,
                fileSize: metadata.fileSize,
                status: DownloadStatus.downloading.rawValue,
                segments: segments,
                headersJSON: headersJSON,
                filePath: dir,
                aria2Gid: gid
            )

            try await repository.save(record)
            notificationService.postDownloadStarted(filename: filename)
        } catch {}

        resetState()
    }

    func startDownload() async {
        guard case .newDownload = state else { return }

        let sanitizedFilename = sanitizeFilename(editableFilename)
        guard !sanitizedFilename.isEmpty, !selectedDirectory.isEmpty else { return }
        guard fileManager.isWritableFile(atPath: selectedDirectory) else { return }
        guard let url = URL(string: trimmedURLString) else {
            resetState()
            return
        }

        let metadata = resolvedMetadata
        let segments = settings.defaultSegments
        let headers = buildHeaders()

        do {
            let gid = try await aria2.addDownload(
                url: url,
                headers: headers,
                dir: selectedDirectory,
                segments: segments,
                outputFileName: sanitizedFilename
            )

            var headersJSON: String?
            if !headers.isEmpty, let data = try? JSONEncoder().encode(headers) {
                headersJSON = String(data: data, encoding: .utf8)
            }

            let record = DownloadRecord(
                url: trimmedURLString,
                filename: sanitizedFilename,
                fileSize: metadata?.fileSize,
                status: DownloadStatus.downloading.rawValue,
                segments: segments,
                headersJSON: headersJSON,
                filePath: selectedDirectory,
                aria2Gid: gid
            )

            try await repository.save(record)
            notificationService.postDownloadStarted(filename: sanitizedFilename)
        } catch {}

        resetState()
    }

    func prefill(url: String) {
        urlText = url
    }

    func prefill(message: NativeMessage) {
        urlText = message.url
        interceptedMessage = message
    }

    func addBrowsedDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        if !directoryOptions.contains(path) {
            directoryOptions.append(path)
        }
        selectedDirectory = path
    }

    // MARK: - Private

    private func resetState() {
        state = .idle
        urlText = ""
        editableFilename = ""
        selectedDirectory = ""
        directoryOptions = []
        resolvedMetadata = nil
        trimmedURLString = ""
        availableDiskSpace = nil
        interceptedMessage = nil
    }

    private func buildHeaders() -> [String: String] {
        guard let msg = interceptedMessage else { return [:] }
        var headers = msg.headers ?? [:]
        if let referrer = msg.referrer, !referrer.isEmpty {
            headers["Referer"] = referrer
        }
        return headers
    }

    private func buildDirectoryOptions(defaultDir: String) -> [String] {
        var options: [String] = [defaultDir]
        let downloadsDir = URL.downloadsDirectory.path()
        if downloadsDir != defaultDir {
            options.append(downloadsDir)
        }
        return options
    }

    private func resolveDefaultDirectory() -> String {
        let configured = settings.defaultDownloadDir
        guard !configured.isEmpty,
              fileManager.fileExists(atPath: configured) else {
            return URL.downloadsDirectory.path()
        }
        return configured
    }

    private func refreshDiskSpace() {
        guard !selectedDirectory.isEmpty else {
            availableDiskSpace = nil
            return
        }
        availableDiskSpace = diskSpaceProvider.availableDiskSpace(at: selectedDirectory)
    }

    private func isValidHTTPURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed) else { return false }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private func isValidFilename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("/") else { return false }
        guard !trimmed.contains("..") else { return false }
        return true
    }

    private func sanitizeFilename(_ name: String) -> String {
        let basename = (name as NSString).lastPathComponent
        let cleaned = basename
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }
}
