import AppKit
import Foundation

let socketPath = NSHomeDirectory() + "/Library/Application Support/Mac Download Manager/helper.sock"
let appBundleId = "com.macdownloadmanager.app"

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

func writeSocketFrame(_ data: Data, to fd: Int32) {
    var length = UInt32(data.count).bigEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(data)
    frame.withUnsafeBytes { ptr in
        var offset = 0
        while offset < ptr.count {
            let n = send(fd, ptr.baseAddress! + offset, ptr.count - offset, 0)
            if n <= 0 { break }
            offset += n
        }
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
    guard fd >= 0 else { return -1 }

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
        close(fd)
        return -1
    }
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
    if workspace.runningApplications.contains(where: { $0.bundleIdentifier == appBundleId }) {
        return
    }
    guard let appURL = workspace.urlForApplication(withBundleIdentifier: appBundleId) else {
        return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    workspace.openApplication(at: appURL, configuration: config, completionHandler: nil)
}

func startSocketReader(fd: Int32) {
    let socketSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    socketSource.setEventHandler {
        guard let data = readSocketFrame(fd: fd) else {
            socketSource.cancel()
            return
        }
        writeNativeMessage(data, to: FileHandle.standardOutput)
    }
    socketSource.setCancelHandler {
        close(fd)
    }
    socketSource.resume()
}

nonisolated(unsafe) var socketFD = connectToSocket()
nonisolated(unsafe) var pendingMessages: [Data] = []

if socketFD < 0 {
    launchAppIfNeeded()

    var retryCount = 0
    let retryTimer = DispatchSource.makeTimerSource(queue: .main)
    retryTimer.schedule(deadline: .now() + 1, repeating: 1.0)
    retryTimer.setEventHandler {
        retryCount += 1
        let fd = connectToSocket()
        if fd >= 0 {
            socketFD = fd
            startSocketReader(fd: fd)
            for msg in pendingMessages {
                writeSocketFrame(msg, to: fd)
            }
            pendingMessages.removeAll()
            retryTimer.cancel()
        } else if retryCount >= 10 {
            for _ in pendingMessages {
                writeErrorResponse("Mac Download Manager is not running")
            }
            pendingMessages.removeAll()
            retryTimer.cancel()
            exit(1)
        }
    }
    retryTimer.resume()
} else {
    startSocketReader(fd: socketFD)
}

let stdinSource = DispatchSource.makeReadSource(fileDescriptor: FileHandle.standardInput.fileDescriptor, queue: .main)
stdinSource.setEventHandler {
    guard let data = readNativeMessage(from: FileHandle.standardInput) else {
        stdinSource.cancel()
        if socketFD >= 0 { close(socketFD) }
        exit(0)
        return
    }

    if socketFD >= 0 {
        writeSocketFrame(data, to: socketFD)
    } else {
        pendingMessages.append(data)
    }
}
stdinSource.setCancelHandler {
    if socketFD >= 0 { close(socketFD) }
    exit(0)
}
stdinSource.resume()

dispatchMain()
