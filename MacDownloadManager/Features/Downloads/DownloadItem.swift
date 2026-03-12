import Foundation

struct DownloadItem: Identifiable, Sendable, Equatable {
    let id: UUID
    var url: URL
    var filename: String
    var fileSize: Int64?
    var downloadedSize: Int64
    var progress: Double
    var speed: Int64
    var status: DownloadStatus
    var segments: Int
    var headers: [String: String]
    var createdAt: Date
    var completedAt: Date?
    var filePath: String?
    var aria2Gid: String?

    var eta: TimeInterval? {
        guard speed > 0, let fileSize, fileSize > downloadedSize else { return nil }
        return TimeInterval(fileSize - downloadedSize) / TimeInterval(speed)
    }

    var isActive: Bool {
        status == .downloading || status == .waiting
    }

    var fileSizeForSort: Int64 {
        fileSize ?? 0
    }

    var statusLabel: String {
        switch status {
        case .waiting: "Waiting"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .error: "Error"
        case .removed: "Removed"
        }
    }

    init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        fileSize: Int64? = nil,
        downloadedSize: Int64 = 0,
        progress: Double = 0,
        speed: Int64 = 0,
        status: DownloadStatus = .waiting,
        segments: Int = 8,
        headers: [String: String] = [:],
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        filePath: String? = nil,
        aria2Gid: String? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.fileSize = fileSize
        self.downloadedSize = downloadedSize
        self.progress = progress
        self.speed = speed
        self.status = status
        self.segments = segments
        self.headers = headers
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.filePath = filePath
        self.aria2Gid = aria2Gid
    }

    init(record: DownloadRecord) {
        let parsedURL = URL(string: record.url)
        self.id = record.id
        self.url = parsedURL ?? URL(string: "about:blank")!
        self.filename = record.filename
        self.fileSize = record.fileSize
        self.downloadedSize = Int64(record.progress * Double(record.fileSize ?? 0))
        self.progress = record.progress
        self.speed = 0
        self.status = parsedURL != nil
            ? (DownloadStatus(rawValue: record.status) ?? .error)
            : .error
        self.segments = record.segments
        self.headers = record.headers
        self.createdAt = record.createdAt
        self.completedAt = record.completedAt
        self.filePath = record.filePath
        self.aria2Gid = record.aria2Gid
    }
}

enum DownloadStatus: String, Codable, Sendable, CaseIterable, Comparable {
    case downloading, waiting, paused, completed, error, removed

    private var sortIndex: Int {
        switch self {
        case .downloading: 0
        case .waiting: 1
        case .paused: 2
        case .completed: 3
        case .error: 4
        case .removed: 5
        }
    }

    static func < (lhs: DownloadStatus, rhs: DownloadStatus) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }
}

enum FilterOption: String, CaseIterable, Sendable {
    case all, active, completed, paused

    var displayName: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .completed: "Completed"
        case .paused: "Paused"
        }
    }
}
