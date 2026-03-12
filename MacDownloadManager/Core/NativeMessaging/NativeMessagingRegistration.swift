import Foundation

enum NativeMessagingBrowserType: Sendable {
    case chromium
    case firefox
}

struct NativeMessagingHostDirectory: Sendable {
    let type: NativeMessagingBrowserType
    let directory: URL
}

enum NativeMessagingRegistration {

    private static let manifestName = "com.macdownloadmanager.helper"

    /// Firefox extension ID matching gecko.id in the Firefox manifest.
    private static let firefoxExtensionId = "macdownloadmanager@example.com"

    /// Development extension ID derived from the deterministic public key
    /// embedded in Chrome/Edge manifest.json (see scripts/build-extensions.js).
    /// When the extension is published to the Chrome Web Store or Edge Add-ons,
    /// replace this with the store-assigned extension ID.
    private static let chromeExtensionId = "iomcmbjooojnddcbbillnngpdmionlmo"

    static let chromiumAllowedOrigins: [String] = [
        "chrome-extension://\(chromeExtensionId)/",
    ]

    /// Scans ~/Library/Application Support/ for any existing NativeMessagingHosts
    /// directories. Automatically covers every installed Chromium-based browser
    /// (Chrome, Edge, Brave, Arc, Helium, Vivaldi, Opera, etc.) and Firefox.
    static func discoverHostDirectories() -> [NativeMessagingHostDirectory] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        guard let enumerator = FileManager.default.enumerator(
            at: appSupport,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [NativeMessagingHostDirectory] = []
        let appSupportDepth = appSupport.pathComponents.count

        while let url = enumerator.nextObject() as? URL {
            let depth = url.pathComponents.count - appSupportDepth
            if depth > 3 {
                enumerator.skipDescendants()
                continue
            }

            guard url.lastPathComponent == "NativeMessagingHosts",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let type: NativeMessagingBrowserType =
                url.path.contains("Mozilla") ? .firefox : .chromium
            results.append(NativeMessagingHostDirectory(type: type, directory: url))
            enumerator.skipDescendants()
        }

        return results
    }

    static func manifestData(
        for browserType: NativeMessagingBrowserType,
        helperPath: String
    ) throws(NativeMessagingError) -> Data {
        var dict: [String: Any] = [
            "name": manifestName,
            "description": "Mac Download Manager Native Messaging Host",
            "path": helperPath,
            "type": "stdio",
        ]

        switch browserType {
        case .chromium:
            dict["allowed_origins"] = chromiumAllowedOrigins
        case .firefox:
            dict["allowed_extensions"] = [firefoxExtensionId]
        }

        do {
            return try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw .serializationFailed(directory: "unknown", underlying: error)
        }
    }

    static func registerAll(helperPath: String) {
        for entry in discoverHostDirectories() {
            do {
                let data = try manifestData(for: entry.type, helperPath: helperPath)
                let manifestFile = entry.directory.appendingPathComponent("\(manifestName).json")
                try data.write(to: manifestFile)
            } catch {
                print(
                    "Failed to register native messaging manifest at \(entry.directory.path): \(error)"
                )
            }
        }
    }
}

enum NativeMessagingError: Error, CustomStringConvertible {
    case serializationFailed(directory: String, underlying: Error)

    var description: String {
        switch self {
        case .serializationFailed(let directory, let underlying):
            return "Failed to serialize native messaging manifest for \(directory): \(underlying.localizedDescription)"
        }
    }
}
