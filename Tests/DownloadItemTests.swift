import Foundation
import Testing
@testable import Mac_Download_Manager

@Suite
struct DownloadItemTests {
    @Test func etaCalculation() {
        let item = DownloadItem(
            url: URL(string: "https://example.com/file.zip")!,
            filename: "file.zip",
            fileSize: 1000,
            downloadedSize: 500,
            speed: 100,
            status: .downloading
        )

        #expect(item.eta == 5.0)
    }

    @Test func etaNilWhenNoSpeed() {
        let item = DownloadItem(
            url: URL(string: "https://example.com/file.zip")!,
            filename: "file.zip",
            fileSize: 1000,
            downloadedSize: 500,
            speed: 0,
            status: .downloading
        )

        #expect(item.eta == nil)
    }

    @Test func isActive() {
        let downloading = DownloadItem(
            url: URL(string: "https://example.com/a")!,
            filename: "a",
            status: .downloading
        )
        let waiting = DownloadItem(
            url: URL(string: "https://example.com/b")!,
            filename: "b",
            status: .waiting
        )
        let completed = DownloadItem(
            url: URL(string: "https://example.com/c")!,
            filename: "c",
            status: .completed
        )

        #expect(downloading.isActive)
        #expect(waiting.isActive)
        #expect(!completed.isActive)
    }

    @Test func initFromRecord() {
        let record = DownloadRecord(
            url: "https://example.com/file.zip",
            filename: "file.zip",
            fileSize: 2048,
            progress: 0.5,
            status: DownloadStatus.downloading.rawValue,
            segments: 16,
            aria2Gid: "gid123"
        )

        let item = DownloadItem(record: record)
        #expect(item.filename == "file.zip")
        #expect(item.fileSize == 2048)
        #expect(item.progress == 0.5)
        #expect(item.status == .downloading)
        #expect(item.segments == 16)
        #expect(item.aria2Gid == "gid123")
    }


}
