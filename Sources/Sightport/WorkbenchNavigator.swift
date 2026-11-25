import SightportCore
import SwiftUI

struct WorkbenchRail: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        let contexts = discoveredContexts
        let favorites = workspace.favorites.sorted(by: Self.precedes)
        let others = contexts.subtracting(workspace.favorites).sorted(by: Self.precedes)
        VStack(spacing: 0) {
            SightportMark().frame(width: 29, height: 29).padding(.vertical, 11)
            rule
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(favorites + others, id: \.self) { id in
                        VStack(spacing: 5) {
                            if !favorites.isEmpty && id == others.first {
                                rule.padding(.vertical, 4)
                            }
                            ContextRailButton(id: id, available: contexts.contains(id))
                        }
                    }
                    if favorites.isEmpty && others.isEmpty {
                        Text(workspace.loading ? "Loading…" : "No contexts")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center).padding(.horizontal, 5).padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 62)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context switcher")
    }

    private var rule: some View { Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 12) }

    private var discoveredContexts: Set<ContextID> {
        Set(workspace.sources.flatMap { source in
            source.contexts.map { ContextID(file: source.url, name: $0.name) }
        })
    }

    private static func precedes(_ lhs: ContextID, _ rhs: ContextID) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.file.path < rhs.file.path : order == .orderedAscending
    }
}

private struct ContextRailButton: View {
    @EnvironmentObject private var workspace: Workspace
    let id: ContextID
    let available: Bool
    @State private var hovered = false

    private var selected: Bool {
        if case .cluster = workspace.page { return workspace.connectedContext == id }
        return workspace.selection == .context(id.file, id.name)
    }
    private var active: Bool { workspace.activeContext == id }
    private var favorite: Bool { workspace.favorites.contains(id) }

    // EKS names end in “cluster/name” and kubeadm uses “user@cluster”.
    // Retain the full name and source file for the connect action and its tooltip.
    private var shortName: String {
        id.name.split(whereSeparator: { $0 == "/" || $0 == "@" }).last.map(String.init) ?? id.name
    }

    private var initials: String {
        let words = shortName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = words.first else { return String(shortName.prefix(2)).uppercased() }
        if words.count > 1, let last = words.last {
            return (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }

    private var tint: Color {
        let colors = [Palette.forest, Color(rgb: 0xA3C7E8), Color(rgb: 0xC7B4E5),
                      Color(rgb: 0xD9BD8B), Color(rgb: 0x9FD8D9), Color(rgb: 0xDAAFA8)]
        let index = (id.file.path + "/" + id.name).utf8.reduce(0) { ($0 * 31 + Int($1)) % colors.count }
        return colors[index]
    }

    private var failure: String? {
        if case .failed(let message) = workspace.checks[id] { return message }
        return nil
    }

    private var tooltip: String {
        let title = (available ? "Connect to " : "Inspect unavailable context ") + id.name
        return [title, displayPath(id.file), failure].compactMap { $0 }.joined(separator: "\n")
    }

    private var accessibilityStatus: String {
        var parts = [displayPath(id.file)]
        if favorite { parts.append("Favorite") }
        if active { parts.append("Active context") }
        if workspace.checks[id] == .checking { parts.append("Connecting") }
        if let failure { parts.append(failure) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let checking = workspace.checks[id] == .checking
        Button {
            if available { workspace.connect(id) } else { workspace.inspect(id) }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(tint.opacity(hovered ? 0.23 : 0.14))
                    RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(selected ? 0.85 : 0.32))
                    Text(initials)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                }
                .frame(width: 32, height: 31)
                .overlay(alignment: .topTrailing) {
                    if favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(rgb: 0xF1CD7F))
                            .padding(2).background(Palette.sidebar, in: Circle())
                            .offset(x: 4, y: -3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !available {
                        Image(systemName: "questionmark.circle.fill").font(.system(size: 10))
                            .foregroundStyle(Palette.muted).padding(1)
                            .background(Palette.sidebar, in: Circle()).offset(x: 3, y: 3)
                    } else if checking {
                        ProgressView().controlSize(.mini).padding(1)
                            .background(Palette.sidebar, in: Circle()).offset(x: 4, y: 3)
                    } else if failure != nil {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11))
                            .foregroundStyle(.orange).padding(1)
                            .background(Palette.sidebar, in: Circle()).offset(x: 3, y: 3)
                    } else if active && workspace.checks[id] == .reachable {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                            .foregroundStyle(Palette.forest).padding(1)
                            .background(Palette.sidebar, in: Circle()).offset(x: 3, y: 3)
                    }
                }
                Text(shortName)
                    .lineLimit(1).truncationMode(.tail)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
            }
            .padding(.top, 4).padding(.bottom, 3).padding(.horizontal, 3)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Palette.forest).frame(width: 2, height: 21) }
        }
        .onHover { hovered = $0 }
        .opacity(available ? 1 : 0.68)
        .help(tooltip)
        .accessibilityLabel((available ? "Connect to " : "Inspect unavailable context ") + id.name)
        .accessibilityValue(accessibilityStatus)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Inspect context") { workspace.inspect(id) }
            Button(favorite ? "Remove from favorites" : "Add to favorites") { workspace.toggleFavorite(id) }
        }
    }
}

private enum NavigatorGroup: String {
    case workloads = "Workloads", config = "Config", argo = "Argo CD", argoSettings = "Settings"
    case karpenter = "Karpenter", network = "Network", gateway = "Gateway API", storage = "Storage"
    case helm = "Helm", access = "Access Control", custom = "Custom Resources"
}

struct WorkbenchNavigator: View {
    @EnvironmentObject private var workspace: Workspace
    @State private var collectionsExpanded = true
    @State private var expanded: Set<NavigatorGroup> = [.argoSettings]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                Text("Navigator").fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 13).frame(height: 37)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { rule }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Workspace", expanded: $collectionsExpanded)
                    if collectionsExpanded { collectionRows }
                    if let context = workspace.connectedContext {
                        clusterNavigation(context)
                    }
                }
                .padding(.top, 10).padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            rule
            Button { workspace.chooseFile() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").frame(width: 17)
                    Text("Open kubeconfig…").lineLimit(1)
                    Spacer(minLength: 0)
                    Text("⌘O").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a local kubeconfig file")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Palette.ink)
        .background(Palette.surface)
        .onChange(of: workspace.connectedContext) { _, context in
            collectionsExpanded = context == nil
        }
        .onChange(of: workspace.page) { _, page in
            guard case .cluster(let section) = page else {
                collectionsExpanded = true
                return
            }
            switch section {
            case .overview: expanded.insert(.workloads)
            case .argoDashboard: expanded.insert(.argo)
            case .portForwarding: expanded.insert(.network)
            case .helmReleases: expanded.insert(.helm)
            case .customResources: expanded.insert(.custom)
            case .resources(let kind):
                if ResourceKind.workloads.contains(kind) { expanded.insert(.workloads) }
                if ResourceKind.configuration.contains(kind) { expanded.insert(.config) }
                if ResourceKind.argoResources.contains(kind) { expanded.insert(.argo) }
                if ResourceKind.argoSettings.contains(kind) { expanded.formUnion([.argo, .argoSettings]) }
                if ResourceKind.karpenter.contains(kind) { expanded.insert(.karpenter) }
                if ResourceKind.network.contains(kind) { expanded.insert(.network) }
                if ResourceKind.gatewayAPI.contains(kind) { expanded.formUnion([.network, .gateway]) }
                if ResourceKind.storage.contains(kind) { expanded.insert(.storage) }
                if ResourceKind.accessControl.contains(kind) { expanded.insert(.access) }
                if kind == .customResourceDefinitions { expanded.insert(.custom) }
            }
        }
    }

    @ViewBuilder private func clusterNavigation(_ context: ContextID) -> some View {
        rule.padding(.vertical, 8)
        HStack(spacing: 7) {
            Image(systemName: "helm").foregroundStyle(Palette.forest)
            Text(context.name).font(.system(size: 12, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(height: 29)
        .help(context.name + "\n" + displayPath(context.file))
        .accessibilityLabel("Connected cluster " + context.name)
        clusterRow(.resources(.namespaces), title: ResourceKind.namespaces.title, symbol: "square.grid.2x2")
        clusterRow(.resources(.nodes), title: ResourceKind.nodes.title, symbol: "server.rack")
        group(.argo, symbol: "arrow.triangle.2.circlepath")
        if expanded.contains(.argo) {
            clusterRow(.argoDashboard, title: "Dashboard")
            resourceRows(ResourceKind.argoResources)
            group(.argoSettings, symbol: "gearshape")
                .padding(.leading, 15)
            if expanded.contains(.argoSettings) { resourceRows(ResourceKind.argoSettings).padding(.leading, 15) }
        }
        group(.karpenter, symbol: "square.3.layers.3d")
        if expanded.contains(.karpenter) { resourceRows(ResourceKind.karpenter) }
        group(.workloads, symbol: "shippingbox")
        if expanded.contains(.workloads) {
            clusterRow(.overview, title: "Overview")
            resourceRows(ResourceKind.workloads)
        }
        group(.config, symbol: "slider.horizontal.3")
        if expanded.contains(.config) { resourceRows(ResourceKind.configuration) }
        networkNavigation
        group(.storage, symbol: "externaldrive")
        if expanded.contains(.storage) { resourceRows(ResourceKind.storage) }
        clusterRow(.resources(.events), title: "Events", symbol: "clock")
        group(.helm, symbol: "helm")
        if expanded.contains(.helm) { clusterRow(.helmReleases, title: "Releases") }
        group(.access, symbol: "shield.lefthalf.filled")
        if expanded.contains(.access) { resourceRows(ResourceKind.accessControl) }
        group(.custom, symbol: "puzzlepiece.extension")
        if expanded.contains(.custom) {
            clusterRow(.resources(.customResourceDefinitions), title: "Definitions")
            ForEach(workspace.tabs, id: \.self) { tab in
                if case .cluster(.customResources(let type)) = tab {
                    clusterRow(.customResources(type), title: type.kind).help(type.resourceName)
                }
            }
        }
    }

    @ViewBuilder private var networkNavigation: some View {
        group(.network, symbol: "arrow.up.arrow.down")
        if expanded.contains(.network) {
            resourceRows(ResourceKind.network)
            group(.gateway, symbol: "point.3.connected.trianglepath.dotted").padding(.leading, 15)
            if expanded.contains(.gateway) { resourceRows(ResourceKind.gatewayAPI).padding(.leading, 15) }
            clusterRow(.portForwarding, title: "Port Forwarding")
        }
    }

    private func resourceRows(_ kinds: [ResourceKind]) -> some View {
        ForEach(kinds, id: \.self) { kind in clusterRow(.resources(kind), title: kind.title) }
    }

    private func clusterRow(_ section: ClusterSection, title: String, symbol: String? = nil) -> some View {
        NavigatorRow(title: title, symbol: symbol, selected: workspace.page == .cluster(section)) {
            workspace.openCluster(section)
        }
    }

    private func group(_ group: NavigatorGroup, symbol: String) -> some View {
        let isExpanded = expanded.contains(group)
        return Button {
            if isExpanded { expanded.remove(group) } else { expanded.insert(group) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 9)
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 15)
                Text(group.rawValue).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.ink).padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(group.rawValue)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var rule: some View { Rectangle().fill(Palette.line).frame(height: 1) }

    private func section(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold)).frame(width: 10)
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    @ViewBuilder private var collectionRows: some View {
        NavigatorRow(title: "All contexts", symbol: "point.3.connected.trianglepath.dotted",
                     selected: workspace.page == .contexts,
                     count: workspace.sources.reduce(0) { $0 + $1.contexts.count }) {
            workspace.open(.contexts)
        }
        NavigatorRow(title: "Favorites", symbol: "star",
                     selected: workspace.page == .favorites,
                     count: workspace.favorites.count) {
            workspace.open(.favorites)
        }
        NavigatorRow(title: "Kubeconfig files", symbol: "folder", selected: workspace.page == .files,
                     count: workspace.sources.count) {
            workspace.open(.files)
        }
    }
}

private struct NavigatorRow: View {
    let title: String
    let symbol: String?
    let selected: Bool
    var count: Int?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Palette.forest : Palette.muted)
                        .frame(width: 15)
                } else {
                    Rectangle().fill(Palette.line).frame(width: 1)
                        .padding(.leading, 10).padding(.trailing, 8)
                }
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text(String(count)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
            }
            .foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.87))
            .padding(.horizontal, 11).frame(height: symbol == nil ? 24 : 27).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(count.map(String.init) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .background(selected ? Palette.selection : hovered ? Palette.raised : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovered = $0 }
        .padding(.horizontal, 5)
    }
}
