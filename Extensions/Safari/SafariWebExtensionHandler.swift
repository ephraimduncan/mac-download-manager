import AppKit
import Foundation
import SafariServices

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let appGroupId = "group.com.macdownloadmanager"
    private static let pendingDownloadsKey = "pendingDownloads"
    private static let appBundleId = "com.macdownloadmanager.app"

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let userInfo = item.userInfo as? [String: Any],
              let message = userInfo[SFExtensionMessageKey] as? [String: Any] else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let messageType = message["type"] as? String ?? ""

        switch messageType {
        case "download":
            handleDownloadRequest(message: message, context: context)
        case "getStatus":
            handleStatusRequest(context: context)
        default:
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: ["status": "unknown_message_type"]]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private func handleDownloadRequest(message: [String: Any], context: NSExtensionContext) {
        guard let url = message["url"] as? String, !url.isEmpty else {
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: ["status": "error", "error": "Missing URL"]]
            context.completeRequest(returningItems: [response], completionHandler: nil)
            return
        }

        let downloadRequest: [String: Any] = [
            "url": url,
            "filename": message["filename"] as? String ?? "",
            "headers": message["headers"] as? [String: String] ?? [:],
            "referrer": message["referrer"] as? String ?? "",
            "fileSize": message["fileSize"] as? Int ?? 0,
            "timestamp": Date().timeIntervalSince1970,
        ]

        writeDownloadRequest(downloadRequest)
        launchContainingAppIfNeeded()

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["status": "received"]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func handleStatusRequest(context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["status": "ok", "connected": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func writeDownloadRequest(_ request: [String: Any]) {
        guard let defaults = UserDefaults(suiteName: SafariWebExtensionHandler.appGroupId) else {
            return
        }

        var pending = defaults.array(forKey: SafariWebExtensionHandler.pendingDownloadsKey)
            as? [[String: Any]] ?? []
        pending.append(request)
        defaults.set(pending, forKey: SafariWebExtensionHandler.pendingDownloadsKey)
    }

    private func launchContainingAppIfNeeded() {
        let workspace = NSWorkspace.shared
        let isRunning = workspace.runningApplications.contains {
            $0.bundleIdentifier == SafariWebExtensionHandler.appBundleId
        }
        guard !isRunning else { return }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: SafariWebExtensionHandler.appBundleId) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        workspace.openApplication(at: appURL, configuration: config, completionHandler: nil)
    }
}
