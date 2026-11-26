import AppKit
import SwiftUI
import SightportCore

enum ClusterSection: Hashable {
    case resources(ResourceKind)
    case overview
    case argoDashboard
    case helmReleases
    case customResources(CustomResourceType)
    case portForwarding

    var title: String {
        switch self {
        case .resources(let kind): return kind.title
        case .overview: return "Workload overview"
        case .argoDashboard: return "Argo CD Dashboard"
        case .helmReleases: return "Helm Releases"
        case .customResources(let type): return type.kind
        case .portForwarding: return "Port Forwarding"
        }
    }

    var listKind: ResourceKind? {
        switch self {
        case .resources(let kind): return kind
        case .argoDashboard: return .argoApplications
        default: return nil
        }
    }

    var isNamespaced: Bool {
        if case .customResources(let type) = self { return type.isNamespaced }
        return listKind?.isNamespaced ?? true
    }

    var columns: [String] {
        switch self {
        case .helmReleases: return HelmReleases.columns
        case .customResources: return CustomResourceType.columns
        default: return listKind?.columns ?? []
        }
    }
}

enum WorkloadCount: Equatable {
    case loading, count(Int), failed(String)
}

enum WorkbenchPage: Hashable {
    case contexts, favorites, files
    case file(URL)
    case cluster(ClusterSection)

    var configDataKind: ResourceKind? {
        guard case .cluster(.resources(let kind)) = self, kind == .configMaps || kind == .secrets else { return nil }
        return kind
    }

    var title: String {
        switch self {
        case .contexts: return "Contexts"
        case .favorites: return "Favorites"
        case .files: return "Kubeconfig files"
        case .file(let url): return url.lastPathComponent
        case .cluster(let section): return section.title
        }
    }

    var symbol: String {
        switch self {
        case .contexts: return "point.3.connected.trianglepath.dotted"
        case .favorites: return "star"
        case .files: return "folder"
        case .file: return "doc.text"
        case .cluster: return "shippingbox"
        }
    }
}

enum WorkbenchItem: Hashable {
    case context(URL, String)
    case file(URL)
    case resource(String)
}

struct SourceFile: Identifiable {
    var id: URL { url }
    let url: URL
    var contexts: [KubeContext] = []
    var error: String?
}

struct WorkspaceAlert: Identifiable {
    let id = UUID()
    let message: String
}

struct PodLogTarget: Identifiable {
    let id = UUID()
    let podID: String
    let context: ContextID
    let namespace: String
    let name: String
    var containers: [PodContainer]
}

enum PodDrawerTab: Hashable {
    case logs
    case terminal(UUID)
}

private struct LinkedResource {
    let name: String
    let namespace: String?
    let uid: String?
}

enum Reachability: Equatable {
    case checking
    case reachable
    case failed(String)
}

@MainActor
final class Workspace: ObservableObject {
    let portForwards = PortForwardManager()
    @Published private(set) var tabs: [WorkbenchPage] = [.contexts, .favorites]
    @Published private(set) var page = WorkbenchPage.contexts
    @Published private(set) var selection: WorkbenchItem?
    @Published private(set) var favorites: Set<ContextID> = []
    @Published private(set) var activeContext: ContextID?
    @Published private(set) var sources: [SourceFile] = []
    @Published private(set) var loading = false
    @Published private(set) var checks: [ContextID: Reachability] = [:]
    @Published var alert: WorkspaceAlert?

    @Published private(set) var connectedContext: ContextID?
    @Published private(set) var rows: [ResourceRow] = []
    @Published private(set) var windowVisible = true
    @Published private(set) var detailRefreshID = 0
    @Published private(set) var pollingAfterWatchFailure = false
    @Published private(set) var resourceLoading = false
    @Published private(set) var resourceError: String?
    @Published private(set) var namespaceNames: [String] = []
    @Published private(set) var namespaceError: String?
    @Published private(set) var namespaceFilter: String?
    @Published private(set) var overview: [ResourceKind: WorkloadCount] = [:]
    @Published private(set) var podMetrics: [PodKey: PodUsage] = [:]
    @Published private(set) var podMetricsLoading = false
    @Published private(set) var podMetricsError: String?
    @Published private(set) var podLogTarget: PodLogTarget?
    @Published private(set) var podTerminals: [PodTerminalTab] = []
    @Published private(set) var activeDrawerTab: PodDrawerTab?
    @Published private(set) var podDrawerCollapsed = false

    func selectedResource(in kind: ResourceKind) -> ResourceRow? {
        guard page == .cluster(.resources(kind)), case .resource(let id) = selection else { return nil }
        return rows.first { $0.id == id }
    }

    private var resourceTask: Task<Void, Never>?
    private var resourceGeneration = UUID()
    private var metricsTask: Task<Void, Never>?
    private var linkedResource: LinkedResource?
    private var namespaceTask: Task<Void, Never>?

    private let repository = ContextPreferencesRepository()
    private let client = KubernetesClient()
    private let defaults = UserDefaults.standard
    private var tabSelections: [WorkbenchPage: WorkbenchItem] = [:]
    private var rememberedContext: ContextID?
    private var readTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var pendingConnection: ContextID?
    private var otherPaths: [String] { defaults.stringArray(forKey: "sourceFiles") ?? [] }
    private var legacyActiveID: UUID? {
        defaults.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:))
    }

    init() {
        do {
            let preferences = try loadPreferences()
            favorites = preferences.favorites
            rememberedContext = preferences.activeContext
        } catch {
            alert = WorkspaceAlert(message: "Could not load context preferences. " + error.localizedDescription)
        }
        refresh()
    }

    func context(for id: ContextID) -> KubeContext? {
        sources.first { $0.url == id.file }?.contexts.first { $0.name == id.name }
    }

    func open(_ destination: WorkbenchPage) {
        if case .file(let file) = destination, !sources.contains(where: { $0.url == file }) { return }
        if case .cluster = destination, connectedContext == nil { return }
        if !tabs.contains(destination) { tabs.append(destination) }
        guard page != destination else { return }
        if page == .cluster(.resources(.pods)) { closePodLogs() }
        if page.configDataKind != nil { select(nil) }
        page = destination
        if case .cluster(let section) = destination {
            loadSection(section)
        } else {
            clearResourceTable()
            restoreSelection()
        }
    }

    func close(_ tab: WorkbenchPage) {
        guard tabs.count > 1, let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if tab == .cluster(.resources(.pods)) { closePodTerminals() }
        tabSelections.removeValue(forKey: tab)
        if page == tab { open(tabs[min(index, tabs.count - 1)]) }
    }

    func select(_ item: WorkbenchItem?) {
        if selection != item { selection = item }
        tabSelections[page] = item
    }

    func inspect(_ id: ContextID) {
        if context(for: id) == nil {
            guard favorites.contains(id) else { return }
            open(.favorites)
        } else {
            switch page {
            case .contexts: break
            case .favorites where favorites.contains(id): break
            case .file(let url) where url == id.file: break
            default: open(.contexts)
            }
        }
        select(.context(id.file, id.name))
    }

    func connect(_ id: ContextID) {
        inspect(id)
        guard context(for: id) != nil, pendingConnection != id else { return }
        cancelConnectionAttempt()
        checks[id] = .checking
        pendingConnection = id
        connectTask = Task {
            defer {
                if !Task.isCancelled {
                    pendingConnection = nil
                    connectTask = nil
                }
            }
            do {
                try await client.testConnection(in: id.file, context: id.name)
                guard !Task.isCancelled else { return }
                guard context(for: id) != nil else {
                    checks.removeValue(forKey: id)
                    return
                }
                checks[id] = .reachable
                activeContext = id
                rememberedContext = id
                updatePreferences { $0.activeContext = id }
                startCluster(id)
            } catch {
                guard !Task.isCancelled else { return }
                checks[id] = .failed(error.localizedDescription)
                if connectedContext == id { endCluster() }
            }
        }
    }

    func toggleFavorite(_ id: ContextID) {
        guard favorites.contains(id) || context(for: id) != nil else { return }
        let add = !favorites.contains(id)
        updatePreferences { preferences in
            if add { preferences.favorites.insert(id) } else { preferences.favorites.remove(id) }
        }
        if page == .favorites { restoreSelection() }
    }

    // Re-read before writing so a failed or unreadable migration can be retried
    // without replacing the user's existing preferences with empty defaults.
    private func updatePreferences(_ change: (inout ContextPreferences) -> Void) {
        do {
            var next = try loadPreferences()
            change(&next)
            try repository.save(next)
            favorites = next.favorites
        } catch {
            alert = WorkspaceAlert(message: "Could not save context preferences. " + error.localizedDescription)
        }
    }

    private func loadPreferences() throws -> ContextPreferences {
        try repository.load(legacyActiveID: legacyActiveID) { files in
            let knownDefaults = Set(client.defaultSources().map { $0.standardizedFileURL.path })
            let custom = files.map { $0.standardizedFileURL.path }.filter { !knownDefaults.contains($0) }
            var seen = Set(otherPaths)
            let additions = custom.filter { seen.insert($0).inserted }
            if !additions.isEmpty { defaults.set(otherPaths + additions, forKey: "sourceFiles") }
        }
    }

    private func restoreSelection() {
        let previous = tabSelections[page]
        switch page {
        case .cluster:
            if case .resource(let id) = previous, rows.contains(where: { $0.id == id }) {
                select(previous)
            } else if page == .cluster(.resources(.pods)) || page.configDataKind != nil {
                select(nil)
            } else { select(rows.first.map { .resource($0.id) }) }
        case .files:
            if case .file(let file) = previous, sources.contains(where: { $0.url == file }) {
                select(previous)
            } else { select(sources.first.map { .file($0.url) }) }
        case .favorites:
            if case .context(let url, let name) = previous, favorites.contains(ContextID(file: url, name: name)) {
                select(previous)
            } else {
                let first = favorites.sorted {
                    $0.name == $1.name ? $0.file.path < $1.file.path : $0.name < $1.name
                }.first
                let target = activeContext.flatMap { favorites.contains($0) ? $0 : nil } ?? first
                select(target.map { .context($0.file, $0.name) })
            }
        case .contexts, .file:
            let list: [SourceFile]
            if case .file(let url) = page { list = sources.filter { $0.url == url } }
            else { list = sources }
            if case .context(let file, let name) = previous,
               list.first(where: { $0.url == file })?.contexts.contains(where: { $0.name == name }) == true {
                select(previous)
            } else if let activeContext, list.contains(where: { $0.url == activeContext.file }),
                      context(for: activeContext) != nil {
                select(.context(activeContext.file, activeContext.name))
            } else if let source = list.first(where: { !$0.contexts.isEmpty }),
                      let item = source.contexts.first(where: \.isCurrent) ?? source.contexts.first {
                select(.context(source.url, item.name))
            } else { select(nil) }
        }
    }

    func refresh() {
        if case .cluster = page { reloadResources() } else { refreshSources() }
    }

    private func refreshSources() {
        readTask?.cancel()
        cancelConnectionAttempt()
        let previousID = connectedContext
        let previousContext = previousID.flatMap { context(for: $0) }
        checks = checks.filter { $0.key == connectedContext }
        var seen = Set<String>()
        let files = (client.defaultSources() + otherPaths.map { URL(fileURLWithPath: $0) })
            .map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        let previous = sources
        sources = files.map { file in previous.first { $0.url == file } ?? SourceFile(url: file) }
        for tab in tabs {
            if case .file(let url) = tab, !files.contains(url) {
                if tabs.count == 1 { open(.contexts) }
                close(tab)
            }
        }
        loading = !files.isEmpty
        readTask = Task {
            for file in files {
                var source = SourceFile(url: file)
                do { source.contexts = try await client.contexts(in: file) }
                catch { source.error = error.localizedDescription }
                guard !Task.isCancelled else { return }
                if let index = sources.firstIndex(where: { $0.url == file }) { sources[index] = source }
            }
            guard !Task.isCancelled else { return }
            if let pendingConnection, context(for: pendingConnection) == nil { cancelConnectionAttempt() }
            if let connectedContext, previousID == connectedContext,
               context(for: connectedContext) == nil || context(for: connectedContext)?.cluster != previousContext?.cluster {
                checks.removeValue(forKey: connectedContext)
                endCluster()
            }
            activeContext = rememberedContext.flatMap { context(for: $0) == nil ? nil : $0 }
            loading = false
            restoreSelection()
        }
    }

    private func cancelConnectionAttempt() {
        connectTask?.cancel()
        connectTask = nil
        if let pendingConnection { checks.removeValue(forKey: pendingConnection) }
        pendingConnection = nil
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Open kubeconfig"
        panel.prompt = "Open"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        if !client.defaultSources().map(\.standardizedFileURL).contains(url), !otherPaths.contains(url.path) {
            defaults.set(otherPaths + [url.path], forKey: "sourceFiles")
        }
        refreshSources()
        open(.file(url))
    }

    func canForget(_ url: URL) -> Bool {
        otherPaths.contains(url.path) && !client.defaultSources().map(\.standardizedFileURL).contains(url)
    }

    func forget(_ url: URL) {
        defaults.set(otherPaths.filter { $0 != url.path }, forKey: "sourceFiles")
        refreshSources()
    }
}

func displayPath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

extension Workspace {
    private func startCluster(_ id: ContextID) {
        if connectedContext != id {
            endCluster()
            connectedContext = id
            namespaceFilter = context(for: id)?.namespace.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        }
        openCluster(.resources(.namespaces))
    }

    private func endCluster() {
        portForwards.stopAll()
        closePodLogs()
        closePodTerminals()
        namespaceNames = []
        namespaceError = nil
        namespaceFilter = nil
        connectedContext = nil
        clearResourceTable()
        tabs.removeAll { if case .cluster = $0 { return true }; return false }
        tabSelections = tabSelections.filter { if case .cluster = $0.key { return false }; return true }
        if tabs.isEmpty { tabs = [.contexts] }
        if case .cluster = page { open(.contexts) }
    }

    func openCluster(_ section: ClusterSection) {
        open(.cluster(section))
    }

    func setNamespace(_ name: String?) {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = value?.isEmpty == true ? nil : value
        guard connectedContext != nil, scope != namespaceFilter else { return }
        if page.configDataKind != nil { select(nil) }
        if let scope, let target = podLogTarget, target.namespace != scope { closePodLogs() }
        namespaceFilter = scope
        if case .cluster(let section) = page, section.isNamespaced {
            loadSection(section)
        }
    }

    func reloadResources() {
        guard case .cluster(let section) = page else { return }
        detailRefreshID &+= 1
        loadSection(section, refresh: true)
    }

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        if visible, case .cluster(let section) = page {
            loadSection(section, refresh: true)
        } else if !visible {
            stopResourceReads()
        }
    }

    private func stopResourceReads() {
        resourceGeneration = UUID()
        resourceTask?.cancel()
        resourceTask = nil
        metricsTask?.cancel()
        metricsTask = nil
        namespaceTask?.cancel()
        namespaceTask = nil
    }

    private func clearResourceTable() {
        stopResourceReads()
        rows = []
        podMetrics = [:]
        podMetricsLoading = false
        podMetricsError = nil
        linkedResource = nil
        resourceError = nil
        pollingAfterWatchFailure = false
        overview = [:]
        resourceLoading = false
    }

    private func loadSection(_ section: ClusterSection, refresh: Bool = false) {
        guard let id = connectedContext else { return }
        if refresh {
            stopResourceReads()
        } else {
            clearResourceTable()
            selection = nil
        }
        guard windowVisible else { return }
        let scope = section.isNamespaced ? namespaceFilter : nil
        resourceLoading = rows.isEmpty && overview.isEmpty
        if section.isNamespaced {
            namespaceTask = Task {
                await observeRows(.resources(.namespaces), in: id, scope: nil, onRows: { result in
                    self.updateNamespaces(result)
                }, onError: { error in
                    self.namespaceError = error.localizedDescription
                    self.namespaceNames = []
                })
            }
        }

        switch section {
        case .overview:
            resourceTask = Task {
                while !Task.isCancelled {
                    await loadWorkloadCounts(in: id, namespace: scope)
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        case .portForwarding:
            resourceLoading = false
        default:
            resourceTask = Task {
                await observeRows(section, in: id, scope: scope, onRows: { result in
                    self.applyRows(result, section: section, context: id, namespace: scope)
                }, onError: { error in
                    self.rows = []
                    self.selection = nil
                    self.resourceError = error.localizedDescription
                    self.resourceLoading = false
                    if section == .resources(.pods) { self.closePodLogs() }
                    if section == .resources(.namespaces) {
                        self.namespaceError = error.localizedDescription
                        self.namespaceNames = []
                    }
                }, onPolling: { polling in
                    if self.pollingAfterWatchFailure != polling { self.pollingAfterWatchFailure = polling }
                })
            }
        }
    }

    private func observeRows(_ section: ClusterSection, in id: ContextID, scope: String?,
                             onRows: @escaping @MainActor ([ResourceRow]) -> Void,
                             onError: @escaping @MainActor (Error) -> Void,
                             onPolling: @escaping @MainActor (Bool) -> Void = { _ in }) async {
        let generation = resourceGeneration
        let target: ResourceWatchTarget?
        if case .customResources(let type) = section {
            target = .custom(type)
        } else {
            target = section.listKind.map(ResourceWatchTarget.resource)
        }
        while !Task.isCancelled {
            if let target {
                let started = ContinuousClock.now
                do {
                    try await client.watchResources(target, in: id.file, context: id.name, namespace: scope) { rows in
                        await MainActor.run {
                            guard !Task.isCancelled, self.resourceGeneration == generation else { return }
                            onPolling(false)
                            onRows(rows)
                        }
                    }
                } catch { /* The next LIST rechecks access and retrieves a fresh snapshot. */ }
                guard !Task.isCancelled else { return }
                // The API server normally ends healthy watches periodically. Reconnect
                // immediately after a long-lived stream, back off after short failures.
                if started.duration(to: .now) >= .seconds(30) { continue }
                onPolling(true)
            }
            // Keep the table current while watch access is unavailable. Periodically
            // establish a new list/watch so disconnects and expired cursors recover.
            for _ in 0..<(target == nil ? 1 : 6) {
                guard !Task.isCancelled else { return }
                do {
                    let snapshot: [ResourceRow]
                    switch section {
                    case .customResources(let type):
                        snapshot = try await client.customResources(type, in: id.file, context: id.name, namespace: scope)
                    case .helmReleases:
                        snapshot = try await client.helmReleases(in: id.file, context: id.name, namespace: scope)
                    default:
                        guard let kind = section.listKind else { return }
                        snapshot = try await client.resources(kind, in: id.file, context: id.name, namespace: scope)
                    }
                    guard !Task.isCancelled else { return }
                    onRows(snapshot)
                } catch {
                    guard !Task.isCancelled else { return }
                    onError(error)
                }
                do { try await Task.sleep(for: .seconds(target == nil ? 15 : 5)) }
                catch { return }
            }
        }
    }

    private func updateNamespaces(_ result: [ResourceRow]) {
        let names = result.map(\.name).sorted()
        if names != namespaceNames { namespaceNames = names }
        if namespaceError != nil { namespaceError = nil }
    }

    private func applyRows(_ result: [ResourceRow], section: ClusterSection, context: ContextID, namespace: String?) {
        let restore = resourceLoading || resourceError != nil || linkedResource != nil
        if rows != result { rows = result }
        if resourceError != nil { resourceError = nil }
        if resourceLoading { resourceLoading = false }
        if restore {
            finishResourceSelection()
        } else if case .resource(let selected) = selection, !result.contains(where: { $0.id == selected }) {
            select(nil)
        }
        if section == .resources(.namespaces) { updateNamespaces(result) }
        guard section == .resources(.pods) else { return }
        for terminal in podTerminals where namespace == nil || terminal.namespace == namespace {
            let pod = result.first { $0.id == terminal.podID }
            terminal.updateContainers(pod?.runningContainerNames ?? [])
        }
        if let target = podLogTarget {
            if let pod = result.first(where: { $0.id == target.podID }), let containers = pod.pod?.containers {
                if containers.map(\.name) != target.containers.map(\.name) {
                    podLogTarget?.containers = containers
                }
            } else {
                closePodLogs()
            }
        }
        if !result.isEmpty && metricsTask == nil { startPodMetrics(in: context, namespace: namespace) }
    }

    private func startPodMetrics(in id: ContextID, namespace: String?) {
        metricsTask = Task {
            while !Task.isCancelled {
                if !rows.isEmpty {
                    if podMetrics.isEmpty && podMetricsError == nil { podMetricsLoading = true }
                    do {
                        let usage = try await client.podMetrics(in: id.file, context: id.name, namespace: namespace)
                        guard !Task.isCancelled else { return }
                        if podMetrics != usage { podMetrics = usage }
                        if podMetricsError != nil { podMetricsError = nil }
                    } catch {
                        guard !Task.isCancelled else { return }
                        if !podMetrics.isEmpty { podMetrics = [:] }
                        if podMetricsError != error.localizedDescription { podMetricsError = error.localizedDescription }
                    }
                    if podMetricsLoading { podMetricsLoading = false }
                }
                try? await Task.sleep(for: .seconds(podMetricsError == nil ? 15 : 60))
            }
        }
    }

    private func isVisiblePod(_ row: ResourceRow) -> Bool {
        page == .cluster(.resources(.pods)) && rows.contains { $0.id == row.id }
    }

    func inspectPod(_ row: ResourceRow) {
        guard isVisiblePod(row) else { return }
        select(.resource(row.id))
    }

    func openPodLogs(_ row: ResourceRow) {
        guard isVisiblePod(row), let context = connectedContext, let namespace = row.namespace,
              let containers = row.pod?.containers, !containers.isEmpty else { return }
        showPodDrawerTab(.logs)
        if let target = podLogTarget, target.podID == row.id, target.context == context,
           target.containers.map(\.name) == containers.map(\.name) { return }
        podLogTarget = PodLogTarget(podID: row.id, context: context, namespace: namespace,
                                    name: row.name, containers: containers)
    }

    func showPodDrawerTab(_ tab: PodDrawerTab) {
        activeDrawerTab = tab
        podDrawerCollapsed = false
    }

    func togglePodDrawer() {
        if activeDrawerTab != nil { podDrawerCollapsed.toggle() }
    }

    func closePodLogs() {
        guard podLogTarget != nil else { return }
        podLogTarget = nil
        if activeDrawerTab == .logs { activeDrawerTab = podTerminals.last.map { .terminal($0.id) } }
    }

    func openPodTerminal(_ selectedRow: ResourceRow) {
        guard page == .cluster(.resources(.pods)), let context = connectedContext,
              let row = rows.first(where: { $0.id == selectedRow.id }), let namespace = row.namespace else { return }
        let containers = row.runningContainerNames
        guard !containers.isEmpty else { return }
        if let existing = podTerminals.first(where: { $0.podID == row.id && $0.context == context }) {
            existing.updateContainers(containers)
            showPodDrawerTab(.terminal(existing.id))
            return
        }
        let terminal = PodTerminalTab(client: client, context: context, podID: row.id, namespace: namespace,
                                      pod: row.name, containers: containers)
        podTerminals.append(terminal)
        showPodDrawerTab(.terminal(terminal.id))
        if containers.count == 1 { terminal.connect() }
    }

    func closePodTerminal(_ terminal: PodTerminalTab) {
        terminal.disconnect()
        podTerminals.removeAll { $0.id == terminal.id }
        if activeDrawerTab == .terminal(terminal.id) {
            activeDrawerTab = podTerminals.last.map { .terminal($0.id) } ?? (podLogTarget == nil ? nil : .logs)
        }
    }

    func closePodTerminals() {
        for terminal in podTerminals { terminal.disconnect() }
        podTerminals.removeAll()
        if case .terminal = activeDrawerTab { activeDrawerTab = podLogTarget == nil ? nil : .logs }
    }

    func loadPodLogs(for target: PodLogTarget, container: String, previous: Bool) async throws -> String {
        guard windowVisible, podLogTarget?.id == target.id, target.context == connectedContext,
              rows.contains(where: { $0.id == target.podID }),
              target.containers.contains(where: { $0.name == container }) else { throw CancellationError() }
        return try await client.podLogs(in: target.context.file, context: target.context.name,
                                        namespace: target.namespace, pod: target.name, container: container,
                                        previous: previous)
    }

    func showNamespace(of row: ResourceRow) {
        guard case .cluster(.resources) = page, rows.contains(where: { $0.id == row.id }),
              let name = row.namespace else { return }
        reveal(.namespaces, name: name)
    }

    func showPodNode(_ row: ResourceRow) {
        guard isVisiblePod(row), let name = row.pod?.node else { return }
        reveal(.nodes, name: name)
    }

    func podOwnerKind(_ row: ResourceRow) -> ResourceKind? { row.pod?.controllerResource }

    func showPodOwner(_ row: ResourceRow) {
        guard isVisiblePod(row), let kind = podOwnerKind(row), let name = row.pod?.controllerName,
              let namespace = row.namespace else { return }
        reveal(kind, name: name, namespace: kind.isNamespaced ? namespace : nil, uid: row.pod?.controllerUID)
    }

    func inspectArgoApplication(_ row: ResourceRow) {
        guard page == .cluster(.argoDashboard), rows.contains(where: { $0.id == row.id }) else { return }
        reveal(.argoApplications, name: row.name, namespace: row.namespace, uid: row.id)
    }

    func showNodeClaimReference(_ kind: ResourceKind, name: String) {
        guard page == .cluster(.resources(.nodeClaims)), kind == .nodePools || kind == .nodes, !name.isEmpty else { return }
        reveal(kind, name: name)
    }

    private func reveal(_ kind: ResourceKind, name: String, namespace: String? = nil, uid: String? = nil) {
        let destination = ClusterSection.resources(kind)
        let changingScope = namespace != nil && namespace != namespaceFilter
        if changingScope { namespaceFilter = namespace }
        if page == .cluster(destination), changingScope { loadSection(destination) }
        else { openCluster(destination) }
        linkedResource = LinkedResource(name: name, namespace: namespace, uid: uid)
        if !resourceLoading { finishResourceSelection() }
        defaults.set(true, forKey: "showInspector")
    }

    private func finishResourceSelection() {
        guard let target = linkedResource else { restoreSelection(); return }
        linkedResource = nil
        guard resourceError == nil else { select(nil); return }
        let match = rows.first { row in
            row.name == target.name && row.namespace == target.namespace && (target.uid == nil || row.id == target.uid)
        }
        select(match.map { .resource($0.id) })
        if match == nil {
            alert = WorkspaceAlert(message: "The linked resource “" + target.name + "” is no longer in this list.")
        }
    }

    private func loadWorkloadCounts(in id: ContextID, namespace: String?) async {
        let kinds = ResourceKind.workloads
        if overview.isEmpty { overview = Dictionary(uniqueKeysWithValues: kinds.map { ($0, WorkloadCount.loading) }) }
        let client = self.client
        await withTaskGroup(of: (ResourceKind, WorkloadCount).self) { group in
            // Bound concurrent API reads even when listing every workload kind.
            for (index, kind) in kinds.enumerated() {
                if index >= 3, let (completed, result) = await group.next(), !Task.isCancelled {
                    if overview[completed] != result { overview[completed] = result }
                }
                guard !Task.isCancelled else { group.cancelAll(); return }
                group.addTask {
                    do {
                        let count = try await client.resourceCount(kind, in: id.file, context: id.name, namespace: namespace)
                        return (kind, .count(count))
                    } catch {
                        return (kind, .failed(error.localizedDescription))
                    }
                }
            }
            for await (kind, result) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if overview[kind] != result { overview[kind] = result }
            }
        }
        if !Task.isCancelled && resourceLoading { resourceLoading = false }
    }
}
