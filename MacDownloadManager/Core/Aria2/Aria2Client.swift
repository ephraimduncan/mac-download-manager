import Foundation

protocol DownloadManagingAria2: Actor {
    func addDownload(
        url: URL,
        headers: [String: String],
        dir: String,
        segments: Int,
        outputFileName: String?
    ) async throws(Aria2Error) -> String
    func pause(gid: String) async throws(Aria2Error)
    func pauseAll() async throws(Aria2Error)
    func resume(gid: String) async throws(Aria2Error)
    func forceRemove(gid: String) async throws(Aria2Error)
    func removeDownloadResult(gid: String) async throws(Aria2Error)
    func tellActive() async throws(Aria2Error) -> [Aria2Status]
    func tellWaiting(offset: Int, count: Int) async throws(Aria2Error) -> [Aria2Status]
    func tellStopped(offset: Int, count: Int) async throws(Aria2Error) -> [Aria2Status]
}

actor Aria2Client: DownloadManagingAria2 {
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    private var requestId: Int = 0

    init(port: Int, secret: String) {
        self.baseURL = URL(string: "http://localhost:\(port)/jsonrpc")!
        self.secret = secret
        self.session = URLSession(configuration: .ephemeral)
    }

    func addDownload(
        url: URL,
        headers: [String: String] = [:],
        dir: String,
        segments: Int = 16,
        outputFileName: String? = nil
    ) async throws(Aria2Error) -> String {
        var options: [String: AnyCodable] = [
            "split": .string("\(segments)"),
            "max-connection-per-server": .string("\(segments)"),
            "dir": .string(dir)
        ]

        if let filename = outputFileName ?? extractFilename(from: url) {
            options["out"] = .string(filename)
        }

        if !headers.isEmpty {
            let headerStrings = headers.map { "\($0.key): \($0.value)" }
            options["header"] = .stringArray(headerStrings)
        }

        let params: [AnyCodable] = [
            .string(tokenParam),
            .stringArray([url.absoluteString]),
            .mixedDict(options)
        ]

        return try await call(method: "aria2.addUri", params: params)
    }

    func pause(gid: String) async throws(Aria2Error) {
        let _: String = try await call(
            method: "aria2.forcePause",
            params: [tokenParam, gid]
        )
    }

    func pauseAll() async throws(Aria2Error) {
        let _: String = try await call(
            method: "aria2.forcePauseAll",
            params: [tokenParam]
        )
    }

    func resume(gid: String) async throws(Aria2Error) {
        let _: String = try await call(
            method: "aria2.unpause",
            params: [tokenParam, gid]
        )
    }

    func remove(gid: String) async throws(Aria2Error) {
        let _: String = try await call(
            method: "aria2.remove",
            params: [tokenParam, gid]
        )
    }

    func forceRemove(gid: String) async throws(Aria2Error) {
        let _: String = try await call(
            method: "aria2.forceRemove",
            params: [tokenParam, gid]
        )
    }

    func removeDownloadResult(gid: String) async throws(Aria2Error) {
        let _: String = try await call(
            method: "aria2.removeDownloadResult",
            params: [tokenParam, gid]
        )
    }

    func tellActive() async throws(Aria2Error) -> [Aria2Status] {
        try await call(
            method: "aria2.tellActive",
            params: [tokenParam]
        )
    }

    func tellWaiting(offset: Int, count: Int) async throws(Aria2Error) -> [Aria2Status] {
        let params: [AnyCodable] = [.string(tokenParam), .int(offset), .int(count)]
        return try await call(method: "aria2.tellWaiting", params: params)
    }

    func tellStopped(offset: Int, count: Int) async throws(Aria2Error) -> [Aria2Status] {
        let params: [AnyCodable] = [.string(tokenParam), .int(offset), .int(count)]
        return try await call(method: "aria2.tellStopped", params: params)
    }

    func getGlobalStat() async throws(Aria2Error) -> Aria2GlobalStat {
        try await call(
            method: "aria2.getGlobalStat",
            params: [tokenParam]
        )
    }

    func changeGlobalOption(options: [String: String]) async throws(Aria2Error) {
        let params: [AnyCodable] = [.string(tokenParam), .dict(options)]
        let _: String = try await call(method: "aria2.changeGlobalOption", params: params)
    }

    private var tokenParam: String { "token:\(secret)" }

    private func nextRequestId() -> String {
        requestId += 1
        return "mac-dl-\(requestId)"
    }

    private func call<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params
    ) async throws(Aria2Error) -> Result {
        let rpcRequest = Aria2Request(
            id: nextRequestId(),
            method: method,
            params: params
        )

        let body: Data
        do {
            body = try JSONEncoder().encode(rpcRequest)
        } catch {
            throw .encodingFailed
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .connectionFailed(underlying: error)
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw .requestFailed(statusCode: httpResponse.statusCode)
        }

        let decoded: Aria2Response<Result>
        do {
            decoded = try JSONDecoder().decode(Aria2Response<Result>.self, from: data)
        } catch {
            throw .invalidResponse(data)
        }

        if let rpcError = decoded.error {
            throw .rpcError(code: rpcError.code, message: rpcError.message)
        }

        guard let result = decoded.result else {
            throw .invalidResponse(data)
        }

        return result
    }

    private func extractFilename(from url: URL) -> String? {
        let name = url.suggestedFilename
        guard name != "download" else { return nil }
        return name
    }
}
