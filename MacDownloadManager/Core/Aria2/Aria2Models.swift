import Foundation

struct Aria2Request<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: Params
}

struct Aria2Response<Result: Decodable>: Decodable {
    let id: String
    let result: Result?
    let error: Aria2RPCError?
}

struct Aria2RPCError: Decodable {
    let code: Int
    let message: String
}

struct Aria2Status: Decodable, Sendable {
    let gid: String
    let status: String
    let totalLength: String
    let completedLength: String
    let downloadSpeed: String
    let files: [Aria2File]?
    let errorCode: String?
    let errorMessage: String?
    /// When aria2 finishes fetching torrent metadata it creates the real torrent
    /// download and adds its GID here on the metadata-fetch entry.
    let followedBy: [String]?

    var totalBytes: Int64 { Int64(totalLength) ?? 0 }
    var completedBytes: Int64 { Int64(completedLength) ?? 0 }
    var speedBytesPerSec: Int64 { Int64(downloadSpeed) ?? 0 }
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(completedBytes) / Double(totalBytes)
    }
}

struct Aria2File: Decodable, Sendable {
    let index: String
    let path: String
    let length: String
    let completedLength: String
    let uris: [Aria2Uri]?
}

struct Aria2Uri: Decodable, Sendable {
    let uri: String
    let status: String
}

struct Aria2GlobalStat: Decodable, Sendable {
    let downloadSpeed: String
    let uploadSpeed: String
    let numActive: String
    let numWaiting: String
    let numStopped: String
    let numStoppedTotal: String
}

typealias Aria2TokenParams = [String]
typealias Aria2AddUriParams = [AnyCodable]
typealias Aria2GidParams = [String]
typealias Aria2TellStoppedParams = [AnyCodable]

struct AnyCodable: Encodable, Sendable {
    private let encodeFunc: @Sendable (inout SingleValueEncodingContainer) throws -> Void

    init(_ encodeFunc: @escaping @Sendable (inout SingleValueEncodingContainer) throws -> Void) {
        self.encodeFunc = encodeFunc
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try encodeFunc(&container)
    }

    static func string(_ value: String) -> AnyCodable {
        AnyCodable { try $0.encode(value) }
    }

    static func int(_ value: Int) -> AnyCodable {
        AnyCodable { try $0.encode(value) }
    }

    static func bool(_ value: Bool) -> AnyCodable {
        AnyCodable { try $0.encode(value) }
    }

    static func stringArray(_ value: [String]) -> AnyCodable {
        AnyCodable { try $0.encode(value) }
    }

    static func dict(_ value: [String: String]) -> AnyCodable {
        AnyCodable { try $0.encode(value) }
    }

    static func mixedDict(_ value: [String: AnyCodable]) -> AnyCodable {
        AnyCodable { try $0.encode(value) }
    }

    static func array(_ value: [AnyCodable]) -> AnyCodable {
        AnyCodable { try $0.encode(value) }
    }
}
