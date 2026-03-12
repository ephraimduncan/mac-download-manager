import Foundation
import Testing

@testable import Mac_Download_Manager

@Suite
struct NativeMessagingRegistrationTests {

    // MARK: - Discovery

    @Test func discoveryFindsExistingDirectories() {
        let dirs = NativeMessagingRegistration.discoverHostDirectories()
        #expect(!dirs.isEmpty, "Should find at least one NativeMessagingHosts directory")
        for entry in dirs {
            #expect(entry.directory.lastPathComponent == "NativeMessagingHosts")
        }
    }

    @Test func mozillaPathClassifiedAsFirefox() {
        let dirs = NativeMessagingRegistration.discoverHostDirectories()
        for entry in dirs where entry.directory.path.contains("Mozilla") {
            #expect(entry.type == .firefox)
        }
    }

    @Test func nonMozillaPathsClassifiedAsChromium() {
        let dirs = NativeMessagingRegistration.discoverHostDirectories()
        for entry in dirs where !entry.directory.path.contains("Mozilla") {
            #expect(entry.type == .chromium)
        }
    }

    // MARK: - Chromium manifest content

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
            #expect(!origin.contains("*"), "allowed_origins must not contain wildcards")
            #expect(origin.hasPrefix("chrome-extension://"))
            #expect(origin.hasSuffix("/"))
        }
    }

    // MARK: - Firefox manifest content

    @Test func firefoxManifestUsesAllowedExtensions() throws {
        let data = try NativeMessagingRegistration.manifestData(for: .firefox, helperPath: "/test/path")
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["allowed_extensions"] != nil)
        #expect(dict?["allowed_origins"] == nil)
    }

    @Test func firefoxManifestContainsGeckoId() throws {
        let data = try NativeMessagingRegistration.manifestData(for: .firefox, helperPath: "/test/path")
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let extensions = dict?["allowed_extensions"] as? [String]
        #expect(extensions?.contains("macdownloadmanager@example.com") == true)
    }

    // MARK: - Common manifest fields

    @Test func allManifestsHaveCorrectName() throws {
        for type in [NativeMessagingBrowserType.chromium, .firefox] {
            let data = try NativeMessagingRegistration.manifestData(for: type, helperPath: "/test/path")
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(dict?["name"] as? String == "com.macdownloadmanager.helper")
        }
    }

    @Test func allManifestsHaveCorrectHelperPath() throws {
        let helperPath = "/Applications/Mac Download Manager.app/Contents/MacOS/NativeMessagingHelper"
        for type in [NativeMessagingBrowserType.chromium, .firefox] {
            let data = try NativeMessagingRegistration.manifestData(for: type, helperPath: helperPath)
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(dict?["path"] as? String == helperPath)
        }
    }

    @Test func allManifestsHaveStdioType() throws {
        for type in [NativeMessagingBrowserType.chromium, .firefox] {
            let data = try NativeMessagingRegistration.manifestData(for: type, helperPath: "/test/path")
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(dict?["type"] as? String == "stdio")
        }
    }

    @Test func manifestDataIsValidJSON() throws {
        for type in [NativeMessagingBrowserType.chromium, .firefox] {
            let data = try NativeMessagingRegistration.manifestData(for: type, helperPath: "/test/path")
            let parsed = try? JSONSerialization.jsonObject(with: data)
            #expect(parsed != nil, "Manifest for \(type) should be valid JSON")
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
