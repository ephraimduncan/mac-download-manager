import Foundation

struct URLMetadata: Sendable, Equatable {
    let filename: String
    let fileSize: Int64?
}

protocol URLMetadataService: Sendable {
    func fetchMetadata(for url: URL) async -> URLMetadata
}

protocol HTTPHeadClient: Sendable {
    func head(url: URL, timeoutInterval: TimeInterval) async throws -> (httpResponse: HTTPURLResponse, data: Data)
}

struct URLSessionHeadClient: HTTPHeadClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func head(url: URL, timeoutInterval: TimeInterval) async throws -> (httpResponse: HTTPURLResponse, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeoutInterval
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (httpResponse, data)
    }
}

final class DefaultURLMetadataService: URLMetadataService {
    private let client: HTTPHeadClient
    static let requestTimeout: TimeInterval = 10

    init(client: HTTPHeadClient = URLSessionHeadClient()) {
        self.client = client
    }

    func fetchMetadata(for url: URL) async -> URLMetadata {
        do {
            let (httpResponse, _) = try await client.head(
                url: url,
                timeoutInterval: Self.requestTimeout
            )

            guard (200..<400).contains(httpResponse.statusCode) else {
                return fallbackMetadata(for: url)
            }

            let filename = resolveFilename(from: httpResponse, url: url)
            let fileSize = parseContentLength(from: httpResponse)
            return URLMetadata(filename: filename, fileSize: fileSize)
        } catch {
            return fallbackMetadata(for: url)
        }
    }

    private func fallbackMetadata(for url: URL) -> URLMetadata {
        URLMetadata(filename: sanitizeFilename(url.suggestedFilename), fileSize: nil)
    }

    private func resolveFilename(from response: HTTPURLResponse, url: URL) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition") {
            if let name = parseContentDisposition(disposition) {
                return sanitizeFilename(name)
            }
        }
        return sanitizeFilename(url.suggestedFilename)
    }

    private func parseContentDisposition(_ value: String) -> String? {
        let parts = value.components(separatedBy: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        // RFC 5987
        for part in parts {
            if part.lowercased().hasPrefix("filename*=") {
                let raw = String(part.dropFirst("filename*=".count))
                if let decoded = decodeRFC5987(raw) {
                    let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }

        for part in parts {
            if part.lowercased().hasPrefix("filename=") {
                let raw = String(part.dropFirst("filename=".count))
                let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    .removingPercentEncoding ?? raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                let trimmed = unquoted.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    private func decodeRFC5987(_ value: String) -> String? {
        let components = value.split(
            separator: "'",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return nil }

        let encoded = String(components[2])
        return encoded.removingPercentEncoding
    }

    private func parseContentLength(from response: HTTPURLResponse) -> Int64? {
        guard let lengthString = response.value(forHTTPHeaderField: "Content-Length") else {
            return nil
        }
        guard let length = Int64(lengthString), length >= 0 else {
            return nil
        }
        return length
    }

    private func sanitizeFilename(_ name: String) -> String {
        // Normalize backslash separators to forward slashes so NSString.lastPathComponent
        // correctly handles Windows-style paths like '..\..\secret.txt'
        let normalized = name.replacingOccurrences(of: "\\", with: "/")

        let basename = (normalized as NSString).lastPathComponent

        let cleaned = basename
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            return "download"
        }
        return cleaned
    }
}
