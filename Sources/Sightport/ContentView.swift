import SwiftUI
import SightportCore

struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace
    @AppStorage("showNavigator") private var showsNavigator = true
    @AppStorage("showInspector") private var showsInspector = true

    var body: some View {
        VStack(spacing: 0) {
            windowBar
            hairline
            HStack(spacing: 0) {
                WorkbenchRail()
                HSplitView {
                    if showsNavigator {
                        WorkbenchNavigator()
                            .frame(minWidth: 218, idealWidth: 235, maxWidth: 352, maxHeight: .infinity)
                    }
                    center.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }
            }
            statusBar
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .tint(Palette.forest)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            endWindowSessions()
        }
        .alert(item: $workspace.alert) { item in
            Alert(title: Text("Sightport"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }

    private var windowBar: some View {
        HStack(spacing: 7) {
            IconAction(symbol: "sidebar.left", title: showsNavigator ? "Hide navigator" : "Show navigator") {
                showsNavigator.toggle()
            }
            Rectangle().fill(Palette.line).frame(width: 1, height: 13)
            Text("Sightport").font(.system(size: 13, weight: .semibold))
            Text("/").font(.system(size: 11)).foregroundStyle(Palette.muted.opacity(0.6))
            if case .cluster = workspace.page, let context = workspace.connectedContext {
                Text(context.name).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .help(context.name + " · " + displayPath(context.file))
            } else {
                Text("Local workspace").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            IconAction(symbol: "folder.badge.plus", title: "Open kubeconfig (⌘O)") { workspace.chooseFile() }
            IconAction(symbol: "arrow.clockwise", title: "Refresh current view (⌘R)") { workspace.refresh() }
            if workspace.page != .cluster(.resources(.pods)), workspace.page != .cluster(.argoDashboard),
               workspace.page != .cluster(.portForwarding) {
                Rectangle().fill(Palette.line).frame(width: 1, height: 13)
                IconAction(symbol: "rectangle.bottomthird.inset.filled",
                           title: showsInspector ? "Hide inspector" : "Show inspector") { showsInspector.toggle() }
            }
        }
        .padding(.leading, 79).padding(.trailing, 12).frame(height: 39)
        .background { WindowDragSurface(onClose: endWindowSessions) }
        .background(Palette.surface)
    }

    private var center: some View {
        VStack(spacing: 0) {
            tabBar
            if workspace.page == .cluster(.resources(.pods)) {
                podWorkspace.id(workspace.connectedContext)
            } else if workspace.page == .cluster(.argoDashboard) {
                ClusterResourceTable(workspace: workspace, section: .argoDashboard)
                    .id(workspace.connectedContext)
            } else if workspace.page == .cluster(.portForwarding), let id = workspace.connectedContext {
                PortForwardingView(manager: workspace.portForwards, context: id, namespace: workspace.namespaceFilter,
                                   namespaces: workspace.namespaceNames).id(id)
            } else {
                standardWorkspace
            }
        }
        .background(Palette.canvas)
    }

    private func endWindowSessions() {
        workspace.closePodTerminals()
        workspace.portForwards.stopAll()
    }

    private var podWorkspace: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let tableMinimum = min(300, max(218, width - 274))
            let detailsMinimum = min(272, max(220, width - tableMinimum - 1))
            let logsMinimum = min(220, max(148, geometry.size.height * 0.26))
            VSplitView {
                HSplitView {
                    ClusterResourceTable(workspace: workspace, section: .resources(.pods))
                        .frame(minWidth: tableMinimum, idealWidth: width * 0.59,
                               maxWidth: .infinity, maxHeight: .infinity)
                    if let row = workspace.selectedPod {
                        PodInspector(workspace: workspace, row: row) { workspace.select(nil) }
                            .id(row.id)
                            .frame(minWidth: detailsMinimum, idealWidth: max(detailsMinimum, width * 0.41),
                                   maxWidth: max(detailsMinimum, width - tableMinimum - 1), maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .layoutPriority(1)
                if workspace.activeDrawerTab != nil {
                    let collapsed = workspace.podDrawerCollapsed
                    PodDrawer(workspace: workspace)
                        .frame(minHeight: collapsed ? 32 : logsMinimum,
                               idealHeight: collapsed ? 32 : max(195, logsMinimum), maxHeight: collapsed ? 32 : .infinity)
                }
            }
        }
    }

    private var standardWorkspace: some View {
        VStack(spacing: 0) {
            VSplitView {
                Group {
                    if case .cluster(let section) = workspace.page {
                        ClusterResourceTable(workspace: workspace, section: section)
                            .id(section).id(workspace.connectedContext)
                    } else {
                        WorkbenchTable()
                    }
                }
                .frame(minHeight: 146, maxHeight: .infinity)
                .layoutPriority(1)
                if showsInspector {
                    WorkbenchInspector { showsInspector = false }
                        .frame(minHeight: 179, idealHeight: 205, maxHeight: .infinity)
                }
            }
            if !showsInspector {
                hairline
                Button { showsInspector = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.bottomthird.inset.filled").foregroundStyle(Palette.forest)
                        Text("Inspector").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.up").font(.system(size: 10))
                    }.font(.system(size: 11.5))
                        .padding(.horizontal, 13).frame(height: 29)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).background(Palette.surface).help("Show inspector")
            }
        }
    }

    private var tabBar: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(workspace.tabs, id: \.self) { tab in
                        WorkspaceTab(tab: tab).id(tab)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: workspace.page) { _, tab in reader.scrollTo(tab) }
        }
        .frame(height: 37)
        .background(Palette.sidebar)
        .overlay(alignment: .bottom) { hairline }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "laptopcomputer")
            Text("Local workspace")
            Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1, height: 10).padding(.horizontal, 2)
            connectionStatus.lineLimit(1).truncationMode(.middle)
            Spacer()
            if workspace.loading {
                Text("Reading kubeconfig…")
            } else {
                let count = workspace.sources.reduce(0) { $0 + $1.contexts.count }
                Text("\(count) " + (count == 1 ? "context" : "contexts"))
                Text("·")
                Text("\(workspace.favorites.count) " + (workspace.favorites.count == 1 ? "favorite" : "favorites"))
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Color(rgb: 0xD4E9DC))
        .padding(.horizontal, 12).frame(height: 23)
        .background(Color(rgb: 0x284337))
    }

    @ViewBuilder private var connectionStatus: some View {
        if case .context(let file, let name) = workspace.selection,
           workspace.checks[ContextID(file: file, name: name)] == .checking {
            Text("Connecting to " + name + "…")
        } else if case .context(let file, let name) = workspace.selection,
                  case .failed(let reason) = workspace.checks[ContextID(file: file, name: name)] {
            Label("Connection failed · " + name, systemImage: "exclamationmark.circle")
                .help(reason)
        } else if let active = workspace.activeContext {
            let connected = workspace.checks[active] == .reachable
            Label((connected ? "Connected · " : "Last used · ") + active.name,
                  systemImage: connected ? "checkmark.circle" : "clock")
                .help(active.name + " · " + displayPath(active.file))
        } else {
            Text("No active context")
        }
    }

    private var hairline: some View { Rectangle().fill(Palette.line).frame(height: 1) }
}

private struct WorkspaceTab: View {
    @EnvironmentObject private var workspace: Workspace
    let tab: WorkbenchPage
    @State private var hovered = false

    var body: some View {
        let selected = tab == workspace.page
        HStack(spacing: 4) {
            Button { workspace.open(tab) } label: {
                HStack(spacing: 7) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Palette.forest : Palette.muted)
                    Text(tab.title).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                }.padding(.leading, 13).padding(.trailing, 3)
                    .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tabHelp)
            .accessibilityLabel(tab.title + " tab").accessibilityAddTraits(selected ? .isSelected : [])
            if workspace.tabs.count > 1 {
                Button { workspace.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        .frame(width: 17, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Close tab").accessibilityLabel("Close " + tab.title + " tab")
                .foregroundStyle(selected || hovered ? Palette.muted : Palette.muted.opacity(0.55))
            }
        }
        .padding(.trailing, 7).frame(maxWidth: 220, maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .background(selected ? Palette.canvas : (hovered ? Palette.surface : Palette.sidebar))
        .foregroundStyle(selected ? Palette.ink : Palette.muted)
        .overlay(alignment: .top) {
            if selected { Rectangle().fill(Palette.forest).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
        .onHover { hovered = $0 }
    }

    private var tabHelp: String {
        if case .cluster(.customResources(let type)) = tab { return type.resourceName + " · " + type.version }
        return tab.title
    }
}

private struct WindowDragSurface: NSViewRepresentable {
    var onClose: () -> Void

    final class Surface: NSView {
        var onClose: (() -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window { NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window) }
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)),
                                                       name: NSWindow.willCloseNotification, object: newWindow)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func windowClosing(_ notification: Notification) { onClose?() }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.onClose = onClose }
}
