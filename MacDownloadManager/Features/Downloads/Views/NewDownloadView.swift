import AppKit
import SwiftUI

struct NewDownloadView: View {
    @Bindable var viewModel: AddDownloadViewModel
    let metadata: URLMetadata
    let onCancel: () -> Void
    let onDownload: () -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(spacing: 16) {
            Text("New Download")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Save to
            HStack(spacing: 8) {
                Text("Save to:")
                    .frame(width: 60, alignment: .trailing)

                Picker("", selection: $viewModel.selectedDirectory) {
                    Text(viewModel.selectedDirectory)
                        .tag(viewModel.selectedDirectory)
                }
                .labelsHidden()

                Button("Browse...") {
                    chooseDirectory()
                }
                .buttonStyle(.bordered)
            }

            // File name
            HStack(spacing: 8) {
                Text("File name:")
                    .frame(width: 60, alignment: .trailing)

                TextField("Filename", text: $viewModel.editableFilename)
                    .textFieldStyle(.roundedBorder)
            }

            // File size and disk space
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Size:")
                        .foregroundStyle(.secondary)
                    if let fileSize = metadata.fileSize {
                        Text(Self.byteFormatter.string(fromByteCount: fileSize))
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Disk space:")
                        .foregroundStyle(.secondary)
                    if let diskSpace = viewModel.availableDiskSpace {
                        Text(Self.byteFormatter.string(fromByteCount: diskSpace))
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)

            // Buttons
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("DOWNLOAD", action: onDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.isDownloadEnabled)
            }
        }
        .padding(20)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: viewModel.selectedDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.selectedDirectory = url.path(percentEncoded: false)
        }
    }
}
