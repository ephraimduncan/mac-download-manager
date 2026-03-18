import Darwin
import Foundation

enum Aria2Error: Error, Sendable {
    case processNotRunning
    case connectionFailed(underlying: any Error)
    case invalidResponse(Data)
    case rpcError(code: Int, message: String)
    case requestFailed(statusCode: Int)
    case encodingFailed
    case pidFileWriteFailed(path: String, errno: Int32)
    case staleProcessCleanupFailed(pid: Int32)
}

extension Aria2Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .processNotRunning: "aria2c is not running"
        case .connectionFailed(let e): "Connection to aria2c failed: \(e.localizedDescription)"
        case .invalidResponse: "Invalid response from aria2c"
        case .rpcError(_, let msg): msg
        case .requestFailed(let s): "HTTP \(s) from aria2c"
        case .encodingFailed: "Failed to encode request"
        case .pidFileWriteFailed(let path, let errno):
            "Failed to write aria2c PID file at \(path): \(String(cString: strerror(errno))) (errno \(errno))"
        case .staleProcessCleanupFailed(let pid):
            "Failed to clean up stale aria2c process (PID \(pid)); aborting launch to avoid port conflicts"
        }
    }
}
