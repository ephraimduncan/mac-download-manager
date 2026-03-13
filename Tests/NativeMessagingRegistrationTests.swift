import Foundation
import Testing

@testable import Mac_Download_Manager

@Suite
struct NativeMessagingRegistrationTests {

    @Test func chromiumManifestUsesAllowedOrigins() throws {
        let data = try NativeMessagingRegistration.manifestData(for: .chromium, helperPath: "/test/path")
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["allowed_origins"] != nil)
        #expect(dict?["allowed_extensions"] == nil)
    }

    @Test func chromiumAllowedOriginsHaveCorrectFormat() throws {
        let data = try NativeMessagingRegistration.manifestData(for: .chromium, helperPath: "/test/path")
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let origins = dict?["allowed_origins"] as? [String] ?? []
        #expect(!origins.isEmpty)
        for origin in origins {
            #expect(!origin.contains("*"))
            #expect(origin.hasPrefix("chrome-extension://"))
            #expect(origin.hasSuffix("/"))
        }
    }

    @Test func firefoxManifestUsesAllowedExtensions() throws {
        let data = try NativeMessagingRegistration.manifestData(for: .firefox, helperPath: "/test/path")
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["allowed_extensions"] != nil)
        #expect(dict?["allowed_origins"] == nil)
    }

    @Test func allManifestsHaveCorrectNamePathAndType() throws {
        let helperPath = "/Applications/Mac Download Manager.app/Contents/MacOS/NativeMessagingHelper"
        for type in [NativeMessagingBrowserType.chromium, .firefox] {
            let data = try NativeMessagingRegistration.manifestData(for: type, helperPath: helperPath)
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(dict?["name"] as? String == "com.macdownloadmanager.helper")
            #expect(dict?["path"] as? String == helperPath)
            #expect(dict?["type"] as? String == "stdio")
        }
    }

    @Test func noPlaceholderExtensionId() throws {
        for type in [NativeMessagingBrowserType.chromium, .firefox] {
            let data = try NativeMessagingRegistration.manifestData(for: type, helperPath: "/test/path")
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            #expect(!jsonString.contains("YOUR_EXTENSION_ID"))
        }
    }
}
