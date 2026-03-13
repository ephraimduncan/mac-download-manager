import Foundation
import Testing

@testable import Mac_Download_Manager

private struct MockHTTPHeadClient: HTTPHeadClient {
    var result: @Sendable (URL, TimeInterval) throws -> (httpResponse: HTTPURLResponse, data: Data)

    func head(url: URL, timeoutInterval: TimeInterval) async throws -> (httpResponse: HTTPURLResponse, data: Data) {
        try result(url, timeoutInterval)
    }
}

private func makeResponse(
    url: URL,
    statusCode: Int = 200,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

private func makeClient(
    url: URL,
    statusCode: Int = 200,
    headers: [String: String] = [:]
) -> MockHTTPHeadClient {
    MockHTTPHeadClient { requestURL, _ in
        (makeResponse(url: requestURL, statusCode: statusCode, headers: headers), Data())
    }
}

private func makeErrorClient(error: Error) -> MockHTTPHeadClient {
    MockHTTPHeadClient { _, _ in throw error }
}

private final class CapturedValues: @unchecked Sendable {
    var timeout: TimeInterval?
}

@Suite("URLMetadataService")
struct URLMetadataServiceTests {

    @Test
    func parsesContentDispositionQuotedFilename() async {
        let url = URL(string: "https://example.com/download")!
        let client = makeClient(url: url, headers: [
            "Content-Disposition": "attachment; filename=\"my document.pdf\"",
            "Content-Length": "5000",
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.filename == "my document.pdf")
        #expect(metadata.fileSize == 5000)
    }

    @Test
    func filenameStarTakesPriorityOverFilename() async {
        let url = URL(string: "https://example.com/download")!
        let client = makeClient(url: url, headers: [
            "Content-Disposition": "attachment; filename=\"fallback.pdf\"; filename*=UTF-8''preferred.pdf"
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.filename == "preferred.pdf")
    }

    @Test
    func fallsBackToURLFilenameWhenNoContentDisposition() async {
        let url = URL(string: "https://example.com/files/archive.zip")!
        let client = makeClient(url: url, headers: [
            "Content-Length": "1024"
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.filename == "archive.zip")
        #expect(metadata.fileSize == 1024)
    }

    @Test
    func nilFileSizeForMissingContentLength() async {
        let url = URL(string: "https://example.com/file.zip")!
        let client = makeClient(url: url, headers: [:])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.fileSize == nil)
    }

    @Test
    func nilFileSizeForInvalidContentLength() async {
        let url = URL(string: "https://example.com/file.zip")!
        let client = makeClient(url: url, headers: [
            "Content-Length": "not-a-number"
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.fileSize == nil)
    }

    @Test
    func returnsFallbackOnNetworkError() async {
        let url = URL(string: "https://example.com/files/report.pdf")!
        let client = makeErrorClient(error: URLError(.notConnectedToInternet))
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.filename == "report.pdf")
        #expect(metadata.fileSize == nil)
    }

    @Test
    func returnsFallbackOnHTTPErrorStatus() async {
        let url = URL(string: "https://example.com/files/secret.zip")!
        let client = makeClient(url: url, statusCode: 403)
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.filename == "secret.zip")
        #expect(metadata.fileSize == nil)
    }

    @Test
    func clientReceivesCorrectTimeout() async {
        let url = URL(string: "https://example.com/file.zip")!
        let captured = CapturedValues()
        let client = MockHTTPHeadClient { requestURL, timeout in
            captured.timeout = timeout
            return (makeResponse(url: requestURL), Data())
        }
        let service = DefaultURLMetadataService(client: client)
        _ = await service.fetchMetadata(for: url)
        #expect(captured.timeout == 10)
    }

    @Test
    func sanitizesPathTraversal() async {
        let url = URL(string: "https://example.com/download")!
        let client = makeClient(url: url, headers: [
            "Content-Disposition": "attachment; filename=\"../../etc/shadow\""
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(!metadata.filename.contains(".."))
        #expect(!metadata.filename.contains("/"))
        #expect(metadata.filename == "shadow")
    }

    @Test
    func sanitizesBackslashPathTraversal() async {
        let url = URL(string: "https://example.com/download")!
        let client = makeClient(url: url, headers: [
            "Content-Disposition": "attachment; filename=\"..\\..\\secret.txt\""
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(!metadata.filename.contains("\\"))
        #expect(metadata.filename == "secret.txt")
    }

    @Test
    func fallsBackToDownloadForEmptyFilename() async {
        let url = URL(string: "https://example.com/")!
        let client = makeClient(url: url, headers: [
            "Content-Disposition": "attachment; filename=\"\""
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.filename == "download")
    }

    @Test
    func handlesContentDispositionWithEmptyFilenameParameter() async {
        let url = URL(string: "https://example.com/files/photo.jpg")!
        let client = makeClient(url: url, headers: [
            "Content-Disposition": "attachment; filename="
        ])
        let service = DefaultURLMetadataService(client: client)
        let metadata = await service.fetchMetadata(for: url)
        #expect(metadata.filename == "photo.jpg")
    }
}
