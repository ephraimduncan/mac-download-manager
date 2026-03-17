import Darwin
import Foundation

final class Aria2ProcessManager {
    private var process: Process?
    private let pidFileURL: URL

    init(pidFileURL: URL? = nil) {
        if let pidFileURL {
            self.pidFileURL = pidFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.pidFileURL = appSupport
                .appendingPathComponent("Mac Download Manager", isDirectory: true)
                .appendingPathComponent("aria2.pid")
        }
    }

    var isRunning: Bool {
        process?.isRunning ?? false
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
        process.terminationHandler = { [weak self] _ in
            self?.removePidFile()
        }

        try process.run()
        do {
            try writePidFile(pid: process.processIdentifier)
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        self.process = process
    }

    private func writePidFile(pid: Int32) throws {
        let url = pidFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw Aria2Error.pidFileWriteFailed
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        guard flock(fd, LOCK_EX) == 0 else {
            throw Aria2Error.pidFileWriteFailed
        }
        guard ftruncate(fd, 0) == 0 else {
            throw Aria2Error.pidFileWriteFailed
        }
        let content = "\(pid)"
        try content.withCString { ptr in
            let total = strlen(ptr)
            var written = 0
            while written < total {
                let n = write(fd, ptr + written, total - written)
                guard n > 0 else { throw Aria2Error.pidFileWriteFailed }
                written += n
            }
        }
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func killStaleProcesses() {
        let path = pidFileURL.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_SH)
        var buffer = [CChar](repeating: 0, count: 32)
        guard read(fd, &buffer, buffer.count - 1) > 0 else { return }
        let contents = String(cString: buffer)
        guard let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        guard Self.isAria2Process(pid: pid) else {
            removePidFile()
            return
        }
        let killResult = Darwin.kill(pid, SIGTERM)
        guard killResult == 0 || errno == ESRCH else { return }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !Self.isAria2Process(pid: pid) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        removePidFile()
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        self.process = nil
        process.terminate()
        // terminationHandler removes the PID file once the process has exited
    }

    private static func isAria2Process(pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return false }
        let path = String(cString: buffer)
        return path.hasSuffix("/aria2c") || path == "aria2c"
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
