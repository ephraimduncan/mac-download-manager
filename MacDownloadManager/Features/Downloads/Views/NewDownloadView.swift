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

            VStack(spacing: 6) {
                Text("Save to:")
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    PopUpButton(
                        selection: $viewModel.selectedDirectory,
                        options: viewModel.directoryOptions
                    )

                    Button("Browse...") {
                        chooseDirectory()
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(spacing: 6) {
                Text("File name:")
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Filename", text: $viewModel.editableFilename)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 4) {
                Spacer()
                Text("Size:")
                    .foregroundStyle(.secondary)
                if let fileSize = metadata.fileSize {
                    Text(Self.byteFormatter.string(fromByteCount: fileSize))
                } else {
                    Text("Unknown")
                        .foregroundStyle(.secondary)
                }
                Text("·")
                    .foregroundStyle(.secondary)
                Text("Disk space:")
                    .foregroundStyle(.secondary)
                if let diskSpace = viewModel.availableDiskSpace {
                    Text(Self.byteFormatter.string(fromByteCount: diskSpace))
                } else {
                    Text("Unknown")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Download", action: onDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.isDownloadEnabled)
                    .textCase(nil)
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
            viewModel.addBrowsedDirectory(url.path(percentEncoded: false))
        }
    }
}

private struct PopUpButton: NSViewRepresentable {
    @Binding var selection: String
    var options: [String]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.removeAllItems()
        button.addItems(withTitles: options)
        button.selectItem(withTitle: selection)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if let title = sender.titleOfSelectedItem {
                selection.wrappedValue = title
            }
        }
    }
}
