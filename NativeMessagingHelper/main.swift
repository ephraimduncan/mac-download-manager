import AppKit
import Foundation

let socketPath = NSHomeDirectory() + "/Library/Application Support/Mac Download Manager/helper.sock"
let appBundleId = "com.macdownloadmanager.app"

let logDir = NSHomeDirectory() + "/Library/Logs/Mac Download Manager"
let logPath = logDir + "/helper.log"

let logMaxBytes: UInt64 = 5 * 1024 * 1024  // 5 MB
let logMaxBackups = 3

func rotateLogs() {
    let fm = FileManager.default
    // Remove the oldest backup if it exists, then shift each backup up by one.
    for i in stride(from: logMaxBackups - 1, through: 1, by: -1) {
        let src = logPath + ".\(i)"
        let dst = logPath + ".\(i + 1)"
        if fm.fileExists(atPath: src) {
            try? fm.removeItem(atPath: dst)
            try? fm.moveItem(atPath: src, toPath: dst)
        }
    }
    try? fm.moveItem(atPath: logPath, toPath: logPath + ".1")
}

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    if !FileManager.default.fileExists(atPath: logDir) {
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? UInt64, size >= logMaxBytes {
        rotateLogs()
    }
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

func readNativeMessage(from handle: FileHandle) -> Data? {
    let lengthData = handle.readData(ofLength: 4)
    guard lengthData.count == 4 else { return nil }

    let length = lengthData.withUnsafeBytes {
        UInt32(littleEndian: $0.load(as: UInt32.self))
    }

    guard length > 0, length < 10_000_000 else { return nil }

    let payload = handle.readData(ofLength: Int(length))
    guard payload.count == Int(length) else { return nil }
    return payload
}

func writeNativeMessage(_ data: Data, to handle: FileHandle) {
    var length = UInt32(data.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    handle.write(header)
    handle.write(data)
}

func readSocketFrame(fd: Int32) -> Data? {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    guard readExact(fd: fd, buffer: &lengthBytes, count: 4) else { return nil }

    let length = Int(lengthBytes.withUnsafeBufferPointer {
        UInt32(bigEndian: $0.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
    })

    guard length > 0, length < 10_000_000 else { return nil }

    var payload = [UInt8](repeating: 0, count: length)
    guard readExact(fd: fd, buffer: &payload, count: length) else { return nil }
    return Data(payload)
}

@discardableResult
func writeSocketFrame(_ data: Data, to fd: Int32) -> Bool {
    var length = UInt32(data.count).bigEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(data)
    return frame.withUnsafeBytes { ptr in
        var offset = 0
        while offset < ptr.count {
            let n = send(fd, ptr.baseAddress! + offset, ptr.count - offset, 0)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

func readExact(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
    buffer.withUnsafeMutableBytes { ptr in
        var offset = 0
        while offset < count {
            let n = recv(fd, ptr.baseAddress! + offset, count - offset, 0)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

func connectToSocket() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        log("connectToSocket: socket() failed, errno=\(errno)")
        return -1
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            for (i, byte) in pathBytes.enumerated() {
                dest[i] = byte
            }
        }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let result = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result != 0 {
        log("connectToSocket: connect() failed, errno=\(errno)")
        close(fd)
        return -1
    }
    log("connectToSocket: connected, fd=\(fd)")
    return fd
}

func writeErrorResponse(_ message: String) {
    struct ErrorResponse: Codable {
        let accepted: Bool
        let error: String
    }
    let response = ErrorResponse(accepted: false, error: message)
    if let data = try? JSONEncoder().encode(response) {
        writeNativeMessage(data, to: FileHandle.standardOutput)
    }
}

func launchAppIfNeeded() {
    let workspace = NSWorkspace.shared
    let myPID = ProcessInfo.processInfo.processIdentifier
    let appRunning = workspace.runningApplications.contains(where: {
        $0.bundleIdentifier == appBundleId && $0.processIdentifier != myPID
    })
    if appRunning {
        log("launchAppIfNeeded: app already running (excluding self pid=\(myPID))")
        return
    }
    guard let appURL = workspace.urlForApplication(withBundleIdentifier: appBundleId) else {
        log("launchAppIfNeeded: app not found for bundle ID \(appBundleId)")
        return
    }
    log("launchAppIfNeeded: launching \(appURL.path)")
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    workspace.openApplication(at: appURL, configuration: config, completionHandler: nil)
}

nonisolated(unsafe) var activeSocketSource: DispatchSourceRead?

func startSocketReader(fd: Int32) {
    let socketSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    activeSocketSource = socketSource
    socketSource.setEventHandler {
        guard let data = readSocketFrame(fd: fd) else {
            log("startSocketReader: read failed, cancelling source for fd=\(fd)")
            socketSource.cancel()
            return
        }
        log("startSocketReader: forwarding \(data.count) bytes to stdout")
        writeNativeMessage(data, to: FileHandle.standardOutput)
    }
    socketSource.setCancelHandler {
        log("startSocketReader: cancel handler, closing fd=\(fd)")
        close(fd)
        socketFD = -1
        activeSocketSource = nil
    }
    socketSource.resume()
    log("startSocketReader: listening on fd=\(fd)")
}

nonisolated(unsafe) var socketFD: Int32 = -1
nonisolated(unsafe) var pendingMessages: [Data] = []
nonisolated(unsafe) var reconnecting = false

func startReconnection() {
    if reconnecting {
        log("startReconnection: already reconnecting, skipping")
        return
    }
    reconnecting = true
    log("startReconnection: beginning reconnection")

    var retryCount = 0
    let retryTimer = DispatchSource.makeTimerSource(queue: .main)
    retryTimer.schedule(deadline: .now() + 1, repeating: 1.0)
    retryTimer.setEventHandler {
        retryCount += 1
        log("startReconnection: attempt \(retryCount)/10")
        launchAppIfNeeded()
        let fd = connectToSocket()
        if fd >= 0 {
            socketFD = fd
            startSocketReader(fd: fd)
            log("startReconnection: flushing \(pendingMessages.count) pending messages")
            for msg in pendingMessages {
                writeSocketFrame(msg, to: fd)
            }
            pendingMessages.removeAll()
            reconnecting = false
            retryTimer.cancel()
        } else if retryCount >= 10 {
            log("startReconnection: exhausted retries, dropping \(pendingMessages.count) messages")
            for _ in pendingMessages {
                writeErrorResponse("Mac Download Manager is not running")
            }
            pendingMessages.removeAll()
            reconnecting = false
            retryTimer.cancel()
        }
    }
    retryTimer.resume()
}

log("Helper started, pid=\(ProcessInfo.processInfo.processIdentifier)")

let initialFD = connectToSocket()
if initialFD >= 0 {
    socketFD = initialFD
    startSocketReader(fd: initialFD)
} else {
    log("Initial connection failed, will reconnect when a message arrives")
}

let stdinSource = DispatchSource.makeReadSource(fileDescriptor: FileHandle.standardInput.fileDescriptor, queue: .main)
stdinSource.setEventHandler {
    guard let data = readNativeMessage(from: FileHandle.standardInput) else {
        log("stdin: read failed (browser disconnected), exiting")
        stdinSource.cancel()
        if let source = activeSocketSource { source.cancel() }
        exit(0)
    }

    log("stdin: received \(data.count) bytes from browser")

    if socketFD >= 0 {
        if !writeSocketFrame(data, to: socketFD) {
            log("stdin: writeSocketFrame failed, cancelling socket source")
            activeSocketSource?.cancel()
            pendingMessages.append(data)
        }
    } else {
        log("stdin: no socket connection, queuing message (pending=\(pendingMessages.count + 1))")
        pendingMessages.append(data)
        startReconnection()
    }
}
stdinSource.setCancelHandler {
    log("stdin: cancel handler, exiting")
    if let source = activeSocketSource { source.cancel() }
    exit(0)
}
stdinSource.resume()

dispatchMain()
