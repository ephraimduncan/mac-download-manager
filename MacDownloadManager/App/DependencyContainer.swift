import SwiftUI

struct MenuBarDownload: Identifiable, Sendable {
    let id: String
    var filename: String
    var progress: Double
    var speed: Int64
    var gid: String
    var status: String
}

struct PendingExtensionDownload: Equatable {
    let id: UUID
    let message: NativeMessage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

@Observable @MainActor
final class DependencyContainer {
    static var shared: DependencyContainer!

    let databaseManager: DatabaseManager
    let repository: any DownloadRepository
    let aria2Client: Aria2Client
    let processManager: Aria2ProcessManager
    let socketServer: SocketServer
    let settingsViewModel: SettingsViewModel
    let notificationService: NotificationService

    let aria2Secret: String
    let aria2Port: Int

    var activeDownloadCount: Int = 0
    var menuBarDownloads: [MenuBarDownload] = []
    var globalDownloadSpeed: Int64 = 0
    var pendingExtensionDownload: PendingExtensionDownload?
    var openMainWindow: (() -> Void)?

    var menuBarIcon: String {
        activeDownloadCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle"
    }

    init() {
        aria2Secret = UUID().uuidString
        aria2Port = 6800

        databaseManager = try! DatabaseManager()
        repository = GRDBDownloadRepository(dbQueue: databaseManager.dbQueue)

        aria2Client = Aria2Client(port: 6800, secret: aria2Secret)
        processManager = Aria2ProcessManager()
        socketServer = SocketServer()
        settingsViewModel = SettingsViewModel(aria2: aria2Client)
        notificationService = NotificationService.shared
    }

    init(inMemory: Bool) {
        aria2Secret = "test"
        aria2Port = 6800
        databaseManager = try! DatabaseManager(inMemory: true)
        repository = InMemoryDownloadRepository()
        aria2Client = Aria2Client(port: 6800, secret: "test")
        processManager = Aria2ProcessManager()
        socketServer = SocketServer()
        settingsViewModel = SettingsViewModel(aria2: aria2Client)
        notificationService = NotificationService.shared
    }
}
