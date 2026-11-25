import AppKit
import SightportCore
import SwiftUI

extension PodDetails {
    func matches(_ query: String) -> Bool {
        [status, warning, controllerKind, controllerName, node, qos]
            .contains { $0?.localizedCaseInsensitiveContains(query) == true }
            || containers.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.reason?.localizedCaseInsensitiveContains(query) == true }
    }
}

private extension ResourceRow {
    var qualifiedPodName: String { namespace.map { $0 + "/" + name } ?? name }
}

private func copyPodNames(_ rows: [ResourceRow]) {
    guard !rows.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(rows.map(\.qualifiedPodName).joined(separator: "\n"), forType: .string)
}

struct PodSelectionControls: View {
    let rows: [ResourceRow]
    @Binding var checked: Set<String>

    var body: some View {
        let visible = Set(rows.map(\.id))
        let count = checked.intersection(visible).count
        let all = count > 0 && count == visible.count
        HStack(spacing: 4) {
            Button {
                checked = all ? [] : visible
            } label: {
                Image(systemName: all ? "checkmark.square.fill" : (count == 0 ? "square" : "minus.square.fill"))
                    .font(.system(size: 14))
                    .foregroundStyle(count == 0 ? Palette.muted : Palette.forest)
            }
            .buttonStyle(.plain).disabled(rows.isEmpty)
            .help(all ? "Clear checked pods" : "Check all visible pods")
            .accessibilityLabel(all ? "Clear checked pods" : "Check all visible pods")
            if count > 0 {
                Button {
                    copyPodNames(rows.filter { checked.contains($0.id) })
                } label: {
                    Label(String(count), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .help(count == 1 ? "Copy the checked pod’s namespace/name" : "Copy the names of \(count) checked pods")
                .accessibilityLabel(count == 1 ? "Copy 1 checked pod name" : "Copy \(count) checked pod names")
            }
        }
        .fixedSize()
        .onChange(of: visible) { _, ids in checked.formIntersection(ids) }
    }
}

private struct PodTableItem: Identifiable {
    let row: ResourceRow
    let usage: PodUsage?
    var id: String { row.id }
    var name: String { row.name }
    var namespace: String { row.namespaceText }
    var warning: String { row.pod?.warning ?? "" }
    var cpu: Int { usage?.cpuMillicores ?? -1 }
    var memory: Int64 { usage?.memoryBytes ?? -1 }
    var containerCount: Int { row.pod?.containers.count ?? 0 }
    var restarts: Int { row.pod?.restartCount ?? 0 }
    var controller: String { row.pod?.controllerKind ?? "" }
    var node: String { row.pod?.node ?? "" }
    var qos: String { row.pod?.qos ?? "" }
    var status: String { row.pod?.status ?? "" }
    var age: TimeInterval { row.ageSortValue }
}

struct PodsTable: View {
    @ObservedObject var workspace: Workspace
    let rows: [ResourceRow]
    @Binding var checked: Set<String>
    @State private var sort = [KeyPathComparator(\PodTableItem.age), KeyPathComparator(\PodTableItem.name)]

    var body: some View {
        let workspace = self.workspace
        let context = workspace.connectedContext
        let scope = workspace.namespaceFilter
        let metrics = workspace.podMetrics
        let items = rows.map { row in
            PodTableItem(row: row, usage: row.namespace.flatMap { metrics[PodKey(namespace: $0, name: row.name)] })
        }.sorted(using: sort)
        let selected = Binding<String?>(get: {
            if case .resource(let id) = workspace.selection { return id }
            return nil
        }, set: { id in
            guard workspace.page == .cluster(.resources(.pods)), workspace.connectedContext == context,
                  workspace.namespaceFilter == scope else { return }
            let item = id.map(WorkbenchItem.resource)
            if workspace.selection != item { workspace.select(item) }
        })
        return Table(items, selection: selected, sortOrder: $sort) {
            identityColumns
            usageColumns
            relationshipsColumns
            statusColumns
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                PodActions(workspace: workspace, row: row)
            }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) { workspace.inspectPod(row) }
        }
    }

    @TableColumnBuilder<PodTableItem, KeyPathComparator<PodTableItem>>
    private var identityColumns: some TableColumnContent<PodTableItem, KeyPathComparator<PodTableItem>> {
        let workspace = self.workspace
        TableColumn("") { item in
            Toggle("Check " + item.name, isOn: Binding(get: { checked.contains(item.id) }, set: { enabled in
                if enabled { checked.insert(item.id) } else { checked.remove(item.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().controlSize(.small)
        }.width(22)
        TableColumn("Name", value: \.name) { ResourceNameCell(name: $0.name) }
            .width(min: 155, ideal: 250)
        TableColumn(Text(Image(systemName: "exclamationmark.triangle")),
                    sortUsing: KeyPathComparator(\PodTableItem.warning)) { item in
            if !item.warning.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(item.warning).accessibilityLabel(item.warning)
            }
        }.width(31)
        TableColumn("Namespace", value: \.namespace) { item in
            PodLink(value: item.namespace, action: { workspace.showPodNamespace(item.row) })
        }.width(min: 85, ideal: 112)
    }

    @TableColumnBuilder<PodTableItem, KeyPathComparator<PodTableItem>>
    private var usageColumns: some TableColumnContent<PodTableItem, KeyPathComparator<PodTableItem>> {
        let missing = metricsMessage
        TableColumn("CPU", value: \.cpu) { item in
            UsageCell(text: item.usage?.cpuText, missing: missing)
        }.width(min: 50, ideal: 65)
        TableColumn("Memory", value: \.memory) { item in
            UsageCell(text: item.usage?.memoryText, missing: missing)
        }.width(min: 66, ideal: 79)
    }

    @TableColumnBuilder<PodTableItem, KeyPathComparator<PodTableItem>>
    private var relationshipsColumns: some TableColumnContent<PodTableItem, KeyPathComparator<PodTableItem>> {
        let workspace = self.workspace
        TableColumn("Containers", value: \.containerCount) { item in
            ContainerIndicators(containers: item.row.pod?.containers ?? [])
        }.width(min: 73, ideal: 90)
        TableColumn("Restarts", value: \.restarts) { item in
            ResourceCell(value: String(item.restarts)).monospacedDigit()
        }.width(min: 58, ideal: 66)
        TableColumn("Controlled By", value: \.controller) { item in
            if workspace.podOwnerKind(item.row) != nil {
                PodLink(value: item.controller, action: { workspace.showPodOwner(item.row) })
                    .help([item.row.pod?.controllerKind, item.row.pod?.controllerName].compactMap { $0 }.joined(separator: "/"))
            } else {
                ResourceCell(value: item.controller).help(item.row.pod?.controllerName ?? "")
            }
        }.width(min: 92, ideal: 105)
        TableColumn("Node", value: \.node) { item in
            PodLink(value: item.node, action: { workspace.showPodNode(item.row) })
        }.width(min: 73, ideal: 100)
    }

    @TableColumnBuilder<PodTableItem, KeyPathComparator<PodTableItem>>
    private var statusColumns: some TableColumnContent<PodTableItem, KeyPathComparator<PodTableItem>> {
        let workspace = self.workspace
        TableColumn("QoS", value: \.qos) { ResourceCell(value: $0.qos) }
            .width(min: 76, ideal: 94)
        TableColumn("Status", value: \.status) { item in
            PodStatus(pod: item.row.pod)
        }.width(min: 85, ideal: 122)
        TableColumn("Age", value: \.age) { item in
            ResourceCell(value: item.row.age)
                .help(item.row.createdAt?.formatted(date: .abbreviated, time: .standard) ?? "")
        }.width(min: 45, ideal: 60)
        TableColumn("") { item in
            Menu {
                PodActions(workspace: workspace, row: item.row)
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize().help("Actions for " + item.name).accessibilityLabel("Actions for " + item.name)
        }.width(28)
    }

    private var metricsMessage: String {
        if workspace.podMetricsLoading { return "Loading pod metrics…" }
        return workspace.podMetricsError ?? "No usage sample for this pod."
    }
}

private struct PodActions: View {
    @ObservedObject var workspace: Workspace
    let row: ResourceRow

    var body: some View {
        Button("Inspect pod") { workspace.inspectPod(row) }
        Button("View logs…") { workspace.openPodLogs(row) }
            .disabled(row.namespace == nil || row.pod?.containers.isEmpty != false)
        Button("Open terminal…") { workspace.openPodTerminal(row) }
            .disabled(row.runningContainerNames.isEmpty)
        Button("Copy namespace/name") { copyPodNames([row]) }
        Divider()
        if row.namespace != nil {
            Button("Show namespace") { workspace.showPodNamespace(row) }
        }
        if workspace.podOwnerKind(row) != nil {
            Button("Show controller") { workspace.showPodOwner(row) }
        }
        if row.pod?.node != nil {
            Button("Show node") { workspace.showPodNode(row) }
        }
    }
}

private struct PodLink: View {
    let value: String
    var wraps = false
    let action: () -> Void

    var body: some View {
        if value.isEmpty {
            ResourceCell(value: "")
        } else {
            Button(action: action) {
                Text(verbatim: value).lineLimit(wraps ? nil : 1).truncationMode(.middle)
                    .multilineTextAlignment(.leading).font(.system(size: 11.5)).underline()
            }
            .buttonStyle(.plain).foregroundStyle(Palette.forest).help(value)
        }
    }
}

private extension PodUsage {
    var cpuText: String { "\(cpuMillicores)m" }

    var memoryText: String {
        let mib = Double(memoryBytes) / (1024 * 1024)
        return mib.formatted(.number.precision(.fractionLength(0...1))) + " MiB"
    }
}

private struct UsageCell: View {
    let text: String?
    let missing: String
    var body: some View {
        Text(verbatim: text ?? "—").font(.system(size: 11.5)).monospacedDigit()
            .foregroundStyle(Palette.muted).lineLimit(1).help(text ?? missing)
    }
}

private extension PodContainer {
    var roleText: String {
        switch role {
        case .app: "App"
        case .initContainer: "Init"
        case .ephemeral: "Ephemeral"
        }
    }

    var stateText: String {
        switch state {
        case .running: return ready ? "Running · Ready" : "Running · Not ready"
        case .waiting: return reason ?? "Waiting"
        case .terminated:
            let state = reason ?? "Terminated"
            return exitCode.map { state + " · Exit " + String($0) } ?? state
        case .unknown: return "Awaiting status"
        }
    }

    var color: Color {
        switch state {
        case .running: ready ? Palette.forest : .yellow
        case .waiting: .orange
        case .terminated: (exitCode ?? 0) == 0 ? Palette.muted : .red
        case .unknown: Palette.muted.opacity(0.6)
        }
    }

    var summary: String {
        "\(name) (\(roleText)) · \(stateText) · \(restartCount) " + (restartCount == 1 ? "restart" : "restarts")
    }
}

private struct ContainerIndicators: View {
    let containers: [PodContainer]
    var body: some View {
        if containers.isEmpty {
            ResourceCell(value: "")
        } else {
            HStack(spacing: 3) {
                ForEach(containers.prefix(5), id: \.name) { container in
                    RoundedRectangle(cornerRadius: 1).fill(container.color)
                        .frame(width: 7, height: 7).help(container.summary)
                }
                if containers.count > 5 {
                    Text("+\(containers.count - 5)").font(.system(size: 9))
                }
            }
            .help(containers.map(\.summary).joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(containers.map(\.summary).joined(separator: ", "))
        }
    }
}

private struct PodStatus: View {
    let pod: PodDetails?

    var body: some View {
        Text(verbatim: pod?.status ?? "—")
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
            .lineLimit(1).truncationMode(.tail).help(pod?.warning ?? pod?.status ?? "")
    }

    private var color: Color {
        if pod?.warning != nil { return .orange }
        switch pod?.status {
        case "Running", "Succeeded": return Palette.forest
        case "Failed": return .red
        default: return Palette.muted
        }
    }
}

struct PodInspector: View {
    @ObservedObject var workspace: Workspace
    let row: ResourceRow
    let onClose: () -> Void

    @State private var labelsExpanded = false
    @State private var annotationsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Pod").foregroundStyle(Palette.muted)
                Text(verbatim: row.name).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.middle).help(row.qualifiedPodName)
                Spacer(minLength: 4)
                IconAction(symbol: "text.alignleft", title: "View logs") { workspace.openPodLogs(row) }
                    .disabled(row.namespace == nil || row.pod?.containers.isEmpty != false)
                IconAction(symbol: "terminal", title: "Open terminal") { workspace.openPodTerminal(row) }
                    .disabled(row.runningContainerNames.isEmpty)
                IconAction(symbol: "doc.on.doc", title: "Copy namespace/name") { copyPodNames([row]) }
                IconAction(symbol: "xmark", title: "Close pod details", action: onClose)
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 43)
            .background(Palette.surface)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    metrics
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        heading("Properties").padding(.bottom, 7)
                        properties
                    }
                    .padding(14)
                    if let containers = row.pod?.containers, !containers.isEmpty {
                        Divider()
                        containerList(containers)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .font(.system(size: 12)).foregroundStyle(Palette.ink)
        .background(Palette.canvas)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var metrics: some View {
        let usage = row.namespace.flatMap { workspace.podMetrics[PodKey(namespace: $0, name: row.name)] }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                heading("Metrics")
                Spacer()
                if usage != nil {
                    Text("Latest sample").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
            }
            if let usage {
                HStack(spacing: 12) {
                    reading("CPU", value: usage.cpuText)
                    Divider().frame(height: 30)
                    reading("Memory", value: usage.memoryText)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line))
            } else if workspace.podMetricsLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading pod metrics…").foregroundStyle(Palette.muted)
                }
            } else {
                Label(workspace.podMetricsError ?? "No usage sample for this pod.", systemImage: "gauge.with.dots.needle.0percent")
                    .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private func reading(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(verbatim: value).font(.system(size: 16, weight: .medium)).monospacedDigit()
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var properties: some View {
        if let date = row.createdAt {
            field("Created") {
                Text(verbatim: row.age + " ago · " + date.formatted(date: .abbreviated, time: .shortened))
                    .help(date.formatted(date: .complete, time: .complete)).textSelection(.enabled)
            }
        }
        field("Name") { Text(verbatim: row.name).textSelection(.enabled) }
        if let ns = row.namespace {
            field("Namespace") { PodLink(value: ns, wraps: true) { workspace.showPodNamespace(row) } }
        }
        if let pod = row.pod {
            metadata("Labels", count: pod.labels.count, expanded: $labelsExpanded) {
                ForEach(pod.labels.keys.sorted(), id: \.self) { key in
                    Text(verbatim: key + "=" + (pod.labels[key] ?? ""))
                }
            }
            metadata("Annotations", count: pod.annotationKeys.count, expanded: $annotationsExpanded) {
                ForEach(pod.annotationKeys, id: \.self) { key in Text(verbatim: key) }
            }
            if let kind = pod.controllerKind, let name = pod.controllerName {
                field("Controlled by") {
                    if workspace.podOwnerKind(row) != nil {
                        PodLink(value: kind + "/" + name, wraps: true) { workspace.showPodOwner(row) }
                    } else {
                        Text(verbatim: kind + "/" + name).textSelection(.enabled)
                    }
                }
            }
            field("Status") {
                VStack(alignment: .leading, spacing: 4) {
                    PodStatus(pod: pod)
                    if let warning = pod.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            }
            if let node = pod.node {
                field("Node") { PodLink(value: node, wraps: true) { workspace.showPodNode(row) } }
            }
            if !pod.podIPs.isEmpty {
                field(pod.podIPs.count == 1 ? "Pod IP" : "Pod IPs") {
                    Text(verbatim: pod.podIPs.joined(separator: "\n")).textSelection(.enabled)
                }
            }
            if let account = pod.serviceAccount {
                field("Service account") { Text(verbatim: account).textSelection(.enabled) }
            }
            if let qos = pod.qos { field("QoS") { Text(verbatim: qos) } }
            field("Ready") { Text("\(pod.readyCount)/\(pod.readinessContainerCount)") }
            field("Restarts") { Text(String(pod.restartCount)) }
        }
    }

    private func field<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).foregroundStyle(Palette.muted).frame(width: 90, alignment: .leading)
                value().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7).fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }

    private func metadata<Content: View>(_ title: String, count: Int, expanded: Binding<Bool>,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            field(title) {
                if count == 0 {
                    Text("0").foregroundStyle(Palette.muted)
                } else {
                    Button { expanded.wrappedValue.toggle() } label: {
                        HStack(spacing: 6) {
                            Text(String(count)).monospacedDigit()
                            Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .medium))
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.forest)
                    .accessibilityLabel((expanded.wrappedValue ? "Hide " : "Show ") + title.lowercased())
                    .accessibilityValue(String(count))
                }
            }
            if expanded.wrappedValue, count > 0 {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                    .background(Palette.surface)
            }
        }
    }

    private func containerList(_ containers: [PodContainer]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Containers").padding(.bottom, 7)
            ForEach(containers, id: \.name) { container in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(container.color).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: container.name).fontWeight(.medium).textSelection(.enabled)
                        Text(verbatim: container.roleText + " · " + container.stateText)
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                    Text("\(container.restartCount) " + (container.restartCount == 1 ? "restart" : "restarts"))
                        .font(.system(size: 10.5)).foregroundStyle(Palette.muted).fixedSize()
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .padding(14)
    }
}
