import SightportCore
import SwiftUI

struct ResourceManifestButton: View {
    let context: ContextID
    let kind: InspectableResource
    let row: ResourceRow
    @State private var showing = false

    var body: some View {
        IconAction(symbol: "doc.text.magnifyingglass", title: "View YAML manifest") { showing = true }
            .sheet(isPresented: $showing) {
                ManifestSheet(context: context, kind: kind, row: row)
            }
    }
}

private struct ManifestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: ContextID
    let kind: InspectableResource
    let row: ResourceRow
    @State private var result: Result<String, Error>?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YAML manifest").font(.headline)
                    Text(verbatim: [context.name, row.namespace, row.name].compactMap { $0 }.joined(separator: " / "))
                        .foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle).help(row.name)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            switch result {
            case .success(let yaml):
                ScrollableConfigValue(value: yaml, key: row.name, lineCount: yaml.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 })
            case .failure(let error):
                VStack(spacing: 10) {
                    Text(error.localizedDescription)
                    Button("Retry") { result = nil; attempt += 1 }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 12)).foregroundStyle(Palette.ink).background(Palette.canvas)
        .frame(minWidth: 480, idealWidth: 730, minHeight: 320, idealHeight: 520)
        .task(id: attempt) {
            let next: Result<String, Error>
            do { next = .success(try await KubernetesClient().manifest(for: kind, row: row, context: context)) }
            catch { next = .failure(error) }
            if !Task.isCancelled { result = next }
        }
    }
}

private struct InspectionRead<Value, Content: View>: View {
    let version: String?
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var result: Result<Value, Error>?
    @State private var attempt = 0

    var body: some View {
        Group {
            switch result {
            case .success(let value): content(value)
            case .failure(let error):
                HStack {
                    Text(error.localizedDescription).foregroundStyle(Palette.muted)
                    Button("Retry") { result = nil; attempt += 1 }.controlSize(.small)
                }
            case nil: ProgressView().controlSize(.small)
            }
        }
        .modifier(ResourceDetailRead(version: version, attempt: attempt, load: load, receive: { result = $0 }))
    }
}

struct ServiceAccountAnnotationsView: View {
    let context: ContextID
    let row: ResourceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Annotations").font(.headline).accessibilityAddTraits(.isHeader)
            InspectionRead(version: row.resourceVersion, load: {
                try await KubernetesClient().serviceAccountAnnotations(row, context: context)
            }) { values in
                if values.isEmpty {
                    Text("No annotations").foregroundStyle(Palette.muted)
                } else {
                    ForEach(values.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: key).foregroundStyle(Palette.muted)
                            Text(verbatim: values[key] ?? "").font(.system(size: 12, design: .monospaced))
                        }.textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct NodeActionsView: View {
    let context: ContextID
    let row: ResourceRow
    @State private var confirm: NodeOperation?

    var body: some View {
        HStack(spacing: 6) {
            ResourceManifestButton(context: context, kind: .node, row: row)
            Button("Drain…") { confirm = .drain }.help("Drain node")
            Button("Delete…", role: .destructive) { confirm = .delete }.help("Delete node")
        }
        .controlSize(.small)
        .sheet(item: $confirm) { operation in
            NodeOperationSheet(context: context, row: row, operation: operation)
        }
    }
}

struct NodeInspectionView: View {
    let context: ContextID
    let row: ResourceRow
    @State private var showLabels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectionRead(version: row.resourceVersion, load: {
                try await KubernetesClient().nodeDetails(row, context: context)
            }) { node in
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                    field("Scheduling", node.unschedulable ? "Cordoned" : "Enabled")
                    field("Kernel", node.system.kernelVersion)
                    field("Architecture", node.system.architecture)
                    field("Container runtime", node.system.containerRuntimeVersion)
                    forAddresses(node)
                    forResources(node)
                    forConditions(node)
                    forTaints(node)
                }
                if let labels = node.labels, !labels.isEmpty {
                    DisclosureGroup("Labels (\(labels.count))", isExpanded: $showLabels) {
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(labels.keys.sorted(), id: \.self) { key in field(key, labels[key]) }
                        }.padding(.top, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder private func field(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(verbatim: title).foregroundStyle(Palette.muted)
                Text(verbatim: value).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func forAddresses(_ node: NodeDetails) -> some View {
        ForEach(Array((node.addresses ?? []).enumerated()), id: \.offset) { _, address in
            field(address.type, address.address)
        }
    }

    @ViewBuilder private func forResources(_ node: NodeDetails) -> some View {
        ForEach((node.capacity ?? [:]).keys.sorted(), id: \.self) { key in
            field(key, [node.capacity?[key], node.allocatable?[key].map { $0 + " allocatable" }].compactMap { $0 }.joined(separator: " · "))
        }
    }

    @ViewBuilder private func forConditions(_ node: NodeDetails) -> some View {
        ForEach(node.conditions ?? [], id: \.type) { condition in
            field(condition.type, [condition.status, condition.reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .help(condition.message ?? "")
        }
    }

    @ViewBuilder private func forTaints(_ node: NodeDetails) -> some View {
        ForEach(Array((node.taints ?? []).enumerated()), id: \.offset) { _, taint in
            field("Taint", taint.key + (taint.value.map { "=" + $0 } ?? "") + ":" + taint.effect)
        }
    }
}

private struct NodeOperationSheet: View {
    @EnvironmentObject private var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    let context: ContextID
    let row: ResourceRow
    let operation: NodeOperation
    @State private var task: Task<Void, Never>?
    @State private var result: String?

    var body: some View {
        let drain = operation == .drain
        VStack(alignment: .leading, spacing: 13) {
            Text(drain ? "Drain node?" : "Delete node?").font(.headline)
            Text(verbatim: row.name).fontWeight(.semibold).textSelection(.enabled)
            Text(verbatim: context.name).foregroundStyle(Palette.muted)
            Text(drain
                 ? "This cordons the node and evicts workloads using their grace periods and disruption budgets. DaemonSet and static pods stay. The node stays cordoned after the drain."
                 : "This deletes the Kubernetes Node object. Pods on the node may be disrupted. A running kubelet can register the node again.")
                .fixedSize(horizontal: false, vertical: true)
            if task != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(drain ? "Waiting for pods to leave the node…" : "Requesting deletion…")
                }
            }
            if let result { Text(verbatim: result).textSelection(.enabled) }
            HStack {
                Spacer()
                if let task {
                    Button(drain ? "Stop drain" : "Stop waiting") {
                        task.cancel()
                        result = drain ? "Drain stopped. Check the node’s scheduling status and remaining pods." :
                            "Check the Nodes list to confirm whether deletion was accepted."
                    }
                } else if result != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(drain ? "Drain node" : "Delete node", role: .destructive, action: perform)
                }
            }
        }
        .padding(20).frame(width: 420)
        .interactiveDismissDisabled(task != nil)
        .onDisappear { task?.cancel() }
    }

    private func perform() {
        guard task == nil, workspace.connectedContext == context, workspace.selectedResource(in: .nodes)?.id == row.id else {
            result = "The selection changed. Open the current node before trying again."
            return
        }
        task = Task { @MainActor in
            defer { task = nil }
            do {
                try await KubernetesClient().perform(operation, on: row, context: context)
                if !Task.isCancelled {
                    result = operation == .drain ? "Drain complete. The node is cordoned." : "The cluster accepted the node deletion."
                }
            } catch {
                if !Task.isCancelled { result = error.localizedDescription }
            }
        }
    }
}
