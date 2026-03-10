import Foundation

/// Provides available disk space for a given directory path. Abstracted for testability.
protocol DiskSpaceProviding: Sendable {
    func availableDiskSpace(at path: String) -> Int64?
}

/// Default implementation using FileManager.
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

    /// URL text binding for the input field.
    var urlText: String = ""

    /// Editable filename for the new download dialog.
    var editableFilename: String = ""

    /// Selected download directory.
    var selectedDirectory: String = "" {
        didSet {
            refreshDiskSpace()
        }
    }

    /// Directory options for the Picker dropdown.
    private(set) var directoryOptions: [String] = []

    /// Available disk space for the selected directory.
    private(set) var availableDiskSpace: Int64?

    /// Whether the OK button should be enabled (valid URL in idle state).
    var isOKEnabled: Bool {
        guard case .idle = state else { return false }
        return isValidHTTPURL(urlText)
    }

    /// Whether the DOWNLOAD button should be enabled in new download state.
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
    private let diskSpaceProvider: any DiskSpaceProviding
    private let fileManager: FileManager

    /// Tracks the current query task for cancellation.
    private var currentQueryTask: Task<Void, Never>?

    /// Generation counter to ignore late completions after cancel.
    private var queryGeneration: Int = 0

    /// Cached metadata from the HEAD request, used when starting a download.
    private var resolvedMetadata: URLMetadata?

    /// The trimmed URL string used for the current flow.
    private var trimmedURLString: String = ""

    // MARK: - Init

    init(
        metadataService: any URLMetadataService,
        repository: any DownloadRepository,
        aria2: any DownloadManagingAria2,
        settings: SettingsViewModel,
        diskSpaceProvider: any DiskSpaceProviding = SystemDiskSpaceProvider(),
        fileManager: FileManager = .default
    ) {
        self.metadataService = metadataService
        self.repository = repository
        self.aria2 = aria2
        self.settings = settings
        self.diskSpaceProvider = diskSpaceProvider
        self.fileManager = fileManager
    }

    // MARK: - Actions

    /// Submit the URL (OK button action). Transitions idle -> querying -> duplicateFound or newDownload.
    func submitURL() async {
        // Only allow submission from idle state (idempotent during querying)
        guard case .idle = state else { return }

        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidHTTPURL(trimmed), let url = URL(string: trimmed) else { return }

        trimmedURLString = trimmed
        queryGeneration += 1
        let generation = queryGeneration

        state = .querying

        // Fetch metadata
        let metadata = await metadataService.fetchMetadata(for: url)

        // Check if cancelled (generation changed)
        guard generation == queryGeneration else { return }
        guard case .querying = state else { return }

        resolvedMetadata = metadata

        // Check for duplicate
        do {
            if let existing = try await repository.fetchByURL(trimmed) {
                // Guard again after async call
                guard generation == queryGeneration, case .querying = state else { return }
                state = .duplicateFound(existing)
                return
            }
        } catch {
            // Proceed to new download if lookup fails
        }

        // Guard again after async call
        guard generation == queryGeneration, case .querying = state else { return }

        // Transition to new download
        let dir = resolveDefaultDirectory()
        directoryOptions = buildDirectoryOptions(defaultDir: dir)
        selectedDirectory = dir
        editableFilename = metadata.filename
        state = .newDownload(metadata)
    }

    /// Cancel from any state. Clears all transient state and returns to idle.
    func cancel() {
        queryGeneration += 1
        currentQueryTask?.cancel()
        currentQueryTask = nil
        resetState()
    }

    /// Skip a duplicate (dismiss without action).
    func skip() {
        resetState()
    }

    /// Force download from duplicate state (creates new record without mutating existing).
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

        do {
            let gid = try await aria2.addDownload(
                url: url,
                headers: [:],
                dir: dir,
                segments: segments,
                outputFileName: filename
            )

            let record = DownloadRecord(
                url: trimmedURLString,
                filename: filename,
                fileSize: metadata.fileSize,
                status: DownloadStatus.downloading.rawValue,
                segments: segments,
                filePath: dir,
                aria2Gid: gid
            )

            try await repository.save(record)
        } catch {
            // Best effort - still reset state
        }

        resetState()
    }

    /// Start a new download from the new download state.
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

        do {
            let gid = try await aria2.addDownload(
                url: url,
                headers: [:],
                dir: selectedDirectory,
                segments: segments,
                outputFileName: sanitizedFilename
            )

            let record = DownloadRecord(
                url: trimmedURLString,
                filename: sanitizedFilename,
                fileSize: metadata?.fileSize,
                status: DownloadStatus.downloading.rawValue,
                segments: segments,
                filePath: selectedDirectory,
                aria2Gid: gid
            )

            try await repository.save(record)
        } catch {
            // Best effort - still reset state
        }

        resetState()
    }

    /// Adds a new directory option to the Picker dropdown and selects it.
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
    }

    /// Builds the initial list of directory options, including the default dir and ~/Downloads.
    private func buildDirectoryOptions(defaultDir: String) -> [String] {
        var options: [String] = []
        options.append(defaultDir)
        let downloadsDir = URL.downloadsDirectory.path()
        if downloadsDir != defaultDir {
            options.append(downloadsDir)
        }
        return options
    }

    private func resolveDefaultDirectory() -> String {
        URL.downloadsDirectory.path()
    }

    private func refreshDiskSpace() {
        guard !selectedDirectory.isEmpty else {
            availableDiskSpace = nil
            return
        }
        availableDiskSpace = diskSpaceProvider.availableDiskSpace(at: selectedDirectory)
    }

    /// Validates that the given string is a valid http/https URL with a non-empty host.
    private func isValidHTTPURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed) else { return false }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Validates a filename is non-empty, has no path separators, and no traversal.
    private func isValidFilename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("/") else { return false }
        guard !trimmed.contains("..") else { return false }
        return true
    }

    /// Sanitizes a filename to a safe basename.
    private func sanitizeFilename(_ name: String) -> String {
        let basename = (name as NSString).lastPathComponent
        let cleaned = basename
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }
}
