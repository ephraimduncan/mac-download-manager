import Foundation

enum NativeMessagingBrowser: String, CaseIterable, Sendable {
    case chrome
    case firefox
    case edge
}

struct BrowserManifestPath: Sendable {
    let browser: NativeMessagingBrowser
    let directory: URL
}

enum NativeMessagingRegistration {

    private static let manifestName = "com.macdownloadmanager.helper"

    /// Firefox extension ID matching gecko.id in the Firefox manifest.
    private static let firefoxExtensionId = "macdownloadmanager@example.com"

    /// Chrome/Edge allowed origins. Each origin must be in the format
    /// `chrome-extension://EXTENSION_ID/`. Add your extension's ID after
    /// loading it in the browser (visible on chrome://extensions or edge://extensions).
    /// Multiple IDs are supported to allow different builds or browser profiles.
    static let chromeAllowedOrigins: [String] = [
        "chrome-extension://*/*",
    ]

    /// Edge shares the Chromium extension model and uses the same origin format.
    static let edgeAllowedOrigins: [String] = [
        "chrome-extension://*/*",
    ]

    static func browserPaths() -> [BrowserManifestPath] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            BrowserManifestPath(
                browser: .chrome,
                directory: home.appendingPathComponent(
                    "Library/Application Support/Google/Chrome/NativeMessagingHosts"
                )
            ),
            BrowserManifestPath(
                browser: .firefox,
                directory: home.appendingPathComponent(
                    "Library/Application Support/Mozilla/NativeMessagingHosts"
                )
            ),
            BrowserManifestPath(
                browser: .edge,
                directory: home.appendingPathComponent(
                    "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
                )
            ),
        ]
    }

    static func manifestData(for browser: NativeMessagingBrowser, helperPath: String) -> Data {
        var dict: [String: Any] = [
            "name": manifestName,
            "description": "Mac Download Manager Native Messaging Host",
            "path": helperPath,
            "type": "stdio",
        ]

        switch browser {
        case .chrome:
            dict["allowed_origins"] = chromeAllowedOrigins
        case .edge:
            dict["allowed_origins"] = edgeAllowedOrigins
        case .firefox:
            dict["allowed_extensions"] = [firefoxExtensionId]
        }

        let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        return data ?? Data()
    }

    static func registerAll(helperPath: String) {
        for entry in browserPaths() {
            do {
                try FileManager.default.createDirectory(
                    at: entry.directory,
                    withIntermediateDirectories: true
                )
                let data = manifestData(for: entry.browser, helperPath: helperPath)
                let manifestFile = entry.directory.appendingPathComponent("\(manifestName).json")
                try data.write(to: manifestFile)
            } catch {
                print(
                    "Failed to register native messaging manifest for \(entry.browser.rawValue): \(error)"
                )
            }
        }
    }
}
