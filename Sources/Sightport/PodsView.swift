import AppKit
import Accessibility
import SightportCore
import SwiftUI

extension PodDetails {
    fileprivate var statusColor: Color {
        if status == "Failed" { return .red }
        if warning != nil { return .orange }
        return status == "Running" || status == "Succeeded" ? Palette.forest : Palette.muted
    }

    func matches(_ query: String) -> Bool {
        [status, warning, controllerKind, controllerName, node, qos]
            .contains { $0?.localizedCaseInsensitiveContains(query) == true }
            || containers.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.reason?.localizedCaseInsensitiveContains(query) == true }
    }
}

private extension ResourceRow {
    var qualifiedPodName: String { namespace.map { $0 + "/" + name } ?? name }
}

@discardableResult
private func copyPodNames(_ rows: [ResourceRow]) -> Bool {
    guard !rows.isEmpty else { return false }
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(rows.map(\.qualifiedPodName).joined(separator: "\n"), forType: .string)
}

struct PodSelectionControls: View {
    let items: [PodTableItem]
    let visible: Set<String>
    @Binding var checked: Set<String>

    var body: some View {
        let count = checked.count
        let all = count > 0 && count == visible.count
        HStack(spacing: 4) {
            Button {
                checked = all ? [] : visible
            } label: {
                Image(systemName: all ? "checkmark.square.fill" : (count == 0 ? "square" : "minus.square.fill"))
                    .font(.system(size: 14))
                    .foregroundStyle(count == 0 ? Palette.muted : Palette.forest)
            }
            .buttonStyle(.plain).disabled(items.isEmpty)
            .help(all ? "Clear checked pods" : "Check all visible pods")
            .accessibilityLabel(all ? "Clear checked pods" : "Check all visible pods")
            if count > 0 {
                Button {
                    copyPodNames(items.filter { checked.contains($0.id) }.map(\.row))
                } label: {
                    Label(String(count), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .help(count == 1 ? "Copy the checked pod’s namespace/name" : "Copy the names of \(count) checked pods")
                .accessibilityLabel(count == 1 ? "Copy 1 checked pod name" : "Copy \(count) checked pod names")
            }
        }
        .fixedSize()
    }
}

struct PodTableItem: Identifiable, Equatable, Sendable {
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
    let items: [PodTableItem]
    let dataID: UUID?
    let scrollID: AnyHashable
    @Binding var checked: Set<String>
    @Binding var sort: [KeyPathComparator<PodTableItem>]

    private struct CellAppearance: Hashable {
        let checked: Set<String>
        let metricsMessage: String
    }

    var body: some View {
        let context = workspace.connectedContext
        let scope = workspace.namespaceFilter
        let selection = Binding<String?>(get: {
            if case .resource(let id) = workspace.selection { return id }
            return nil
        }, set: { id in
            guard workspace.page == .cluster(.resources(.pods)), workspace.connectedContext == context,
                  workspace.namespaceFilter == scope else { return }
            let item = id.map(WorkbenchItem.resource)
            if workspace.selection != item { workspace.select(item) }
        })
        let appearance = CellAppearance(checked: checked, metricsMessage: metricsMessage)
        return LiveResourceTable(items: items, dataID: AnyHashable(dataID), visualID: AnyHashable(appearance),
                                 scrollID: scrollID, columns: columns, selection: selection, sortOrder: $sort,
                                 menu: { actions(for: $0.row) }, doubleClick: { workspace.inspectPod($0.row) })
    }

    private var columns: [LiveColumn<PodTableItem>] {
        typealias Column = LiveColumn<PodTableItem>
        let missing = metricsMessage
        return [
            Column(id: "checked", title: "", width: 30, minWidth: 30) { item in
                .check(checked.contains(item.id), help: "Check " + item.name) {
                    if checked.remove(item.id) == nil { checked.insert(item.id) }
                }
            },
            Column(id: "name", title: "Name", width: 250, minWidth: 155, sort: KeyPathComparator(\.name)) {
                .text($0.name, color: NSColor(Palette.ink), bold: true, help: $0.name)
            },
            Column(id: "warning", title: "⚠", width: 32, minWidth: 32, sort: KeyPathComparator(\.warning)) {
                $0.warning.isEmpty ? .empty : .symbol("exclamationmark.triangle.fill", color: .systemOrange, help: $0.warning)
            },
            Column(id: "namespace", title: "Namespace", width: 112, minWidth: 85, sort: KeyPathComparator(\.namespace)) { item in
                item.namespace.isEmpty ? .resourceValue("") : .link(item.namespace) { workspace.showNamespace(of: item.row) }
            },
            Column(id: "cpu", title: "CPU", width: 65, minWidth: 50, sort: KeyPathComparator(\.cpu)) { item in
                let value = item.usage?.cpuText
                return .text(value ?? "—", color: NSColor(Palette.muted), help: value ?? missing)
            },
            Column(id: "memory", title: "Memory", width: 79, minWidth: 66, sort: KeyPathComparator(\.memory)) { item in
                let value = item.usage?.memoryText
                return .text(value ?? "—", color: NSColor(Palette.muted), help: value ?? missing)
            },
            Column(id: "containers", title: "Containers", width: 90, minWidth: 73, sort: KeyPathComparator(\.containerCount)) { item in
                guard let containers = item.row.pod?.containers, !containers.isEmpty else { return .resourceValue("") }
                return .indicators(containers.prefix(5).map { NSColor($0.color) }, extra: max(0, containers.count - 5),
                                   help: containers.map(\.summary).joined(separator: "\n"))
            },
            Column(id: "restarts", title: "Restarts", width: 66, minWidth: 58, sort: KeyPathComparator(\.restarts)) {
                .resourceValue(String($0.restarts))
            },
            Column(id: "owner", title: "Controlled By", width: 105, minWidth: 92, sort: KeyPathComparator(\.controller)) { item in
                guard workspace.podOwnerKind(item.row) != nil else { return .resourceValue(item.controller) }
                let help = [item.row.pod?.controllerKind, item.row.pod?.controllerName].compactMap { $0 }.joined(separator: "/")
                return .link(item.controller, help: help) { workspace.showPodOwner(item.row) }
            },
            Column(id: "node", title: "Node", width: 100, minWidth: 73, sort: KeyPathComparator(\.node)) { item in
                item.node.isEmpty ? .resourceValue("") : .link(item.node) { workspace.showPodNode(item.row) }
            },
            Column(id: "qos", title: "QoS", width: 94, minWidth: 76, sort: KeyPathComparator(\.qos)) { .resourceValue($0.qos) },
            Column(id: "status", title: "Status", width: 122, minWidth: 85, sort: KeyPathComparator(\.status)) { item in
                .text(item.row.pod?.status ?? "—", color: NSColor(item.row.pod?.statusColor ?? Palette.muted),
                      bold: true, help: item.row.pod?.warning ?? item.row.pod?.status)
            },
            Column(id: "age", title: "Age", width: 60, minWidth: 45, sort: KeyPathComparator(\.age)) { .age($0.row.createdAt) },
            Column(id: "actions", title: "", width: 32, minWidth: 32) { .menu(help: "Actions for " + $0.name) }
        ]
    }

    private func actions(for displayed: ResourceRow) -> NSMenu? {
        guard let row = workspace.resourceRow(id: displayed.id) else { return nil }
        let menu = NSMenu()
        menu.addAction("Inspect pod") { workspace.inspectPod(row) }
        menu.addAction("View logs…", enabled: row.namespace != nil && row.pod?.containers.isEmpty == false) {
            workspace.openPodLogs(row)
        }
        menu.addAction("Open terminal…", enabled: !row.runningContainerNames.isEmpty) { workspace.openPodTerminal(row) }
        menu.addAction("Copy namespace/name") { copyPodNames([row]) }
        menu.addItem(.separator())
        if row.namespace != nil { menu.addAction("Show namespace") { workspace.showNamespace(of: row) } }
        if workspace.podOwnerKind(row) != nil { menu.addAction("Show controller") { workspace.showPodOwner(row) } }
        if row.pod?.node != nil { menu.addAction("Show node") { workspace.showPodNode(row) } }
        menu.addItem(.separator())
        menu.addAction(workspace.isTerminatingPod(row) ? "Termination requested" : "Terminate Pod…",
                       enabled: workspace.canTerminatePod(row)) { workspace.requestPodTermination(row) }
        return menu
    }

    private var metricsMessage: String {
        if workspace.podMetricsLoading { return "Loading pod metrics…" }
        return workspace.podMetricsError ?? "No usage sample for this pod."
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

struct PodInspector: View {
    @ObservedObject var workspace: Workspace
    let row: ResourceRow
    let onClose: () -> Void

    @State private var labelsExpanded = false
    @State private var annotationsExpanded = false
    @State private var copySucceeded: Bool?
    @State private var copyAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identity
                    if let pod = row.pod {
                        health(pod)
                        properties(pod)
                        if !pod.containers.isEmpty, let context = workspace.connectedContext {
                            PodInspectedContainers(context: context, row: row, containers: pod.containers)
                                .id(context)
                        }
                        metadata(pod)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .font(.system(size: 12)).foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .disclosureGroupStyle(PodDisclosureStyle())
        .task(id: copyAttempt) {
            guard copySucceeded != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copySucceeded = nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            if let copySucceeded {
                Text(copySucceeded ? "Copied" : "Copy failed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copySucceeded ? Palette.forest : .orange)
            } else {
                Label("Pod", systemImage: "cube")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Spacer(minLength: 2)
            IconAction(symbol: "text.alignleft", title: "View logs") { workspace.openPodLogs(row) }
                .disabled(row.namespace == nil || row.pod?.containers.isEmpty != false)
            IconAction(symbol: "terminal", title: "Open terminal") { workspace.openPodTerminal(row) }
                .disabled(row.runningContainerNames.isEmpty)
            IconAction(symbol: copySucceeded.map { $0 ? "checkmark" : "exclamationmark.triangle" } ?? "doc.on.doc",
                       title: "Copy namespace/name") {
                let succeeded = copyPodNames([row])
                copySucceeded = succeeded
                copyAttempt += 1
                AccessibilityNotification.Announcement(succeeded ? "Pod name copied" : "Couldn’t copy the pod name").post()
            }
            IconAction(symbol: "trash", title: workspace.isTerminatingPod(row) ? "Termination requested" : "Terminate Pod…") {
                workspace.requestPodTermination(row)
            }
            .disabled(!workspace.canTerminatePod(row))
            Divider().frame(height: 14).padding(.horizontal, 3)
            IconAction(symbol: "xmark", title: "Close pod details", action: onClose)
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 39)
        .background(Palette.surface)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: row.name)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).accessibilityAddTraits(.isHeader)
            if let namespace = row.namespace {
                Button { workspace.showNamespace(of: row) } label: {
                    Label { Text(verbatim: namespace) } icon: { Image(systemName: "square.stack.3d.up") }
                }
                .buttonStyle(.plain).foregroundStyle(Palette.forest)
                .help("Show namespace " + namespace).accessibilityLabel("Namespace " + namespace)
            }
        }
    }

    private func health(_ pod: PodDetails) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    status(pod).fixedSize()
                    Spacer(minLength: 2)
                    counters(pod)
                }
                VStack(alignment: .leading, spacing: 8) {
                    status(pod)
                    counters(pod)
                }
            }
            if let warning = pod.warning, warning != pod.status,
               !pod.containers.contains(where: { $0.name + " · " + pod.status == warning }) {
                Text(verbatim: warning).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            metrics
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
    }

    private func status(_ pod: PodDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption("Status")
            HStack(spacing: 5) {
                Image(systemName: pod.warning == nil ? "circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: pod.warning == nil ? 7 : 11))
                Text(verbatim: pod.status).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(pod.statusColor)
            .help(pod.warning ?? pod.status)
        }
    }

    private func counters(_ pod: PodDetails) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                caption("Ready")
                Text("\(pod.readyCount)/\(pod.readinessContainerCount)")
            }
            VStack(alignment: .leading, spacing: 4) {
                caption("Restarts")
                Text(pod.restartCount.formatted())
            }
        }
        .font(.system(size: 13, weight: .semibold)).monospacedDigit().fixedSize()
    }

    @ViewBuilder private var metrics: some View {
        if let namespace = row.namespace, let usage = workspace.podMetrics[PodKey(namespace: namespace, name: row.name)] {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { readings(usage) }.fixedSize()
                VStack(alignment: .leading, spacing: 5) { readings(usage) }
            }
            .help("Latest pod usage from the cluster’s Metrics API")
        } else if workspace.podMetricsLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                caption("Loading metrics…")
            }
        } else {
            let reason = workspace.podMetricsError ?? "No usage sample for this pod."
            Label(workspace.podMetricsError == nil ? "No metrics sample" : "Metrics unavailable",
                  systemImage: "gauge.with.dots.needle.0percent")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .help(reason).accessibilityHint(reason)
        }
    }

    @ViewBuilder private func readings(_ usage: PodUsage) -> some View {
        HStack(spacing: 5) {
            caption("CPU")
            Text(verbatim: usage.cpuText).monospacedDigit()
        }
        HStack(spacing: 5) {
            caption("Memory")
            Text(verbatim: usage.memoryText).monospacedDigit()
        }
    }

    private func caption(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
    }

    private func properties(_ pod: PodDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Properties").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                if let date = row.createdAt {
                    field("Created") {
                        ViewThatFits(in: .horizontal) {
                            ResourceAgeText(createdAt: date, includeDate: true).fixedSize()
                            Text(verbatim: date.formatted(date: .abbreviated, time: .shortened))
                                .textSelection(.enabled)
                        }
                        .help(date.formatted(date: .complete, time: .complete))
                    }
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
                if let node = pod.node {
                    field("Node") { PodLink(value: node, wraps: true) { workspace.showPodNode(row) } }
                }
                if !pod.podIPs.isEmpty {
                    field(pod.podIPs.count == 1 ? "Pod IP" : "Pod IPs") {
                        Text(verbatim: pod.podIPs.joined(separator: "\n")).monospacedDigit().textSelection(.enabled)
                    }
                }
                if let account = pod.serviceAccount {
                    field("Service account") { Text(verbatim: account).textSelection(.enabled) }
                }
                if let qos = pod.qos { field("QoS") { Text(verbatim: qos) } }
            }
        }
    }

    private func field<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(title).foregroundStyle(Palette.muted).fixedSize()
            value().frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadata(_ pod: PodDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            metadataGroup("Pod labels", count: pod.labels.count, expanded: $labelsExpanded) {
                ForEach(pod.labels.keys.sorted(), id: \.self) { key in
                    Text(verbatim: key + "=" + (pod.labels[key] ?? ""))
                }
            }
            metadataGroup("Annotations", count: pod.annotationKeys.count, expanded: $annotationsExpanded) {
                ForEach(pod.annotationKeys, id: \.self) { key in Text(verbatim: key) }
            }
        }
    }

    private func metadataGroup<Content: View>(_ title: String, count: Int, expanded: Binding<Bool>,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 5) { content() }
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(count.formatted()).monospacedDigit().foregroundStyle(Palette.muted)
            }
        }
        .disabled(count == 0)
    }
}

private struct PodDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .modifier(PodDisclosureFeedback())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 6)
            }
        }
    }
}

private struct PodDisclosureFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var handPushed = false

    func body(content: Content) -> some View {
        content
            .background(hovered && isEnabled ? Palette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside
                showHand(inside && isEnabled)
            }
            .onChange(of: isEnabled) { _, enabled in showHand(hovered && enabled) }
            .onDisappear {
                hovered = false
                showHand(false)
            }
    }

    private func showHand(_ show: Bool) {
        guard handPushed != show else { return }
        handPushed = show
        if show { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}

private struct PodInspectedContainers: View {
    let context: ContextID
    let row: ResourceRow
    let containers: [PodContainer]

    @State private var expanded: Set<String>
    @State private var result: Result<PodInspection, Error>?
    @State private var attempt = 0

    init(context: ContextID, row: ResourceRow, containers: [PodContainer]) {
        self.context = context
        self.row = row
        self.containers = containers
        let initial = containers.first { $0.state == .waiting || ($0.exitCode ?? 0) != 0 } ?? containers.first
        _expanded = State(initialValue: initial.map { [$0.name] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Containers").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ForEach(containers, id: \.name) { container in
                let isExpanded = expanded.contains(container.name)
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if isExpanded { expanded.remove(container.name) } else { expanded.insert(container.name) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 14)).foregroundStyle(Palette.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: container.name).font(.system(size: 12, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 4) {
                                    Circle().fill(container.color).frame(width: 6, height: 6)
                                    Text(verbatim: container.roleText + " · " + container.stateText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 0)
                            Label(container.restartCount.formatted(), systemImage: "arrow.clockwise")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                                .fixedSize().help("Container restarts")
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                                .frame(width: 10)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(PodDisclosureFeedback())
                    }
                    .buttonStyle(.plain).background(Palette.raised)
                    .accessibilityLabel(container.summary)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    if isExpanded {
                        Divider()
                        details(for: container)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                    }
                }
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line).allowsHitTesting(false))
            }
        }
        .modifier(ResourceDetailRead(version: row.resourceVersion, attempt: attempt, load: {
            try await KubernetesClient().inspectPod(for: row, in: context.file, context: context.name)
        }, receive: { response in
            result = response
        }))
    }

    @ViewBuilder private func details(for container: PodContainer) -> some View {
        if let result {
            switch result {
            case .success(let inspection):
                if let info = inspection.containers[container.name] {
                    ContainerProperties(info: info)
                } else {
                    Text("Container details unavailable").foregroundStyle(Palette.muted)
                }
            case .failure(let error):
                VStack(alignment: .leading, spacing: 5) {
                    Text(error.localizedDescription).foregroundStyle(Palette.muted)
                    Button("Retry") { attempt += 1 }.controlSize(.small)
                }
            }
        } else {
            ProgressView("Loading container details…").controlSize(.small)
        }
    }
}

private struct ContainerProperties: View {
    let info: PodContainerInspection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(fields(in: .image), id: \.name) { field in
                VStack(alignment: .leading, spacing: 3) {
                    fieldLabel(field.name)
                    fieldValue(field.value, label: field.name, monospaced: true)
                }
            }
            fieldRows(fields(in: .runtime))
            fieldDisclosure("Image details & IDs", section: .imageDetails)
            fieldDisclosure("Configuration", section: .configuration)
            if !info.environment.isEmpty || !info.environmentFrom.isEmpty {
                DisclosureGroup("Environment") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(info.environmentFrom.enumerated()), id: \.offset) { _, source in
                            environmentValue("Import all keys", source)
                        }
                        ForEach(Array(info.environment.enumerated()), id: \.offset) { _, variable in
                            environmentValue(variable.name, variable.value)
                        }
                    }
                    .padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func fields(in section: PodContainerInspection.Section) -> [PodContainerInspection.Field] {
        info.properties.filter { $0.section == section }
    }

    @ViewBuilder private func fieldDisclosure(_ title: String, section: PodContainerInspection.Section) -> some View {
        let fields = fields(in: section)
        if !fields.isEmpty {
            DisclosureGroup(title) {
                fieldRows(fields).padding(.top, 6)
            }
        }
    }

    @ViewBuilder private func fieldRows(_ fields: [PodContainerInspection.Field]) -> some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fields, id: \.name) { field in
                    let value = fieldValue(field.value, label: field.name, monospaced: field.section != .runtime)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            fieldLabel(field.name).frame(width: 92, alignment: .leading)
                            value.frame(minWidth: 118, idealWidth: 118, maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            fieldLabel(field.name)
                            value
                        }
                    }
                }
            }
        }
    }

    private func environmentValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldLabel(label).textSelection(.enabled)
            fieldValue(value, label: label, monospaced: true)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func fieldValue(_ value: String, label: String, monospaced: Bool) -> some View {
        if value.isEmpty {
            Text("Empty value").foregroundStyle(Palette.muted)
        } else if value.utf8.count > 2048 || value.prefix(2048).filter({ $0 == "\n" }).count > 8 {
            ScrollableConfigValue(value: value, key: label).frame(height: 120)
        } else {
            Text(verbatim: value).font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
