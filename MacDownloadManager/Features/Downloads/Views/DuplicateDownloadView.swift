import SwiftUI

struct DuplicateDownloadView: View {
    let record: DownloadRecord
    let onSkip: () -> Void
    let onDownload: () -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(spacing: 16) {
            Text("The download already exists")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "URL:", value: record.url)
                infoRow(label: "Path:", value: record.filePath ?? "—")
                infoRow(label: "Size:", value: sizeText)
                infoRow(label: "Added at:", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            HStack {
                Spacer()

                Button("Skip", action: onSkip)
                    .keyboardShortcut(.cancelAction)

                Button("Download", action: onDownload)
                    .keyboardShortcut(.defaultAction)
                    .textCase(nil)
            }
        }
        .padding(20)
    }

    private var sizeText: String {
        if let fileSize = record.fileSize, fileSize > 0 {
            return Self.byteFormatter.string(fromByteCount: fileSize)
        }
        return "Unknown"
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
