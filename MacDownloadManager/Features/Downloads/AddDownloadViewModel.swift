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

    enum State: Sendable {
        case idle
        case querying
        case duplicateFound(DownloadRecord)
        case newDownload(URLMetadata)
    }

    private(set) var state: State = .idle
    var urlText: String = ""
    private(set) var localMetalinkFileURL: URL?
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
        directoryOptions = await buildDirectoryOptions(defaultDir: dir)
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

        if let metalinkURL = localMetalinkFileURL {
            let data: Data
            do {
                // Read off the main actor to avoid blocking the UI thread
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: metalinkURL)
                }.value
            } catch {
                resetState()
                return
            }
            do {
                let gids = try await aria2.addMetalink(data: data, dir: selectedDirectory)
                for gid in gids {
                    let record = DownloadRecord(
                        url: metalinkURL.absoluteString,
                        filename: sanitizedFilename,
                        fileSize: nil,
                        status: DownloadStatus.downloading.rawValue,
                        segments: settings.defaultSegments,
                        headersJSON: nil,
                        filePath: selectedDirectory,
                        aria2Gid: gid
                    )
                    try await repository.save(record)
                }
                if !gids.isEmpty {
                    notificationService.postDownloadStarted(filename: sanitizedFilename)
                }
            } catch {}
            resetState()
            return
        }

        guard let url = URL(string: trimmedURLString) else {
            resetState()
            return
        }

        // Remote .meta4 / .metalink: fetch the XML ourselves then hand it to aria2
        if url.isMetalinkURL {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let gids = try await aria2.addMetalink(data: data, dir: selectedDirectory)
                for gid in gids {
                    let record = DownloadRecord(
                        url: trimmedURLString,
                        filename: sanitizedFilename,
                        fileSize: nil,
                        status: DownloadStatus.downloading.rawValue,
                        segments: settings.defaultSegments,
                        headersJSON: nil,
                        filePath: selectedDirectory,
                        aria2Gid: gid
                    )
                    try await repository.save(record)
                }
                if !gids.isEmpty {
                    notificationService.postDownloadStarted(filename: sanitizedFilename)
                }
            } catch {}
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

    func prefillMetalinkFile(at url: URL) async {
        localMetalinkFileURL = url
        let displayName = url.deletingPathExtension().lastPathComponent
        let name = sanitizeFilename(displayName.isEmpty ? "download" : displayName)
        let dir = resolveDefaultDirectory()
        directoryOptions = await buildDirectoryOptions(defaultDir: dir)
        selectedDirectory = dir
        refreshDiskSpace()
        editableFilename = name
        state = .newDownload(URLMetadata(filename: name, fileSize: nil))
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

    private func resetState() {
        state = .idle
        urlText = ""
        localMetalinkFileURL = nil
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

    private func buildDirectoryOptions(defaultDir: String) async -> [String] {
        var options: [String] = [defaultDir]
        let downloadsDir = URL.downloadsDirectory.path()
        if downloadsDir != defaultDir, !options.contains(downloadsDir) {
            options.insert(downloadsDir, at: 0)
        }

        let recentDirs = await recentDownloadDirectories()
        for dir in recentDirs where !options.contains(dir) {
            options.append(dir)
        }
        return options
    }

    private func recentDownloadDirectories() async -> [String] {
        guard let records = try? await repository.fetchAll() else { return [] }
        var seen = Set<String>()
        var dirs: [String] = []
        for record in records.reversed() {
            guard let path = record.filePath,
                  !path.isEmpty,
                  !isTemporaryPath(path),
                  !seen.contains(path),
                  fileManager.fileExists(atPath: path) else { continue }
            seen.insert(path)
            dirs.append(path)
            if dirs.count >= 5 { break }
        }
        return dirs
    }

    private func resolveDefaultDirectory() -> String {
        let configured = settings.defaultDownloadDir
        guard !configured.isEmpty,
              fileManager.fileExists(atPath: configured),
              !isTemporaryPath(configured) else {
            return URL.downloadsDirectory.path()
        }
        return configured
    }

    private func isTemporaryPath(_ path: String) -> Bool {
        path.hasPrefix("/var/") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/")
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
