import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadListView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel: DownloadListViewModel?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            let vm = DownloadListViewModel(
                repository: container.repository,
                aria2: container.aria2Client
            )
            viewModel = vm
            await vm.loadDownloads()
        }
        .task(id: "polling") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await viewModel?.updateFromAria2()
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.isAddURLPresented ?? false },
            set: { viewModel?.isAddURLPresented = $0 }
        )) {
            if let vm = viewModel {
                AddURLSheet { url, headers, directory, segments in
                    await vm.addDownload(
                        url: url,
                        headers: headers,
                        directory: directory,
                        segments: segments
                    )
                }
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { viewModel?.errorMessage != nil },
                set: { if !$0 { viewModel?.errorMessage = nil } }
            ),
            presenting: viewModel?.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Download Already Exists",
            isPresented: Binding(
                get: { viewModel?.pendingDuplicate != nil },
                set: { if !$0 { viewModel?.cancelDuplicate() } }
            ),
            presenting: viewModel?.pendingDuplicate
        ) { _ in
            Button("Skip", role: .cancel) { viewModel?.cancelDuplicate() }
            Button("Download") { viewModel?.confirmDuplicate() }
        } message: { item in
            Text(duplicateMessage(for: item))
        }
    }

    private var sidebar: some View {
        List(FilterOption.allCases, id: \.self, selection: Binding(
            get: { viewModel?.filterOption ?? .active },
            set: { viewModel?.filterOption = $0 }
        )) { option in
            Label(option.displayName, systemImage: iconForFilter(option))
        }
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let vm = viewModel {
            downloadTable(vm: vm)
                .navigationTitle(vm.filterOption.displayName)
                .toolbar { toolbarContent(vm: vm) }
                .searchable(text: Binding(
                    get: { vm.searchText },
                    set: { vm.searchText = $0 }
                ), prompt: "Search downloads")
        }
    }

    @ViewBuilder
    private func downloadTable(vm: DownloadListViewModel) -> some View {
        let items = vm.filteredDownloads
        if items.isEmpty {
            ContentUnavailableView {
                Label("No Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text(vm.searchText.isEmpty
                     ? "Downloads will appear here when you start one."
                     : "No downloads match your search.")
            } actions: {
                if vm.searchText.isEmpty {
                    Button("Add URL") { vm.isAddURLPresented = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            Table(items, selection: Binding(
                get: { vm.selectedDownloadIDs },
                set: { vm.selectedDownloadIDs = $0 }
            ), sortOrder: Binding(
                get: { vm.sortOrder },
                set: { vm.sortOrder = $0 }
            )) {
                TableColumn("Name", value: \.filename) { item in
                    HStack(spacing: 6) {
                        fileIcon(for: item.filename)
                        Text(item.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.filename)
                    }
                }
                .width(min: 200, ideal: 300)

                TableColumn("Size", sortUsing: KeyPathComparator(\.fileSizeForSort)) { item in
                    if let fileSize = item.fileSize, fileSize > 0 {
                        Text(Self.byteFormatter.string(fromByteCount: fileSize))
                            .monospacedDigit()
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 80)

                TableColumn("Status", sortUsing: KeyPathComparator(\.status)) { item in
                    Text(item.statusLabel)
                }
                .width(min: 70, ideal: 100)

                TableColumn("Speed", sortUsing: KeyPathComparator(\.speed)) { item in
                    if item.status == .downloading, item.speed > 0 {
                        Text("\(Self.byteFormatter.string(fromByteCount: item.speed))/s")
                            .monospacedDigit()
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 90)

                TableColumn("Date Added", value: \.createdAt) { item in
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 100, ideal: 140)
            }
            .contextMenu(forSelectionType: UUID.self) { selectedIDs in
                if let item = items.first(where: { selectedIDs.contains($0.id) }) {
                    contextMenuItems(vm: vm, item: item)
                }
            }
            .alternatingRowBackgrounds()
        }
    }

    @ViewBuilder
    private func contextMenuItems(vm: DownloadListViewModel, item: DownloadItem) -> some View {
        switch item.status {
        case .downloading, .waiting:
            Button("Pause") { Task { await vm.pauseDownload(item) } }
        case .paused:
            Button("Resume") { Task { await vm.resumeDownload(item) } }
        default:
            EmptyView()
        }

        Divider()

        Button("Remove", role: .destructive) { Task { await vm.removeDownload(item) } }

        if item.status == .completed {
            Button("Reveal in Finder") { vm.revealInFinder(item) }
        }

        Divider()

        Button("Copy URL") { vm.copyURL(item) }
    }

    @ToolbarContentBuilder
    private func toolbarContent(vm: DownloadListViewModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                vm.isAddURLPresented = true
            } label: {
                Label("Add URL", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)

            if let selected = selectedItem(vm: vm) {
                switch selected.status {
                case .downloading, .waiting:
                    Button {
                        Task { await vm.pauseDownload(selected) }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                case .paused:
                    Button {
                        Task { await vm.resumeDownload(selected) }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                default:
                    EmptyView()
                }
            }

            Button {
                guard let selected = selectedItem(vm: vm) else { return }
                Task { await vm.removeDownload(selected) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(selectedItem(vm: vm) == nil)

            if let selected = selectedItem(vm: vm), selected.status == .completed {
                Button {
                    vm.revealInFinder(selected)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
        }
    }

    private func selectedItem(vm: DownloadListViewModel) -> DownloadItem? {
        guard let id = vm.selectedDownloadIDs.first, vm.selectedDownloadIDs.count == 1 else {
            return nil
        }
        return vm.filteredDownloads.first { $0.id == id }
    }

    private func duplicateMessage(for item: DownloadItem) -> String {
        var lines: [String] = []
        let urlString = item.url.absoluteString
        lines.append(urlString.count > 80 ? String(urlString.prefix(77)) + "..." : urlString)
        if let path = item.filePath {
            lines.append("Location: \(path)")
        }
        if let size = item.fileSize, size > 0 {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        lines.append("Added: \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
        return lines.joined(separator: "\n")
    }

    private func fileIcon(for filename: String) -> some View {
        let ext = (filename as NSString).pathExtension
        let utType = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: utType)
        return Image(nsImage: icon)
            .resizable()
            .frame(width: 16, height: 16)
    }

    private func iconForFilter(_ option: FilterOption) -> String {
        switch option {
        case .active: "arrow.down.circle"
        case .completed: "checkmark.circle"
        case .all: "list.bullet"
        }
    }
}
