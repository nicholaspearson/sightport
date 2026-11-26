import SightportCore
import SwiftUI

struct ClusterResourceTable: View {
    @ObservedObject var workspace: Workspace
    let section: ClusterSection
    @State private var query = ""
    @State private var checkedPods: Set<String> = []
    @State private var sort: [KeyPathComparator<ResourceRow>]
    @FocusState private var searchFocused: Bool

    init(workspace: Workspace, section: ClusterSection) {
        self.workspace = workspace
        self.section = section
        var order = [KeyPathComparator(\ResourceRow.name), KeyPathComparator(\ResourceRow.namespace)]
        if section == .resources(.events), let index = section.columns.firstIndex(of: "Last seen") {
            order.insert(KeyPathComparator(\ResourceRow.[field: index], order: .reverse), at: 0)
        }
        _sort = State(initialValue: order)
    }

    private var kind: ResourceKind? { section.listKind }
    private var listTitle: String {
        if case .customResources(let type) = section { return type.resourceName }
        return kind?.title ?? section.title
    }

    var body: some View {
        GeometryReader { area in
            resourceList(compact: (kind == .pods || workspace.page.configDataKind != nil) && area.size.width < 425)
        }
    }

    private func resourceList(compact: Bool) -> some View {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = workspace.rows.filter { row in
            filter.isEmpty || row.name.localizedCaseInsensitiveContains(filter)
                || row.namespace?.localizedCaseInsensitiveContains(filter) == true
                || row.values.contains { $0.localizedCaseInsensitiveContains(filter) }
                || row.pod?.matches(filter) == true
        }
        let rows = kind == .pods ? matches : matches.sorted(using: sort)
        let kinds = ResourceKind.workloads.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }

        return VStack(spacing: 0) {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                 : AnyLayout(HStackLayout(spacing: 9))
            layout {
                HStack(spacing: compact ? 5 : 9) {
                    scopeControls(rows: rows, compact: compact)
                    if compact {
                        Spacer(minLength: 0)
                        refreshButton
                    }
                }
                HStack(spacing: compact ? 5 : 9) {
                    searchBox
                    if section != .overview, !workspace.resourceLoading, workspace.resourceError == nil {
                        Text("\(rows.count) " + (rows.count == 1 ? "item" : "items"))
                            .font(.system(size: 10.5)).foregroundStyle(Palette.muted).fixedSize()
                            .accessibilityLabel("\(rows.count) " + listTitle)
                    }
                    if kind == .pods, !rows.isEmpty, let message = workspace.podMetricsError {
                        ViewThatFits(in: .horizontal) {
                            if !compact {
                                Label("Metrics unavailable", systemImage: "gauge.with.dots.needle.0percent").fixedSize()
                            }
                            Image(systemName: "gauge.with.dots.needle.0percent")
                        }
                        .font(.system(size: 10.5)).foregroundStyle(Palette.muted).help(message)
                        .accessibilityLabel("Pod metrics unavailable").accessibilityHint(message)
                    }
                    Spacer(minLength: 0)
                    if !compact { refreshButton }
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, compact ? 8 : 12).frame(height: compact ? 68 : 43).background(Palette.surface)

            Divider()

            if section.isNamespaced, let message = workspace.namespaceError {
                Label("Namespace list unavailable. You can enter a namespace by name.", systemImage: "info.circle")
                    .help(message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface)
            }

            if section != .overview {
                Group {
                    if section == .argoDashboard {
                        if workspace.resourceLoading || workspace.resourceError != nil || rows.isEmpty {
                            Color.clear
                        } else {
                            ArgoDashboardView(rows: rows, query: filter, openApplications: {
                                workspace.openCluster(.resources(.argoApplications))
                            }, inspect: workspace.inspectArgoApplication)
                        }
                    } else if kind == .pods {
                        PodsTable(workspace: workspace, rows: rows, checked: $checkedPods)
                    } else {
                        resourceTable(rows: rows)
                    }
                }
                    .overlay {
                        if workspace.resourceLoading && rows.isEmpty {
                            ProgressView("Loading " + listTitle.lowercased() + "…").controlSize(.small)
                        } else if let error = workspace.resourceError {
                            VStack(spacing: 8) {
                                Label("Couldn’t load " + listTitle.lowercased(), systemImage: "exclamationmark.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(error).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    .multilineTextAlignment(.center).textSelection(.enabled)
                                Button("Retry") { workspace.reloadResources() }.buttonStyle(.link)
                            }
                            .padding(16).frame(maxWidth: 420)
                        } else if rows.isEmpty {
                            VStack(spacing: 9) {
                                emptyState(filtered: !filter.isEmpty, noun: listTitle.lowercased())
                                if filter.isEmpty, let kind, ResourceKind.argoResources.contains(kind) || ResourceKind.argoSettings.contains(kind),
                                   let current = workspace.namespaceFilter {
                                    if current != "argocd", workspace.namespaceNames.contains("argocd") {
                                        Button("View namespace argocd") { workspace.setNamespace("argocd") }
                                            .buttonStyle(.link)
                                    } else {
                                        Button("View all namespaces") { workspace.setNamespace(nil) }.buttonStyle(.link)
                                    }
                                }
                            }
                        }
                    }
            } else {
                overviewTable(kinds)
                    .overlay { if kinds.isEmpty { emptyState(filtered: true, noun: "workload types") } }
            }
        }
        .background(Palette.canvas)
        .onChange(of: query) { _, _ in
            if case .resource(let id) = workspace.selection, !rows.contains(where: { $0.id == id }) {
                workspace.select(nil)
            }
        }
    }

    @ViewBuilder
    private func scopeControls(rows: [ResourceRow], compact: Bool) -> some View {
        if kind == .pods { PodSelectionControls(rows: rows, checked: $checkedPods) }
        if section.isNamespaced {
            NamespaceSelector(workspace: workspace, compact: compact)
        } else {
            Label("Cluster-wide", systemImage: "network").foregroundStyle(Palette.muted).fixedSize()
        }
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            let title = "Search " + (section == .overview ? "workload types" : listTitle.lowercased())
            TextField(title, text: $query)
                .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel(title)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(minWidth: 78, maxWidth: 260).frame(height: 26)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(searchFocused ? Palette.forest : Palette.line))
    }

    private var refreshButton: some View {
        IconAction(symbol: "arrow.clockwise", title: "Refresh resources") { workspace.reloadResources() }
    }

    private func resourceTable(rows: [ResourceRow]) -> some View {
        let workspace = self.workspace
        let page = workspace.page
        let context = workspace.connectedContext
        let columns = section.columns
        let summaryIndices = columns.indices.filter { section != .helmReleases || columns[$0] != "Updated" }
        let selection = Binding<String?>(get: {
            if case .resource(let id) = workspace.selection { return id }
            return nil
        }, set: { id in
            guard workspace.page == page, workspace.connectedContext == context else { return }
            let item = id.map(WorkbenchItem.resource)
            if workspace.selection != item { workspace.select(item) }
        })
        return Group {
            if #available(macOS 14.4, *) {
                Table(rows, selection: selection, sortOrder: $sort) {
                    nameColumn
                    if section.isNamespaced { namespaceColumn }
                    TableColumnForEach(columns.indices, id: \.self) { index in
                        detailColumn(columns[index], index: index)
                    }
                    if section != .helmReleases { ageColumn }
                }
            } else {
                // Early Sonoma versions support a fixed Table column layout.
                Table(rows, selection: selection, sortOrder: $sort) {
                    nameColumn
                    TableColumn(section.isNamespaced ? "Namespace" : "Scope") { row in
                        ResourceCell(value: row.namespace ?? "Cluster")
                    }.width(min: 62, ideal: 95)
                    TableColumn("Details") { row in
                        ResourceCell(value: summaryIndices.map { columns[$0] + ": " + row[field: $0] }.joined(separator: " · "))
                    }.width(min: 110, ideal: 220)
                    legacyDateColumn
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .contextMenu(forSelectionType: String.self) { ids in
            if kind == .namespaces, let row = rows.first(where: { ids.contains($0.id) }) {
                Button("View pods in " + row.name) { showPods(in: row.name) }
            } else if kind == .customResourceDefinitions, let row = rows.first(where: { ids.contains($0.id) }),
                      let type = CustomResourceType(definition: row) {
                Button("View instances") { workspace.openCluster(.customResources(type)) }
            }
        } primaryAction: { ids in
            guard let row = rows.first(where: { ids.contains($0.id) }),
                  workspace.page == page, workspace.connectedContext == context else { return }
            if kind == .namespaces {
                showPods(in: row.name)
            } else if kind == .customResourceDefinitions, let type = CustomResourceType(definition: row) {
                workspace.openCluster(.customResources(type))
            }
        }
    }

    private var nameColumn: TableColumn<ResourceRow, KeyPathComparator<ResourceRow>, ResourceNameCell, Text> {
        TableColumn("Name", value: \.name) { ResourceNameCell(name: $0.name) }.width(min: 119, ideal: 210)
    }

    private var namespaceColumn: TableColumn<ResourceRow, KeyPathComparator<ResourceRow>, ResourceCell, Text> {
        TableColumn("Namespace", value: \.namespaceText) { ResourceCell(value: $0.namespaceText) }
            .width(min: 70, ideal: 95)
    }

    private var ageColumn: TableColumn<ResourceRow, KeyPathComparator<ResourceRow>, ResourceCell, Text> {
        TableColumn("Age", value: \.ageSortValue) { ResourceCell(ageSince: $0.createdAt) }.width(min: 43, ideal: 55, max: 85)
    }

    private var legacyDateColumn: TableColumn<ResourceRow, KeyPathComparator<ResourceRow>, ResourceCell, Text> {
        if section == .helmReleases, let index = section.columns.firstIndex(of: "Updated") {
            return detailColumn("Updated", index: index)
        }
        return ageColumn
    }

    private func detailColumn(_ title: String, index: Int) -> TableColumn<ResourceRow, KeyPathComparator<ResourceRow>, ResourceCell, Text> {
        TableColumn(title, value: \ResourceRow.[field: index]) { row in ResourceCell(value: row[field: index]) }
            .width(min: 57, ideal: 100)
    }

    private func showPods(in namespace: String) {
        workspace.setNamespace(namespace)
        workspace.openCluster(.resources(.pods))
    }

    private func overviewTable(_ kinds: [ResourceKind]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workload")
                Spacer()
                Text("Objects").frame(width: 110, alignment: .trailing)
                Color.clear.frame(width: 14, height: 1)
            }
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 17).frame(height: 28).background(Palette.surface)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(kinds, id: \.self) { kind in
                        Button { workspace.openCluster(.resources(kind)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox").foregroundStyle(Palette.forest)
                                Text(kind.title).fontWeight(.medium)
                                Spacer()
                                switch workspace.overview[kind] {
                                case .count(let count):
                                    Text(String(count)).monospacedDigit()
                                case .failed(let message):
                                    Label("Unavailable", systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.orange).help(message)
                                case .loading, nil:
                                    Text("Loading…").foregroundStyle(Palette.muted)
                                }
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted)
                            }
                            .font(.system(size: 12)).padding(.horizontal, 17)
                            .frame(height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("View " + kind.title.lowercased())
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func emptyState(filtered: Bool, noun: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: filtered ? "magnifyingglass" : "tray").font(.system(size: 19))
                .foregroundStyle(Palette.muted)
            Text(filtered ? "No matches" : "No " + noun + " found").font(.system(size: 13, weight: .medium))
            if filtered {
                Button("Clear search") { query = "" }.buttonStyle(.link)
            }
        }
    }
}

struct ResourceNameCell: View {
    let name: String
    var body: some View {
        Text(verbatim: name).font(.system(size: 12, weight: .medium))
            .lineLimit(1).truncationMode(.middle).help(name).frame(minHeight: 29)
            .background(TableRowHover().accessibilityHidden(true))
    }
}

struct ResourceCell: View {
    var value = ""
    var ageSince: Date?

    var body: some View {
        Group {
            if let ageSince {
                ResourceAgeText(createdAt: ageSince)
            } else {
                Text(verbatim: value.isEmpty ? "—" : value)
            }
        }
        .lineLimit(1).truncationMode(.middle)
        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        .help(ageSince?.formatted(date: .abbreviated, time: .standard) ?? value)
    }
}

// Each visible age label wakes only when its displayed unit changes.
private struct ResourceAgeSchedule: TimelineSchedule {
    let createdAt: Date

    static func unit(for seconds: Int) -> (duration: Int, suffix: String) {
        switch seconds {
        case ..<60: return (1, "s")
        case ..<3600: return (60, "m")
        case ..<86_400: return (3600, "h")
        default: return (86_400, "d")
        }
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        sequence(first: startDate) { date in
            let elapsed = Int(max(0, date.timeIntervalSince(createdAt)))
            let step = Self.unit(for: elapsed).duration
            return createdAt.addingTimeInterval(TimeInterval((elapsed / step + 1) * step))
        }
    }
}

struct ResourceAgeText: View {
    let createdAt: Date
    var includeDate = false

    var body: some View {
        if includeDate {
            HStack(spacing: 4) {
                relativeTime
                Text(verbatim: createdAt.formatted(date: .abbreviated, time: .shortened))
                    .textSelection(.enabled)
            }
        } else {
            relativeTime
        }
    }

    private var relativeTime: some View {
        TimelineView(ResourceAgeSchedule(createdAt: createdAt)) { tick in
            let elapsed = Int(max(0, tick.date.timeIntervalSince(createdAt)))
            let unit = ResourceAgeSchedule.unit(for: elapsed)
            let age = String(elapsed / unit.duration) + unit.suffix
            Text(verbatim: includeDate ? age + " ago ·" : age)
        }
    }
}

extension ResourceRow {
    var namespaceText: String { namespace ?? "" }
    subscript(field index: Int) -> String { values.indices.contains(index) ? values[index] : "" }
    var ageSortValue: TimeInterval { -(createdAt?.timeIntervalSinceReferenceDate ?? -.infinity) }
}

private struct NamespaceSelector: View {
    @ObservedObject var workspace: Workspace
    var compact = false
    @State private var enterName = false
    @State private var name = ""

    var body: some View {
        let selected = workspace.namespaceFilter
        let options = Set(workspace.namespaceNames + [selected].compactMap { $0 }).sorted()
        Menu {
            Picker("Namespace", selection: Binding(
                get: { workspace.namespaceFilter }, set: { workspace.setNamespace($0) }
            )) {
                Text("All namespaces").tag(Optional<String>.none)
                ForEach(options, id: \.self) { value in Text(verbatim: value).tag(Optional(value)) }
            }.pickerStyle(.inline)
            Divider()
            Button("Enter namespace…") {
                name = workspace.namespaceFilter ?? ""
                enterName = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").accessibilityHidden(true)
                Text(verbatim: selected ?? "All namespaces").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(maxWidth: compact ? 100 : 155, alignment: .leading).fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Select namespace").accessibilityValue(selected ?? "All namespaces")
        .help(selected ?? "All namespaces")
        .sheet(isPresented: $enterName) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose namespace").font(.headline)
                TextField("Namespace", text: $name)
                    .accessibilityLabel("Namespace name")
                if !name.isEmpty && !validName {
                    Text("Use up to 63 lowercase letters, digits, or hyphens. Start and end with a letter or digit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { enterName = false }.keyboardShortcut(.cancelAction)
                    Button("Use namespace") {
                        workspace.setNamespace(namespaceName)
                        enterName = false
                    }.keyboardShortcut(.defaultAction).disabled(!validName)
                }
            }
            .padding(20).frame(width: 340)
        }
    }

    private var namespaceName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validName: Bool {
        namespaceName.utf8.count <= 63 &&
        namespaceName.range(of: #"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"#, options: .regularExpression) != nil
    }
}

struct ClusterResourceInspector: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if case .cluster(let section) = workspace.page, case .resource(let id) = workspace.selection,
           let row = workspace.rows.first(where: { $0.id == id }) {
            resourceDetails(section, row: row)
        } else {
            let overview = workspace.page == .cluster(.overview)
            Label(overview ? "Choose a workload type to browse its resources." : "Select a resource to inspect its details.",
                  systemImage: overview ? "square.3.layers.3d" : "cursorarrow")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resourceDetails(_ section: ClusterSection, row: ResourceRow) -> some View {
        let kind = section.listKind
        let columns = section.columns
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").foregroundStyle(Palette.forest)
                    Text(verbatim: row.name).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).help(row.name).textSelection(.enabled)
                    Spacer()
                    if kind == .namespaces {
                        Button("View pods") {
                            workspace.setNamespace(row.name)
                            workspace.openCluster(.resources(.pods))
                        }.controlSize(.small).help("View pods in " + row.name)
                    } else if kind == .customResourceDefinitions, let type = CustomResourceType(definition: row) {
                        Button("View instances") { workspace.openCluster(.customResources(type)) }
                            .controlSize(.small).help("Browse " + type.resourceName)
                    }
                }
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
                    if let namespace = row.namespace { field("Namespace", namespace) }
                    ForEach(columns.indices, id: \.self) { index in
                        let column = columns[index]
                        let value = row[field: index]
                        if kind == .nodeClaims, !value.isEmpty, column == "Node Pool" || column == "Node" {
                            GridRow(alignment: .firstTextBaseline) {
                                Text(column).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize()
                                Button(value) {
                                    workspace.showNodeClaimReference(column == "Node Pool" ? .nodePools : .nodes, name: value)
                                }
                                .buttonStyle(.link).help("Show " + value)
                            }
                        } else { field(column, value) }
                    }
                    if let createdAt = row.createdAt { field("Created", createdAt.formatted(date: .abbreviated, time: .standard)) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize()
            Text(verbatim: value.isEmpty ? "—" : value)
                .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
