import Foundation
import Testing

@testable import Mac_Download_Manager

@Suite
struct NativeMessagingRegistrationTests {

    // MARK: - Manifest path constants

    @Test func chromeManifestPathContainsGoogleChrome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts"
        )
        let paths = NativeMessagingRegistration.browserPaths()
        let chromePath = paths.first { $0.browser == .chrome }
        #expect(chromePath != nil)
        #expect(chromePath?.directory == expected)
    }

    @Test func firefoxManifestPathContainsMozilla() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = home.appendingPathComponent(
            "Library/Application Support/Mozilla/NativeMessagingHosts"
        )
        let paths = NativeMessagingRegistration.browserPaths()
        let firefoxPath = paths.first { $0.browser == .firefox }
        #expect(firefoxPath != nil)
        #expect(firefoxPath?.directory == expected)
    }

    @Test func edgeManifestPathContainsMicrosoftEdge() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = home.appendingPathComponent(
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        )
        let paths = NativeMessagingRegistration.browserPaths()
        let edgePath = paths.first { $0.browser == .edge }
        #expect(edgePath != nil)
        #expect(edgePath?.directory == expected)
    }

    @Test func noSafariManifestPath() {
        let paths = NativeMessagingRegistration.browserPaths()
        let safariPath = paths.first { $0.browser.rawValue.lowercased().contains("safari") }
        #expect(safariPath == nil)
    }

    @Test func allThreeBrowsersRegistered() {
        let paths = NativeMessagingRegistration.browserPaths()
        #expect(paths.count == 3)
        let browsers = Set(paths.map(\.browser))
        #expect(browsers.contains(.chrome))
        #expect(browsers.contains(.firefox))
        #expect(browsers.contains(.edge))
    }

    // MARK: - Manifest content

    @Test func chromeManifestUsesAllowedOrigins() {
        let manifest = NativeMessagingRegistration.manifestData(for: .chrome, helperPath: "/test/path")
        let dict = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        #expect(dict?["allowed_origins"] != nil)
        #expect(dict?["allowed_extensions"] == nil)
    }

    @Test func edgeManifestUsesAllowedOrigins() {
        let manifest = NativeMessagingRegistration.manifestData(for: .edge, helperPath: "/test/path")
        let dict = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        #expect(dict?["allowed_origins"] != nil)
        #expect(dict?["allowed_extensions"] == nil)
    }

    @Test func firefoxManifestUsesAllowedExtensions() {
        let manifest = NativeMessagingRegistration.manifestData(for: .firefox, helperPath: "/test/path")
        let dict = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        #expect(dict?["allowed_extensions"] != nil)
        #expect(dict?["allowed_origins"] == nil)
    }

    @Test func firefoxManifestContainsGeckoId() {
        let manifest = NativeMessagingRegistration.manifestData(for: .firefox, helperPath: "/test/path")
        let dict = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        let extensions = dict?["allowed_extensions"] as? [String]
        #expect(extensions?.contains("macdownloadmanager@example.com") == true)
    }

    @Test func allManifestsHaveCorrectName() {
        for browser in NativeMessagingBrowser.allCases {
            let manifest = NativeMessagingRegistration.manifestData(for: browser, helperPath: "/test/path")
            let dict = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
            #expect(dict?["name"] as? String == "com.macdownloadmanager.helper")
        }
    }

    @Test func allManifestsHaveCorrectHelperPath() {
        let helperPath = "/Applications/Mac Download Manager.app/Contents/MacOS/NativeMessagingHelper"
        for browser in NativeMessagingBrowser.allCases {
            let manifest = NativeMessagingRegistration.manifestData(for: browser, helperPath: helperPath)
            let dict = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
            #expect(dict?["path"] as? String == helperPath)
        }
    }

    @Test func allManifestsHaveStdioType() {
        for browser in NativeMessagingBrowser.allCases {
            let manifest = NativeMessagingRegistration.manifestData(for: browser, helperPath: "/test/path")
            let dict = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any]
            #expect(dict?["type"] as? String == "stdio")
        }
    }

    @Test func manifestDataIsValidJSON() {
        for browser in NativeMessagingBrowser.allCases {
            let data = NativeMessagingRegistration.manifestData(for: browser, helperPath: "/test/path")
            let parsed = try? JSONSerialization.jsonObject(with: data)
            #expect(parsed != nil, "Manifest for \(browser) should be valid JSON")
        }
    }

    @Test func noPlaceholderExtensionId() {
        for browser in NativeMessagingBrowser.allCases {
            let data = NativeMessagingRegistration.manifestData(for: browser, helperPath: "/test/path")
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            #expect(!jsonString.contains("YOUR_EXTENSION_ID"))
        }
    }
}
