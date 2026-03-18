import Darwin
import Foundation

actor Aria2ProcessManager {
    private var process: Process?
    private let pidFileURL: URL

    init(pidFileURL: URL? = nil) {
        if let pidFileURL {
            self.pidFileURL = pidFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
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
    ) async throws {
        try await killStaleProcesses()

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
        let pid = process.processIdentifier
        let pidURL = pidFileURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.writePidFile(at: pidURL, pid: pid)
            }.value
        } catch {
            let wrapper = SendableProcess(process)
            Task.detached(priority: .utility) {
                wrapper.process.terminate()
                wrapper.process.waitUntilExit()
            }
            throw error
        }
        self.process = process
    }

    // nonisolated so it can be called synchronously from the terminationHandler closure.
    nonisolated private func removePidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func killStaleProcesses() async throws {
        let pidURL = pidFileURL
        try await Task.detached(priority: .userInitiated) {
            try Self.killStaleProcessesSync(pidFileURL: pidURL)
        }.value
    }

    func terminate() async {
        guard let process, process.isRunning else { return }
        let wrapper = SendableProcess(process)
        await Task.detached(priority: .userInitiated) {
            wrapper.process.terminate()
            wrapper.process.waitUntilExit()
        }.value
        if self.process === wrapper.process {
            self.process = nil
        }
    }

    private static func writePidFile(at url: URL, pid: Int32) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw Aria2Error.pidFileWriteFailed(path: url.path, errno: Darwin.errno)
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        let lockDeadline = Date().addingTimeInterval(1)
        var locked = false
        while Date() < lockDeadline {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            guard errno == EWOULDBLOCK else { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard locked else {
            throw Aria2Error.pidFileWriteFailed(path: url.path, errno: Darwin.errno)
        }
        guard ftruncate(fd, 0) == 0 else {
            throw Aria2Error.pidFileWriteFailed(path: url.path, errno: Darwin.errno)
        }
        let content = "\(pid)"
        try content.withCString { ptr in
            let total = strlen(ptr)
            var written = 0
            while written < total {
                let n = write(fd, ptr + written, total - written)
                guard n > 0 else { throw Aria2Error.pidFileWriteFailed(path: url.path, errno: Darwin.errno) }
                written += n
            }
        }
    }

    private static func killStaleProcessesSync(pidFileURL: URL) throws {
        let path = pidFileURL.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        let lockDeadline = Date().addingTimeInterval(1)
        var locked = false
        while Date() < lockDeadline {
            if flock(fd, LOCK_SH | LOCK_NB) == 0 {
                locked = true
                break
            }
            guard errno == EWOULDBLOCK else { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard locked else { return }
        var buffer = [CChar](repeating: 0, count: 32)
        guard read(fd, &buffer, buffer.count - 1) > 0 else { return }
        let contents = String(cString: buffer)
        guard let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        guard isAria2Process(pid: pid) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }
        let killResult = Darwin.kill(pid, SIGTERM)
        guard killResult == 0 || errno == ESRCH else {
            throw Aria2Error.staleProcessCleanupFailed(pid: pid)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !isAria2Process(pid: pid) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isAria2Process(pid: pid) {
            Darwin.kill(pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while Date() < killDeadline {
                if !isAria2Process(pid: pid) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !isAria2Process(pid: pid) else {
                throw Aria2Error.staleProcessCleanupFailed(pid: pid)
            }
        }
        try? FileManager.default.removeItem(at: pidFileURL)
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

// Process is not Sendable, so wrap it to safely cross concurrency boundaries.
private final class SendableProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
