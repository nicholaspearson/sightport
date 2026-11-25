import SightportCore
import SwiftUI

struct WorkbenchTable: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        RecordTable(workspace: workspace, page: workspace.page)
            .id(workspace.page)
    }
}

private struct RecordTable: View {
    @ObservedObject var workspace: Workspace
    let page: WorkbenchPage
    @State private var query = ""
    @State private var namespace: String?
    @State private var sort = [KeyPathComparator(\WorkbenchRecord.name), KeyPathComparator(\.sourcePath)]
    @FocusState private var searchFocused: Bool

    private var sources: [SourceFile] {
        if case .file(let url) = page { return workspace.sources.filter { $0.url == url } }
        return workspace.sources
    }

    private var records: [WorkbenchRecord] {
        switch page {
        case .contexts, .file:
            return sources.flatMap { source in
                source.contexts.map { WorkbenchRecord(ContextID(file: source.url, name: $0.name), context: $0) }
            }
        case .favorites:
            var remaining = workspace.favorites
            var result: [WorkbenchRecord] = []
            for source in sources {
                for context in source.contexts {
                    let id = ContextID(file: source.url, name: context.name)
                    if remaining.remove(id) != nil { result.append(WorkbenchRecord(id, context: context)) }
                }
            }
            result += remaining.map { WorkbenchRecord($0, context: nil) }
            return result
        case .files:
            return sources.map(WorkbenchRecord.init)
        case .cluster:
            return []
        }
    }

    private var searchPlaceholder: String {
        page == .files ? "Search files" : "Search contexts"
    }

    private var selectedContext: ContextID? {
        guard case .context(let file, let name) = workspace.selection else { return nil }
        return ContextID(file: file, name: name)
    }

    var body: some View {
        let all = records
        let names = Set(all.map(\.namespace).filter { !$0.isEmpty }).sorted()
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = all.filter { (namespace == nil || namespace == $0.namespace) && $0.matches(filter) }
            .sorted(using: sort)
        VStack(spacing: 0) {
            toolbar(names: names, count: rows.count)
            Rectangle().fill(Palette.line).frame(height: 1)
            if page != .files {
                ForEach(sources.filter { $0.error != nil }) { source in
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(source.url.lastPathComponent + " · " + (source.error ?? ""))
                            .lineLimit(2).help(source.error ?? "")
                        Spacer()
                        Button("Retry") { workspace.refresh() }.buttonStyle(.link)
                    }
                    .font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Palette.surface)
                }
            }
            nativeTable(rows)
                .overlay {
                    if rows.isEmpty { emptyState(hasRecords: !all.isEmpty) }
                }
        }
        .background(Palette.canvas)
        .onChange(of: names) { _, available in
            if let namespace, !available.contains(namespace) { self.namespace = nil }
        }
        .onChange(of: query) { _, _ in clearHiddenSelection(rows) }
        .onChange(of: namespace) { _, _ in clearHiddenSelection(rows) }
        .onChange(of: workspace.selection) { _, selected in
            if let selected, all.contains(where: { $0.id == selected }), !rows.contains(where: { $0.id == selected }) {
                query = ""
                namespace = nil
            }
        }
    }

    private func clearHiddenSelection(_ visible: [WorkbenchRecord]) {
        if let id = workspace.selection, !visible.contains(where: { $0.id == id }) {
            workspace.select(nil)
        }
    }

    private func toolbar(names: [String], count: Int) -> some View {
        HStack(spacing: 9) {
            if page != .files {
                Menu {
                    Picker("Namespace", selection: $namespace) {
                        Text("All namespaces").tag(Optional<String>.none)
                        ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
                    }.pickerStyle(.inline)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.stack.3d.up").accessibilityHidden(true)
                        Text(namespace ?? "All namespaces").lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 100, alignment: .leading).help(namespace ?? "All namespaces")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                    }.padding(.horizontal, 9).frame(height: 26)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Filter by namespace")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.muted)
                TextField(searchPlaceholder, text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel(searchPlaceholder)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).frame(minWidth: 85, idealWidth: 190, maxWidth: 270).frame(height: 26)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(searchFocused ? Palette.forest : Palette.line))
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.muted)
                .fixedSize()
            Spacer(minLength: 0)
            Group {
                if page == .files {
                    Button("Open file…") { workspace.chooseFile() }
                } else {
                    ConnectContextButton(workspace: workspace, id: selectedContext)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.ink)
        .padding(.horizontal, 12).frame(height: 43)
        .background(Palette.surface)
    }

    private func nativeTable(_ rows: [WorkbenchRecord]) -> some View {
        // AppKit can retain and update cells after their SwiftUI table has left the hierarchy.
        let workspace = self.workspace
        let activeContext = workspace.activeContext
        let loading = workspace.loading
        let selection = Binding<WorkbenchItem?>(
            get: { workspace.selection },
            set: { item in
                if workspace.page == page, workspace.selection != item { workspace.select(item) }
            }
        )
        return Table(rows, selection: selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { row in
                RecordName(record: row, activeContext: activeContext)
            }.width(min: 120, ideal: 235)
            TableColumn(page == .files ? "Location" : "Cluster", value: \.detail) { row in
                cell(row.detail)
            }.width(min: 76, ideal: 145)
            TableColumn(page == .files ? "Contexts" : "Namespace") { row in
                if case .file(let source) = row.content {
                    cell(String(source.contexts.count))
                } else {
                    cell(row.namespace)
                }
            }.width(min: 71, ideal: 90, max: 155)
            TableColumn(page == .files ? "Status" : "Kubeconfig") { row in
                if case .file(let source) = row.content {
                    Text(source.error != nil ? "Read error" : (loading ? "Reading…" : "Available"))
                        .font(.system(size: 11.5)).foregroundStyle(source.error != nil ? .orange : Palette.muted)
                        .help(source.error ?? "")
                } else {
                    cell(row.sourcePath)
                }
            }.width(min: 76, ideal: 117)
            TableColumn("") { row in RecordActions(workspace: workspace, record: row) }.width(28)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .contextMenu(forSelectionType: WorkbenchItem.self) { items in
            if let row = rows.first(where: { items.contains($0.id) }) { RecordMenu(workspace: workspace, record: row) }
        } primaryAction: { items in
            guard let item = items.first else { return }
            switch item {
            case .context(let file, let name):
                let id = ContextID(file: file, name: name)
                if workspace.context(for: id) != nil { workspace.connect(id) }
            case .file(let url): workspace.open(.file(url))
            case .resource: break
            }
        }
    }

    private func cell(_ value: String) -> some View {
        Text(value.isEmpty ? "—" : value)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .lineLimit(1).truncationMode(.middle).help(value)
    }

    @ViewBuilder
    private func emptyState(hasRecords: Bool) -> some View {
        if hasRecords {
            emptyMessage("No matches", symbol: "magnifyingglass") {
                Button("Clear filters") { query = ""; namespace = nil }
            }
        } else {
            switch page {
            case .cluster:
                EmptyView()
            case .favorites:
                emptyMessage("No favorite contexts", symbol: "star") {
                    Button("Browse contexts") { workspace.open(.contexts) }
                }
            case .contexts, .files, .file:
                if workspace.loading {
                    ProgressView("Reading kubeconfig…").controlSize(.small)
                } else if page == .files || sources.isEmpty {
                    emptyMessage("No kubeconfig files", symbol: "folder") {
                        Button("Open kubeconfig…") { workspace.chooseFile() }
                    }
                } else {
                    emptyMessage("No contexts to display", symbol: "helm") {
                        Button("Open another kubeconfig…") { workspace.chooseFile() }
                    }
                }
            }
        }
    }

    private func emptyMessage<Action: View>(_ title: String, symbol: String,
                                             @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 20)).accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .medium))
            action().buttonStyle(.link).font(.system(size: 12))
        }
        .foregroundStyle(Palette.muted)
    }
}
