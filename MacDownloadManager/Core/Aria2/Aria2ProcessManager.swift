import Darwin
import Foundation

final class Aria2ProcessManager {
    private var process: Process?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    private var pidFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Mac Download Manager", isDirectory: true)
            .appendingPathComponent("aria2.pid")
    }

    func launch(
        secret: String,
        port: Int,
        downloadDir: String,
        maxConcurrent: Int
    ) throws {
        killStaleProcesses()

        let binaryPath = Self.findBinary()
        guard let binaryPath else {
            throw Aria2Error.processNotRunning
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "--enable-rpc",
            "--rpc-listen-port=\(port)",
            "--rpc-listen-all=false",
            "--rpc-secret=\(secret)",
            "--continue=true",
            "--max-concurrent-downloads=\(maxConcurrent)",
            "--dir=\(downloadDir)",
            "--file-allocation=none",
            "--auto-file-renaming=true"
        ]
        process.standardOutput = nil
        process.standardError = nil

        try process.run()
        self.process = process
        writePidFile(pid: process.processIdentifier)
    }

    private func writePidFile(pid: Int32) {
        let url = pidFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func killStaleProcesses() {
        let url = pidFileURL
        guard
            let contents = try? String(contentsOf: url, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }

        Darwin.kill(pid, SIGTERM)
        removePidFile()
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
        removePidFile()
    }

    private static func findBinary() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("aria2c")
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        let candidates = [
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c"
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
