import Accessibility
import SwiftUI
import SightportCore

@MainActor
final class PortForwardManager: ObservableObject {
    struct Entry: Identifiable {
        let id: UUID
        let context: ContextID
        let request: PortForwardRequest
        var status: PortForwardStatus?
    }

    @Published private(set) var entries: [Entry] = []
    private var sessions: [UUID: PortForwardSession] = [:]
    let client = KubernetesClient()

    func start(_ request: PortForwardRequest, in context: ContextID) throws {
        let id = UUID()
        let session = try client.openPortForward(in: context.file, context: context.name, request: request) { [weak self] status in
            DispatchQueue.main.async { [weak self] in self?.receive(status, for: id) }
        }
        entries.append(Entry(id: id, context: context, request: request))
        sessions[id] = session
    }

    private func receive(_ status: PortForwardStatus, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        if case .listening = status { return }
        sessions.removeValue(forKey: id)
    }

    func remove(_ id: UUID) {
        sessions.removeValue(forKey: id)?.stop()
        entries.removeAll { $0.id == id }
    }

    func stopAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        entries.removeAll()
    }
}

struct PortForwardingView: View {
    @EnvironmentObject private var workspace: Workspace
    @Environment(\.openURL) private var openURL
    @ObservedObject var manager: PortForwardManager
    let context: ContextID
    let namespace: String?
    let namespaces: [String]
    @State private var adding = false

    var body: some View {
        let entries = manager.entries.filter { $0.context == context }
        VStack(spacing: 0) {
            HStack {
                Text(entries.count == 1 ? "1 port forward" : "\(entries.count) port forwards")
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    workspace.keepTabOpen()
                    adding = true
                } label: { Label("New Forward…", systemImage: "plus") }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).frame(height: 38).background(Palette.surface)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "arrow.left.arrow.right").font(.title2)
                    Text("No port forwards").fontWeight(.medium)
                }
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            forwardRow(entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(Palette.ink).background(Palette.canvas)
        .sheet(isPresented: $adding) {
            PortForwardEditor(manager: manager, context: context, namespaces: namespaces,
                              namespace: namespace ?? "default")
        }
    }

    private func forwardRow(_ entry: PortForwardManager.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.request.kind == .pod ? "shippingbox" : "network")
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.request.kind.rawValue + "/" + entry.request.name).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                Text(entry.request.namespace + "  ·  Remote port " + entry.request.remotePort)
                    .foregroundStyle(Palette.muted)
                if case .failed(let message) = entry.status {
                    Text(message).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Spacer(minLength: 6)
            switch entry.status {
            case .listening(let port):
                Text("127.0.0.1:\(String(port))").monospacedDigit().foregroundStyle(Palette.forest)
                    .textSelection(.enabled)
                Menu("Open in browser") {
                    ForEach(["https", "http"], id: \.self) { scheme in
                        Button("Open \(scheme.uppercased())") {
                            if let url = URL(string: "\(scheme)://127.0.0.1:\(String(port))/") { openURL(url) }
                        }
                    }
                }
                .fixedSize()
                Button("Stop") { manager.remove(entry.id) }
            case .failed, .stopped:
                Button("Dismiss") { manager.remove(entry.id) }
            case nil:
                ProgressView().controlSize(.mini)
                Text("Connecting…").foregroundStyle(Palette.muted)
                Button("Cancel") { manager.remove(entry.id) }
            }
        }
        .controlSize(.small).padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct PortForwardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: Workspace
    let manager: PortForwardManager
    let context: ContextID
    let namespaces: [String]
    @State private var namespace: String
    private var pod: ResourceRow?
    @State private var kind: PortForwardTargetKind = .pod
    @State private var name = ""
    @State private var remote = ""
    @State private var local = ""
    @State private var options: [String] = []
    @State private var portLookup: PortLookup = .loading
    @State private var portAttempt = 0
    @State private var editedRemote = false
    @State private var error: String?

    private enum PortLookup {
        case loading, loaded([PodInspection.TCPPort]), failed(String)

        var ports: [PodInspection.TCPPort] {
            if case .loaded(let ports) = self { return ports }
            return []
        }

        var message: String {
            switch self {
            case .loading: return "Loading TCP ports…"
            case .loaded(let ports) where ports.isEmpty: return "No TCP ports declared. Enter a port number."
            case .loaded(let ports): return ports.count == 1 ? "1 TCP port available" : "\(ports.count) TCP ports available"
            case .failed: return "Couldn’t load TCP ports."
            }
        }
    }

    private struct Lookup: Equatable {
        let kind: PortForwardTargetKind
        let namespace: String
    }

    init(manager: PortForwardManager, context: ContextID, namespaces: [String], namespace: String) {
        self.manager = manager
        self.context = context
        self.namespaces = namespaces
        _namespace = State(initialValue: namespace)
    }

    init(manager: PortForwardManager, context: ContextID, pod: ResourceRow, knownPorts: [PodInspection.TCPPort]? = nil) {
        self.init(manager: manager, context: context, namespaces: [], namespace: pod.namespace ?? "")
        self.pod = pod
        if let knownPorts {
            _portLookup = State(initialValue: .loaded(knownPorts))
            _remote = State(initialValue: knownPorts.first.map { String($0.number) } ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New port forward").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if let pod {
                    GridRow {
                        Text("Namespace")
                        Text(verbatim: namespace)
                    }
                    GridRow {
                        Text("Pod")
                        Text(verbatim: pod.name).textSelection(.enabled)
                    }
                } else {
                    targetFields
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Remote port")
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            TextField("Number or port name", text: remoteInput)
                                .accessibilityLabel("Remote port")
                            if pod != nil { portMenu }
                        }
                        if let pod {
                            portStatus.task(id: portAttempt) { await loadPorts(for: pod) }
                        }
                    }
                }
                GridRow {
                    Text("Local port")
                    TextField("Automatic", text: $local)
                }
            }
            if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Forward") { start() }.keyboardShortcut(.defaultAction)
                    .disabled((pod == nil && name.isEmpty) || namespace.isEmpty || remote.isEmpty)
            }
        }
        .padding(20).frame(width: 403)
        .onChange(of: kind) { _, _ in name = ""; options = [] }
        .onChange(of: namespace) { _, _ in options = [] }
        .task(id: Lookup(kind: kind, namespace: namespace)) {
            guard pod == nil else { return }
            let ns = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ns.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(220))
                let names = try await manager.client.portForwardNames(kind, in: context.file, context: context.name, namespace: ns)
                guard !Task.isCancelled else { return }
                options = names
            } catch { /* Manual entry also works with permission to forward but no permission to list. */ }
        }
    }

    private var remoteInput: Binding<String> {
        Binding(get: { remote }, set: { value in
            // AppKit writes the current value back when the field gains focus.
            guard value != remote else { return }
            editedRemote = true
            remote = value
        })
    }

    private var portMenu: some View {
        Menu("Choose port") {
            ForEach(portLookup.ports, id: \.number) { port in
                Button(String(port.number) + (port.name.map { " · " + $0 } ?? "")) {
                    remoteInput.wrappedValue = String(port.number)
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(portLookup.ports.isEmpty)
        .accessibilityLabel("Choose TCP port").help("Choose a TCP port declared by the pod")
    }

    private var portStatus: some View {
        HStack(spacing: 5) {
            if case .loading = portLookup {
                ProgressView().controlSize(.mini)
                    .progressViewStyle(WorkbenchProgressStyle()).accessibilityHidden(true)
            }
            Text(verbatim: portLookup.message).fixedSize(horizontal: false, vertical: true)
            if case .failed(let reason) = portLookup {
                Button("Retry") {
                    portLookup = .loading
                    portAttempt += 1
                }
                .buttonStyle(.link).help(reason)
            }
        }
        .font(.caption).foregroundStyle(Palette.muted)
    }

    private func loadPorts(for pod: ResourceRow) async {
        guard case .loading = portLookup else { return }
        do {
            let inspection = try await manager.client.inspectPod(for: pod, in: context.file, context: context.name)
            guard !Task.isCancelled else { return }
            let ports = inspection.forwardablePorts
            portLookup = .loaded(ports)
            if !editedRemote, let first = ports.first { remote = String(first.number) }
        } catch {
            guard !Task.isCancelled else { return }
            portLookup = .failed(error.localizedDescription)
        }
        AccessibilityNotification.Announcement(portLookup.message).post()
    }

    @ViewBuilder private var targetFields: some View {
        GridRow {
            Text("Target type")
            Picker("Target type", selection: $kind) {
                Text("Pod").tag(PortForwardTargetKind.pod)
                Text("Service").tag(PortForwardTargetKind.service)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        GridRow {
            Text("Namespace")
            HStack(spacing: 4) {
                TextField("Namespace", text: $namespace)
                choices("Choose namespace", options: namespaces, selection: $namespace)
            }
        }
        GridRow {
            Text(kind == .pod ? "Pod name" : "Service name")
            HStack(spacing: 4) {
                TextField(kind == .pod ? "Pod name" : "Service name", text: $name)
                choices("Choose target", options: options, selection: $name)
            }
        }
    }

    private func choices(_ title: String, options: [String], selection: Binding<String>) -> some View {
        Menu {
            ForEach(options, id: \.self) { value in
                Button(value) { selection.wrappedValue = value }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(options.isEmpty).accessibilityLabel(title).help(title)
    }

    private func start() {
        do {
            let request: PortForwardRequest
            if let pod {
                request = try PortForwardRequest(pod: pod, localPort: local, remotePort: remote)
            } else {
                request = try PortForwardRequest(kind: kind, namespace: namespace, name: name, localPort: local, remotePort: remote)
            }
            try manager.start(request, in: context)
            dismiss()
            if pod != nil {
                workspace.keepTabOpen()
                workspace.open(.cluster(.portForwarding))
                workspace.keepTabOpen()
            }
        } catch { self.error = error.localizedDescription }
    }
}
