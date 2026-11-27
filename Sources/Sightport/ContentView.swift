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
        .progressViewStyle(WorkbenchProgressStyle())
        .onAppear { workspace.setWindowVisible(true) }
        .onDisappear { workspace.setWindowVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            workspace.setWindowVisible(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            endWindowSessions()
        }
        .alert(item: $workspace.alert) { item in
            switch item.action {
            case .removeContext(let id):
                return Alert(title: Text("Remove from Sightport?"), message: Text(verbatim: item.message),
                             primaryButton: .cancel(), secondaryButton: .destructive(Text("Remove")) {
                                 Task { @MainActor in workspace.confirmContextRemoval(id) }
                             })
            case .workload(let request):
                return Alert(title: Text(request.action.title + "?"), message: Text(verbatim: item.message),
                             primaryButton: .cancel(), secondaryButton: .default(Text(request.action.title)) {
                                 workspace.confirmWorkloadAction(request)
                             })
            case .terminatePod(let request):
                return Alert(title: Text("Terminate Pod?"), message: Text(verbatim: item.message),
                             primaryButton: .cancel(), secondaryButton: .destructive(Text("Terminate Pod")) {
                                 workspace.confirmPodTermination(request)
                             })
            case nil:
                return Alert(title: Text("Sightport"), message: Text(verbatim: item.message), dismissButton: .default(Text("OK")))
            }
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
            if workspace.page == .cluster(.resources(.nodes)) {
                Rectangle().fill(Palette.line).frame(width: 1, height: 13)
                IconAction(symbol: "sidebar.right", title: workspace.showsNodeInspector ? "Hide node inspector" : "Show node inspector") {
                    if workspace.showsNodeInspector {
                        workspace.closeNodeInspector()
                    } else if let row = workspace.selectedResource(in: .nodes) {
                        workspace.inspectNode(row)
                    }
                }
                .disabled(workspace.selectedResource(in: .nodes) == nil)
            } else if usesBottomInspector {
                Rectangle().fill(Palette.line).frame(width: 1, height: 13)
                IconAction(symbol: "rectangle.bottomthird.inset.filled",
                           title: showsInspector ? "Hide inspector" : "Show inspector") { showsInspector.toggle() }
            }
        }
        .padding(.leading, 79).padding(.trailing, 12).frame(height: 39)
        .background { WindowDragSurface(onClose: endWindowSessions, onVisibility: workspace.setWindowVisible) }
        .background(Palette.surface)
    }

    private var usesBottomInspector: Bool {
        switch workspace.page {
        case .cluster(.resources(.pods)), .cluster(.resources(.nodes)), .cluster(.argoDashboard), .cluster(.portForwarding):
            return false
        default: return workspace.page.configDataKind == nil
        }
    }

    private var center: some View {
        VStack(spacing: 0) {
            tabBar
            if let notice = workspace.workloadNotice, case .cluster = workspace.page {
                HStack(spacing: 8) {
                    Image(systemName: notice.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(notice.failed ? Color.orange : Palette.forest)
                    Text(verbatim: notice.message).textSelection(.enabled)
                    Spacer()
                    IconAction(symbol: "xmark", title: "Dismiss message") { workspace.workloadNotice = nil }
                }
                .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 4)
                .background(Palette.surface)
                hairline
            }
            if workspace.page == .cluster(.resources(.pods)) {
                workspaceWithDrawer { width in
                    resourceSplit(.pods, width: width) { row in
                        PodInspector(workspace: workspace, row: row) { workspace.select(nil) }
                    }
                }
                .id(workspace.connectedContext)
            } else if workspace.page == .cluster(.resources(.nodes)) {
                GeometryReader { area in
                    resourceSplit(.nodes, width: area.size.width, showsDetails: workspace.showsNodeInspector) { _ in
                        ClusterResourceInspector(workspace: workspace)
                    }
                }
                .id(workspace.connectedContext)
            } else if workspace.page == .cluster(.resources(.deployments)) {
                workspaceWithDrawer { _ in standardWorkspace }.id(workspace.connectedContext)
            } else if let kind = workspace.page.configDataKind, let context = workspace.connectedContext {
                GeometryReader { area in
                    resourceSplit(kind, width: area.size.width) { row in
                        let showNamespace = { workspace.showNamespace(of: row) }
                        let close = { workspace.select(nil) }
                        if kind == .configMaps {
                            ConfigMapInspector(context: context, row: row, onShowNamespace: showNamespace, onClose: close)
                        } else {
                            SecretInspector(context: context, row: row, onShowNamespace: showNamespace, onClose: close)
                        }
                    }
                }
                .id(kind)
                .id(context)
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
        workspace.setWindowVisible(false)
        if workspace.page.configDataKind != nil { workspace.select(nil) }
        workspace.closePodTerminals()
        workspace.portForwards.stopAll()
    }

    private func resourceSplit<Details: View>(_ kind: ResourceKind, width: CGFloat, showsDetails: Bool = true,
                                              @ViewBuilder details: (ResourceRow) -> Details) -> some View {
        let compactInspector: CGFloat = kind == .pods ? 320 : 273
        let tableMinimum = min(300, max(218, width - compactInspector - 1))
        let detailsMinimum = min(272, max(220, width - tableMinimum - 1))
        let detailsWidth: CGFloat
        switch kind {
        case .pods:
            let preferred = min(480, max(360, width * 0.44))
            detailsWidth = min(preferred, width - tableMinimum - 1)
        case .nodes: detailsWidth = min(520, width * 0.41)
        default: detailsWidth = width * 0.41
        }
        return HSplitView {
            ClusterResourceTable(workspace: workspace, section: .resources(kind))
                .frame(minWidth: tableMinimum, idealWidth: width - detailsWidth, maxWidth: .infinity, maxHeight: .infinity)
            if showsDetails, let row = workspace.selectedResource(in: kind) {
                VStack(spacing: 0) {
                    details(row).id(row.id)
                }
                .frame(minWidth: detailsMinimum, idealWidth: max(detailsMinimum, detailsWidth),
                       maxWidth: max(detailsMinimum, width - tableMinimum - 1), maxHeight: .infinity)
                .background {
                    if kind == .nodes || kind == .pods { InitialInspectorWidth(width: detailsWidth) }
                }
            }
        }
    }

    private func workspaceWithDrawer<Content: View>(@ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        GeometryReader { geometry in
            let logsMinimum = min(220, max(148, geometry.size.height * 0.26))
            VSplitView {
                content(geometry.size.width)
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .layoutPriority(1)
                if workspace.activeDrawerTab != nil &&
                    (workspace.page == .cluster(.resources(.pods)) || workspace.podLogTarget?.kind == .deployments) {
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
                        .modifier(DisclosureHeaderFeedback())
                }
                .buttonStyle(.plain).background(Palette.surface).help("Show inspector")
                .accessibilityLabel("Expand inspector")
                .accessibilityValue("Collapsed")
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
            if workspace.pollingAfterWatchFailure, workspace.windowVisible {
                Text("·")
                Text("Refreshing every 5s")
                    .help("The watch connection is unavailable. Sightport is retrying it and refreshing this list.")
            }
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
            let connected = workspace.connectedContext == active
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
                    Text(tab.title).italic(workspace.previewTab == tab).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                }.padding(.leading, 13).padding(.trailing, 3)
                    .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.keepTabOpen(tab) })
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
        .contextMenu {
            if workspace.previewTab == tab { Button("Keep Tab Open") { workspace.keepTabOpen(tab) } }
            Button("Close Tab") { workspace.close(tab) }.disabled(workspace.tabs.count < 2)
        }
        .onHover { hovered = $0 }
    }

    private var tabHelp: String {
        if case .cluster(.customResources(let type)) = tab { return type.resourceName + " · " + type.version }
        return workspace.previewTab == tab ? tab.title + " · Preview. Double-click to keep open." : tab.title
    }
}

// HSplitView inserts a newly opened pane at its minimum width. Set the initial
// divider position once, then leave subsequent sizing to the native splitter.
private struct InitialInspectorWidth: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> NSView {
        let marker = NSView()
        DispatchQueue.main.async {
            var ancestor = marker.superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2,
                   marker.isDescendant(of: split.arrangedSubviews[1]) {
                    split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
                    return
                }
                ancestor = view.superview
            }
        }
        return marker
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct WindowDragSurface: NSViewRepresentable {
    var onClose: () -> Void
    var onVisibility: (Bool) -> Void

    final class Surface: NSView {
        var onClose: (() -> Void)?
        var onVisibility: ((Bool) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            NotificationCenter.default.removeObserver(self)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)),
                                                       name: NSWindow.willCloseNotification, object: newWindow)
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                           name: name, object: newWindow)
                }
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                       name: NSApplication.didUnhideNotification, object: nil)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func windowClosing(_ notification: Notification) { onClose?() }
        @objc private func visibilityChanged() {
            guard let window else { return }
            onVisibility?(window.isVisible && !window.isMiniaturized && !NSApp.isHidden)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.onClose = onClose
        view.onVisibility = onVisibility
    }
}
