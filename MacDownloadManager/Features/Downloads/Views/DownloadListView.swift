import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadListView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel: DownloadListViewModel?
    @State private var addDownloadViewModel: AddDownloadViewModel?
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: DownloadItem?

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

            if container.pendingExtensionDownload != nil {
                handlePendingExtensionDownload()
            }
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
            if let addVM = addDownloadViewModel {
                AddDownloadDialog(viewModel: addVM)
            }
        }
        .onChange(of: viewModel?.isAddURLPresented) { oldValue, newValue in
            if newValue == true, oldValue != true, addDownloadViewModel == nil {
                addDownloadViewModel = AddDownloadViewModel(
                    metadataService: DefaultURLMetadataService(),
                    repository: container.repository,
                    aria2: container.aria2Client,
                    settings: container.settingsViewModel
                )
            } else if newValue == false, oldValue != false {
                addDownloadViewModel?.cancel()
                addDownloadViewModel = nil
                Task { await viewModel?.loadDownloads() }
            }
        }
        .onChange(of: container.pendingExtensionDownload) { _, newValue in
            guard newValue != nil else { return }
            handlePendingExtensionDownload()
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
        .confirmationDialog(
            "Delete selected download",
            isPresented: $showDeleteConfirmation,
            presenting: itemToDelete
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await viewModel?.removeDownload(item) }
            }
        } message: { item in
            Text("Are you sure you want to delete \"\(item.filename)\"?")
        }
    }

    private var sidebar: some View {
        List(FilterOption.allCases, id: \.self, selection: Binding(
            get: { viewModel?.filterOption ?? .all },
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
                    switch item.status {
                    case .downloading, .waiting, .paused:
                        HStack(spacing: 6) {
                            ProgressView(value: item.progress)
                                .progressViewStyle(.linear)
                            Text("\(Int(item.progress * 100))%")
                                .monospacedDigit()
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .completed:
                        Text("Completed")
                    case .error:
                        Text("Error")
                    case .removed:
                        Text("Removed")
                    }
                }
                .width(min: 120, ideal: 180)

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

                TableColumn("ETA") { item in
                    if item.status == .downloading, let formatted = item.formattedETA {
                        Text(formatted)
                            .monospacedDigit()
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 80)

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

        Button("Remove", role: .destructive) {
            itemToDelete = item
            showDeleteConfirmation = true
        }

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
                itemToDelete = selected
                showDeleteConfirmation = true
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
        case .all: "list.bullet"
        case .active: "arrow.down.circle"
        case .completed: "checkmark.circle"
        case .paused: "pause.circle"
        }
    }

    private func handlePendingExtensionDownload() {
        guard let pending = container.pendingExtensionDownload else { return }
        container.pendingExtensionDownload = nil

        if viewModel?.isAddURLPresented == true {
            viewModel?.isAddURLPresented = false
            addDownloadViewModel?.cancel()
            addDownloadViewModel = nil
        }

        let addVM = AddDownloadViewModel(
            metadataService: DefaultURLMetadataService(),
            repository: container.repository,
            aria2: container.aria2Client,
            settings: container.settingsViewModel
        )
        addVM.prefill(message: pending.message)
        addDownloadViewModel = addVM
        viewModel?.isAddURLPresented = true

        Task { await addVM.submitURL() }
    }
}
