import SwiftUI

struct AddDownloadDialog: View {
    @Bindable var viewModel: AddDownloadViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .idle:
                idleContent
            case .querying:
                queryingContent
            case .duplicateFound(let record):
                DuplicateDownloadView(
                    record: record,
                    onSkip: {
                        viewModel.skip()
                        dismiss()
                    },
                    onDownload: {
                        Task {
                            await viewModel.forceDownload()
                            dismiss()
                        }
                    }
                )
            case .newDownload(let metadata):
                NewDownloadView(
                    viewModel: viewModel,
                    metadata: metadata,
                    onCancel: {
                        viewModel.cancel()
                        dismiss()
                    },
                    onDownload: {
                        Task {
                            await viewModel.startDownload()
                            dismiss()
                        }
                    }
                )
            }
        }
        .frame(width: 480)
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
            Text("Enter URL")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("URL", text: $viewModel.urlText, prompt: Text("https://example.com/file.zip"))
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if viewModel.isOKEnabled {
                        Task { await viewModel.submitURL() }
                    }
                }

            HStack {
                Spacer()

                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("OK") {
                    Task { await viewModel.submitURL() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.isOKEnabled)
            }
        }
        .padding(20)
    }

    private var queryingContent: some View {
        VStack(spacing: 16) {
            Text("Enter URL")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("URL", text: .constant(viewModel.urlText), prompt: Text("https://example.com/file.zip"))
                .textFieldStyle(.roundedBorder)
                .disabled(true)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Querying info. Please wait...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()

                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("OK") {}
                    .disabled(true)
            }
        }
        .padding(20)
    }
}
