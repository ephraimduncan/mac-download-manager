import Foundation
import UniformTypeIdentifiers

extension UTType {
    static var meta4: UTType { UTType(importedAs: "org.metalink.meta4") }
    static var metalink: UTType { UTType(importedAs: "org.metalink") }
}

extension URL {
    var fileExtension: String {
        pathExtension.lowercased()
    }

    var isMetalinkURL: Bool {
        fileExtension == "meta4" || fileExtension == "metalink"
    }

    var suggestedFilename: String {
        let name = lastPathComponent
            .removingPercentEncoding ?? lastPathComponent

        if name.isEmpty || name == "/" {
            return "download"
        }

        let pathHasExtension = name.contains(".") && !name.hasPrefix(".")
        if !pathHasExtension, let queryFilename = filenameFromQueryParameters {
            return queryFilename
        }

        return name
    }

    private var filenameFromQueryParameters: String? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }

        for item in queryItems {
            guard let value = item.value else { continue }

            switch item.name {
            case "response-content-disposition", "rscd":
                if let extracted = extractFilenameFromContentDisposition(value) {
                    return extracted
                }
            case "filename":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            default:
                continue
            }
        }

        return nil
    }

    private func extractFilenameFromContentDisposition(_ value: String) -> String? {
        for part in value.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename=") {
                let filename = String(trimmed.dropFirst("filename=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    .removingPercentEncoding ?? String(trimmed.dropFirst("filename=".count))
                if !filename.isEmpty { return filename }
            }
        }
        return nil
    }

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
