import AppKit
import SightportCore
import SwiftUI

extension ResourceRow {
    var runningContainerNames: [String] {
        guard namespace != nil, let pod else { return [] }
        return pod.containers.filter { $0.state == .running }.map(\.name)
    }
}

@MainActor
final class PodTerminalTab: ObservableObject, Identifiable {
    enum State: Equatable {
        case ready, open, disconnected, exited(Int32), failed(String)
    }

    let id = UUID()
    let context: ContextID
    let podID: String
    let namespace: String
    let pod: String
    @Published private(set) var containers: [String]
    @Published var container: String
    @Published var shell = "/bin/sh"
    @Published private(set) var state = State.ready
    @Published private(set) var screen: PodTerminalScreen?

    private let client: KubernetesClient
    private var session: PodTerminalSession?
    private var generation: UUID?

    init(client: KubernetesClient, context: ContextID, podID: String, namespace: String,
         pod: String, containers: [String]) {
        self.client = client
        self.context = context
        self.podID = podID
        self.namespace = namespace
        self.pod = pod
        self.containers = containers
        self.container = containers.first ?? ""
    }

    func updateContainers(_ names: [String]) {
        guard names != containers else { return }
        containers = names
        if state != .open { selectAvailableContainer() }
    }

    private func selectAvailableContainer() {
        if !containers.contains(container) { container = containers.first ?? "" }
    }

    func connect() {
        guard session == nil, containers.contains(container) else { return }
        let token = UUID()
        generation = token
        let display = PodTerminalScreen()
        screen = display
        display.onInput = { [weak self] bytes in
            guard let self, generation == token, let session else { return }
            if !session.send(bytes) { NSSound.beep() }
        }
        display.onResize = { [weak self] columns, rows in
            guard let self, generation == token else { return }
            session?.resize(columns: columns, rows: rows)
        }
        do {
            session = try client.openPodTerminal(in: context.file, context: context.name, namespace: namespace,
                                                  pod: pod, container: container, shell: shell,
                                                  columns: max(1, display.columns), rows: max(1, display.rows),
                                                  onOutput: { [weak self] bytes in
                // The PTY reader can only advance as fast as the terminal consumes its output.
                DispatchQueue.main.sync {
                    guard let self, self.generation == token else { return }
                    self.screen?.receive(bytes)
                }
            }, onExit: { [weak self] code in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.generation = nil
                    self.session = nil
                    self.state = .exited(code)
                    self.selectAvailableContainer()
                }
            })
            state = .open
        } catch {
            generation = nil
            screen = nil
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        guard let session else { return }
        generation = nil
        self.session = nil
        session.close()
        state = .disconnected
        selectAvailableContainer()
    }
}

struct PodDrawer: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            header
            if let log = workspace.podLogTarget {
                PodLogsView(workspace: workspace, target: log,
                            isVisible: !workspace.podDrawerCollapsed && workspace.activeDrawerTab == .logs)
                    .id(log.id)
            }
            if !workspace.podDrawerCollapsed, case .terminal(let id) = workspace.activeDrawerTab,
               let tab = workspace.podTerminals.first(where: { $0.id == id }) {
                PodTerminalView(tab: tab).id(tab.id)
            }
        }
        .background(Palette.canvas)
    }

    private var header: some View {
        HStack(spacing: 3) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        if let target = workspace.podLogTarget {
                            drawerTab(.logs, title: "Logs", symbol: "text.alignleft", namespace: target.namespace,
                                      pod: target.name, close: workspace.closePodLogs)
                        }
                        ForEach(workspace.podTerminals) { tab in
                            drawerTab(.terminal(tab.id), title: "Terminal", symbol: "terminal", namespace: tab.namespace,
                                      pod: tab.pod) { workspace.closePodTerminal(tab) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: workspace.activeDrawerTab, initial: true) { _, tab in
                    if let tab { reader.scrollTo(tab) }
                }
            }
            Spacer(minLength: 0)
            let name = workspace.activeDrawerTab == .logs ? "logs" : "drawer"
            IconAction(symbol: workspace.podDrawerCollapsed ? "chevron.up" : "chevron.down",
                       title: (workspace.podDrawerCollapsed ? "Expand " : "Collapse ") + name,
                       action: workspace.togglePodDrawer)
                .padding(.trailing, 6)
        }
        .frame(height: 32)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func drawerTab(_ tab: PodDrawerTab, title: String, symbol: String, namespace: String,
                           pod: String, close: @escaping () -> Void) -> some View {
        let selected = tab == workspace.activeDrawerTab
        let fullName = namespace + "/" + pod
        return HStack(spacing: 2) {
            Button { workspace.showPodDrawerTab(tab) } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(selected ? Palette.forest : Palette.muted)
                    Text(title).fontWeight(.medium)
                    Text(verbatim: fullName).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Palette.muted)
                }
                .padding(.leading, 10).padding(.trailing, 3)
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + " for " + fullName)
            .accessibilityAddTraits(selected ? .isSelected : [])
            IconAction(symbol: "xmark", title: "Close " + title.lowercased(), action: close)
        }
        .font(.system(size: 12)).padding(.trailing, 2)
        .frame(maxWidth: 330).fixedSize(horizontal: true, vertical: false)
        .background(selected ? Palette.canvas : Palette.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
        .help(fullName).id(tab)
    }
}

private struct PodTerminalView: View {
    @ObservedObject var tab: PodTerminalTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if tab.state == .open {
                    Label(tab.container, systemImage: "shippingbox").lineLimit(1).truncationMode(.middle)
                    Text(verbatim: tab.shell).foregroundStyle(Palette.muted)
                        .font(.system(size: 11, design: .monospaced))
                    Spacer(minLength: 0)
                    Button("Disconnect", action: tab.disconnect)
                } else {
                    Picker("Container", selection: $tab.container) {
                        if tab.containers.isEmpty { Text("Unavailable").tag("") }
                        ForEach(tab.containers, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .accessibilityLabel("Terminal container").frame(maxWidth: 220)
                    Picker("Shell", selection: $tab.shell) {
                        Text("/bin/sh").tag("/bin/sh")
                        Text("/bin/bash").tag("/bin/bash")
                    }
                    .accessibilityLabel("Terminal shell").fixedSize()
                    Spacer(minLength: 0)
                    if case .exited(let code) = tab.state {
                        Text(code == 0 ? "Shell exited" : "Exit \(code)")
                            .foregroundStyle(Palette.muted).fixedSize()
                    }
                    Button(tab.state == .ready ? "Connect" : "Reconnect", action: tab.connect)
                        .disabled(tab.containers.isEmpty)
                }
            }
            .font(.system(size: 11.5)).controlSize(.small)
            .padding(.horizontal, 10).frame(height: 34)
            Divider()
            if let screen = tab.screen {
                PodTerminalSurface(screen: screen).id(ObjectIdentifier(screen))
            } else {
                let message = statusMessage
                Text(verbatim: message).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.sidebar)
    }

    private var statusMessage: String {
        if case .failed(let reason) = tab.state { return reason }
        if tab.containers.isEmpty { return "This pod has no running containers." }
        return "Choose a container and connect to start its shell."
    }
}
