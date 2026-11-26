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
    enum Action {
        case workload(WorkloadRequest)
        case terminatePod(PodTerminationRequest)
        case removeContext(ContextID)
    }

    let id = UUID()
    let message: String
    var action: Action?
}

struct WorkloadNotice {
    let message: String
    let failed: Bool
}

struct WorkloadRequest {
    struct Target: Hashable {
        let context: ContextID
        let kind: ResourceKind
        let uid: String
    }

    let target: Target
    let row: ResourceRow
    let action: WorkloadAction
}

struct PodTerminationRequest: Identifiable {
    let id = UUID()
    let context: ContextID
    let row: ResourceRow
    let namespace: String

    var confirmation: String {
        var text = "Kubernetes will terminate \(namespace)/\(row.name) in context \(context.name) using the pod’s configured grace period."
        if let kind = row.pod?.controllerKind, let owner = row.pod?.controllerName {
            text += "\n\nIts controller (\(kind)/\(owner)) may create a replacement."
        }
        return text
    }
}

struct PodLogTarget: Identifiable {
    let id = UUID()
    let context: ContextID
    let namespace: String
    let kind: ResourceKind
    var row: ResourceRow

    var name: String { row.name }
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

private struct WorkspaceResourceRows: Sendable {
    var rows: [ResourceRow] = []
    var positions: [String: Int] = [:]

    // Snapshot comparison can traverse the labels and containers of every pod.
    // Compare and build the lookup index on the cooperative executor before publishing.
    static func replacement(for rows: [ResourceRow], previous: [ResourceRow]) async -> Self? {
        guard rows != previous, !Task.isCancelled else { return nil }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() { positions[row.id] = index }
        return Self(rows: rows, positions: positions)
    }
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
    @Published private(set) var previewTab: WorkbenchPage?
    @Published private(set) var page = WorkbenchPage.contexts
    @Published private(set) var selection: WorkbenchItem?
    @Published private(set) var favorites: Set<ContextID> = []
    @Published private(set) var activeContext: ContextID?
    @Published private(set) var sources: [SourceFile] = []
    @Published private(set) var loading = false
    @Published private(set) var checks: [ContextID: Reachability] = [:]
    @Published var alert: WorkspaceAlert?

    @Published private(set) var connectedContext: ContextID?
    @Published private var resourceRows = WorkspaceResourceRows() {
        didSet { rowsRevision &+= 1 }
    }
    private(set) var rowsRevision: UInt64 = 0
    var rows: [ResourceRow] { resourceRows.rows }
    @Published private(set) var windowVisible = true
    @Published private(set) var detailRefreshID = 0
    @Published private(set) var pollingAfterWatchFailure = false
    @Published private(set) var resourceLoading = false
    @Published private(set) var resourceError: String?
    @Published private(set) var namespaceNames: [String] = []
    @Published private(set) var namespaceError: String?
    @Published private(set) var namespaceFilter: String?
    @Published private(set) var customResourceGroups: [CustomResourceGroup] = []
    @Published private(set) var customResourceCatalogError: String?
    @Published private(set) var customResourceCatalogLoading = false
    @Published private(set) var overview: [ResourceKind: WorkloadCount] = [:]
    @Published private(set) var podMetrics: [PodKey: PodUsage] = [:] {
        didSet { podMetricsRevision &+= 1 }
    }
    private(set) var podMetricsRevision: UInt64 = 0
    @Published private(set) var podMetricsLoading = false
    @Published private(set) var podMetricsError: String?
    @Published private(set) var podLogTarget: PodLogTarget?
    @Published private(set) var podTerminals: [PodTerminalTab] = []
    @Published private(set) var activeDrawerTab: PodDrawerTab?
    @Published private(set) var podDrawerCollapsed = false
    @Published var workloadNotice: WorkloadNotice?
    @Published private var activeWorkloadRequests: Set<WorkloadRequest.Target> = []
    @Published private var terminatingPods: [String: PodTerminationRequest] = [:]

    func selectedResource(in kind: ResourceKind) -> ResourceRow? {
        guard page == .cluster(.resources(kind)), case .resource(let id) = selection else { return nil }
        return resourceRow(id: id)
    }

    func resourceRow(id: String) -> ResourceRow? {
        guard let index = resourceRows.positions[id] else { return nil }
        return resourceRows.rows[index]
    }

    private var resourceTask: Task<Void, Never>?
    private var resourceGeneration = UUID()
    private var metricsTask: Task<Void, Never>?
    private var linkedResource: LinkedResource?
    private var namespaceTask: Task<Void, Never>?
    private var customResourceCatalogVisible = false
    private var customResourceCatalogTask: Task<Void, Never>?

    private let repository = ContextPreferencesRepository()
    private let client = KubernetesClient()
    private let defaults = UserDefaults.standard
    private var savedTableSettings: [ClusterSection: ResourceTableSettings] = [:]
    private var tabSelections: [WorkbenchPage: WorkbenchItem] = [:]
    private var rememberedContext: ContextID?
    private var removedContexts: Set<ContextID> = []
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
            removedContexts = preferences.removedContexts
        } catch {
            alert = WorkspaceAlert(message: "Could not load context preferences. " + error.localizedDescription)
        }
        refresh()
    }

    func context(for id: ContextID) -> KubeContext? {
        sources.first { $0.url == id.file }?.contexts.first { $0.name == id.name }
    }

    func tableSettings(for section: ClusterSection) -> ResourceTableSettings {
        if let existing = savedTableSettings[section] { return existing }
        let settings = ResourceTableSettings(section: section)
        savedTableSettings[section] = settings
        return settings
    }

    private func forgetTabState(_ tab: WorkbenchPage) {
        tabSelections.removeValue(forKey: tab)
        if case .cluster(let section) = tab { savedTableSettings.removeValue(forKey: section) }
    }

    func open(_ destination: WorkbenchPage) {
        if case .file(let file) = destination, !sources.contains(where: { $0.url == file }) { return }
        if case .cluster = destination, connectedContext == nil { return }
        guard page != destination else { return }
        if case .workload = alert?.action { alert = nil }
        let isNew = !tabs.contains(destination)
        if let preview = previewTab, let index = tabs.firstIndex(of: preview) {
            forgetTabState(preview)
            if isNew { tabs[index] = destination } else { tabs.remove(at: index) }
            previewTab = nil
        } else if isNew {
            tabs.append(destination)
        }
        if isNew, case .cluster = destination { previewTab = destination }
        if page == .cluster(.resources(.pods)) {
            dismissPodTerminationPrompt()
        }
        if let target = podLogTarget, page == .cluster(.resources(target.kind)) { closePodLogs() }
        if page.configDataKind != nil { select(nil) }
        page = destination
        if case .cluster(let section) = destination {
            loadSection(section)
        } else {
            clearResourceTable()
            restoreSelection()
        }
        updateCustomResourceObservation()
    }

    func keepTabOpen(_ tab: WorkbenchPage? = nil) {
        if previewTab == (tab ?? page) { previewTab = nil }
    }

    func close(_ tab: WorkbenchPage) {
        guard tabs.count > 1, let index = tabs.firstIndex(of: tab) else { return }
        if previewTab == tab { previewTab = nil }
        tabs.remove(at: index)
        if tab == .cluster(.resources(.pods)) { closePodTerminals() }
        forgetTabState(tab)
        if page == tab { open(tabs[min(index, tabs.count - 1)]) }
    }

    func select(_ item: WorkbenchItem?) {
        if case .workload(let request) = alert?.action, item != .resource(request.target.uid) {
            alert = nil
            workloadNotice = WorkloadNotice(message: "The selected workload changed. Select it again to continue.", failed: true)
        }
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

    func disconnect(_ id: ContextID) {
        if pendingConnection == id { cancelConnectionAttempt() }
        guard connectedContext == id else { return }
        checks.removeValue(forKey: id)
        endCluster()
    }

    func requestContextRemoval(_ id: ContextID) {
        guard context(for: id) != nil || favorites.contains(id) || connectedContext == id else { return }
        var message = "Remove “\(id.name)” from this workspace?"
        if connectedContext == id {
            message += " Its cluster tabs, terminals, and port forwards will close."
        }
        message += "\n\nTo add it again, reopen its kubeconfig with Open Kubeconfig…\n\(displayPath(id.file))"
        alert = WorkspaceAlert(message: message, action: .removeContext(id))
    }

    func confirmContextRemoval(_ id: ContextID) {
        guard updatePreferences({ $0.removeContext(id) }) else { return }
        if pendingConnection == id { cancelConnectionAttempt() }
        if rememberedContext == id { rememberedContext = nil }
        if activeContext == id { activeContext = nil }
        checks.removeValue(forKey: id)
        if let index = sources.firstIndex(where: { $0.url == id.file }) {
            sources[index].contexts.removeAll { $0.name == id.name }
        }
        tabSelections = tabSelections.filter { $0.value != .context(id.file, id.name) }
        if connectedContext == id { endCluster() }
        if selection == .context(id.file, id.name) { restoreSelection() }
    }

    // Re-read before writing so a failed or unreadable migration can be retried
    // without replacing the user's existing preferences with empty defaults.
    @discardableResult
    private func updatePreferences(_ change: (inout ContextPreferences) -> Void) -> Bool {
        do {
            var next = try loadPreferences()
            change(&next)
            try repository.save(next)
            favorites = next.favorites
            removedContexts = next.removedContexts
            return true
        } catch {
            alert = WorkspaceAlert(message: "Could not save context preferences. " + error.localizedDescription)
            return false
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
            if case .resource(let id) = previous, resourceRow(id: id) != nil {
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
                do {
                    let contexts = try await client.contexts(in: file)
                    source.contexts = contexts.filter { !removedContexts.contains(ContextID(file: file, name: $0.name)) }
                }
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openKubeconfig(url)
    }

    func openKubeconfig(_ file: URL) {
        let url = file.standardizedFileURL
        if removedContexts.contains(where: { $0.file == url }),
           !updatePreferences({ $0.restoreContexts(in: url) }) { return }
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
        stopCustomResourceObservation()
        applyCustomResourceCatalog([])
        dismissPodTerminationPrompt()
        terminatingPods.removeAll()
        portForwards.stopAll()
        closePodLogs()
        closePodTerminals()
        namespaceNames = []
        namespaceError = nil
        namespaceFilter = nil
        connectedContext = nil
        clearResourceTable()
        previewTab = nil
        savedTableSettings.removeAll()
        workloadNotice = nil
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
        keepTabOpen()
        dismissPodTerminationPrompt()
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
        if section == .resources(.customResourceDefinitions) { updateCustomResourceObservation() }
    }

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        if visible, case .cluster(let section) = page {
            loadSection(section, refresh: true)
        } else if !visible {
            stopResourceReads()
        }
        updateCustomResourceObservation()
    }

    func setCustomResourceCatalogVisible(_ visible: Bool) {
        guard customResourceCatalogVisible != visible else { return }
        customResourceCatalogVisible = visible
        updateCustomResourceObservation()
    }

    func refreshCustomResourceCatalog() {
        if page == .cluster(.resources(.customResourceDefinitions)) {
            reloadResources()
        } else {
            stopCustomResourceObservation()
            updateCustomResourceObservation()
        }
    }

    private func stopCustomResourceObservation() {
        customResourceCatalogTask?.cancel()
        customResourceCatalogTask = nil
    }

    private func updateCustomResourceObservation() {
        guard customResourceCatalogVisible, windowVisible, let context = connectedContext else {
            stopCustomResourceObservation()
            return
        }
        let definitions = ClusterSection.resources(.customResourceDefinitions)
        if page == .cluster(definitions) {
            // The Definitions table already follows this collection.
            stopCustomResourceObservation()
            if resourceLoading {
                customResourceCatalogLoading = true
                customResourceCatalogError = nil
            } else {
                applyCustomResourceCatalog(rows, error: resourceError)
            }
            return
        }
        guard customResourceCatalogTask == nil else { return }
        customResourceCatalogLoading = customResourceGroups.isEmpty
        customResourceCatalogError = nil
        customResourceCatalogTask = Task {
            await observeRows(definitions, in: context, scope: nil, followsTable: false, onRows: {
                self.applyCustomResourceCatalog($0)
            }, onError: {
                self.applyCustomResourceCatalog([], error: $0.localizedDescription)
            })
        }
    }

    private func applyCustomResourceCatalog(_ definitions: [ResourceRow], error: String? = nil) {
        let groups = CustomResourceGroup.catalog(from: definitions)
        if groups != customResourceGroups { customResourceGroups = groups }
        if customResourceCatalogError != error { customResourceCatalogError = error }
        if customResourceCatalogLoading { customResourceCatalogLoading = false }
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
        if !rows.isEmpty { resourceRows = WorkspaceResourceRows() }
        if !podMetrics.isEmpty { podMetrics = [:] }
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
                    await self.applyRows(result, section: section, context: id, namespace: scope)
                }, onError: { error in
                    if !self.rows.isEmpty { self.resourceRows = WorkspaceResourceRows() }
                    self.select(nil)
                    self.resourceError = error.localizedDescription
                    self.resourceLoading = false
                    if section == .resources(.pods) {
                        self.dismissPodTerminationPrompt()
                    }
                    if let target = self.podLogTarget, section == .resources(target.kind) { self.closePodLogs() }
                    if section == .resources(.namespaces) {
                        self.namespaceError = error.localizedDescription
                        self.namespaceNames = []
                    }
                    if section == .resources(.customResourceDefinitions) {
                        self.applyCustomResourceCatalog([], error: error.localizedDescription)
                    }
                }, onPolling: { polling in
                    if self.pollingAfterWatchFailure != polling { self.pollingAfterWatchFailure = polling }
                })
            }
        }
    }

    private func observeRows(_ section: ClusterSection, in id: ContextID, scope: String?, followsTable: Bool = true,
                             onRows: @escaping @MainActor ([ResourceRow]) async -> Void,
                             onError: @escaping @MainActor (Error) -> Void,
                             onPolling: @escaping @MainActor (Bool) -> Void = { _ in }) async {
        let generation = resourceGeneration
        let target: ResourceWatchTarget?
        if case .customResources(let type) = section {
            target = .custom(type)
        } else {
            target = section.listKind.map(ResourceWatchTarget.resource)
        }
        @MainActor @Sendable func receive(_ rows: [ResourceRow]) async {
            guard !Task.isCancelled, connectedContext == id,
                  !followsTable || resourceGeneration == generation else { return }
            onPolling(false)
            await onRows(rows)
        }
        while !Task.isCancelled {
            if let target {
                let started = ContinuousClock.now
                do {
                    try await client.watchResources(target, in: id.file, context: id.name, namespace: scope) { rows in
                        await receive(rows)
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
                    await onRows(snapshot)
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

    private func applyRows(_ result: [ResourceRow], section: ClusterSection, context: ContextID, namespace: String?) async {
        let generation = resourceGeneration
        let replacement = await WorkspaceResourceRows.replacement(for: result, previous: rows)
        guard !Task.isCancelled, resourceGeneration == generation, connectedContext == context else { return }
        let restore = resourceLoading || resourceError != nil || linkedResource != nil
        if let replacement { resourceRows = replacement }
        if resourceError != nil { resourceError = nil }
        if resourceLoading { resourceLoading = false }
        if restore {
            finishResourceSelection()
        } else if case .resource(let selected) = selection, resourceRow(id: selected) == nil {
            select(nil)
        }
        if section == .resources(.namespaces) { updateNamespaces(result) }
        if section == .resources(.customResourceDefinitions) { applyCustomResourceCatalog(result) }
        if let target = podLogTarget, section == .resources(target.kind) {
            if let row = resourceRow(id: target.row.id) {
                if row.pod?.containers != target.row.pod?.containers { podLogTarget?.row = row }
            } else {
                closePodLogs()
            }
        }
        guard section == .resources(.pods) else { return }
        if case .terminatePod(let request) = alert?.action,
           resourceRow(id: request.row.id)?.pod?.isTerminating != false {
            dismissPodTerminationPrompt()
        }
        if !terminatingPods.isEmpty {
            let finished = terminatingPods.filter { id, request in
                (namespace == nil || namespace == request.namespace) && resourceRow(id: id)?.pod?.isTerminating != false
            }
            for id in finished.keys { terminatingPods.removeValue(forKey: id) }
        }
        for terminal in podTerminals where namespace == nil || terminal.namespace == namespace {
            let pod = resourceRow(id: terminal.podID)
            terminal.updateContainers(pod?.runningContainerNames ?? [])
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
        page == .cluster(.resources(.pods)) && resourceRow(id: row.id) != nil
    }

    func inspectPod(_ row: ResourceRow) {
        guard isVisiblePod(row) else { return }
        keepTabOpen()
        select(.resource(row.id))
    }

    func isChangingWorkload(_ row: ResourceRow, kind: ResourceKind) -> Bool {
        guard let context = connectedContext else { return false }
        return activeWorkloadRequests.contains(.init(context: context, kind: kind, uid: row.id))
    }

    func requestWorkloadAction(_ kind: ResourceKind, row: ResourceRow) {
        guard let context = connectedContext, page == .cluster(.resources(kind)),
              let current = resourceRow(id: row.id), current.name == row.name, current.namespace == row.namespace,
              let action = WorkloadAction(kind: kind, row: current), !isChangingWorkload(row, kind: kind) else { return }
        keepTabOpen()
        select(.resource(row.id))
        let target = WorkloadRequest.Target(context: context, kind: kind, uid: row.id)
        let request = WorkloadRequest(target: target, row: current, action: action)
        alert = WorkspaceAlert(message: action.confirmation(for: current, context: context.name), action: .workload(request))
    }

    func confirmWorkloadAction(_ request: WorkloadRequest) {
        let target = request.target
        guard connectedContext == target.context else { return }
        guard let row = selectedResource(in: target.kind), row.id == target.uid,
              row.name == request.row.name, row.namespace == request.row.namespace,
              WorkloadAction(kind: target.kind, row: row) == request.action else {
            workloadNotice = WorkloadNotice(message: "The workload changed. Review its current state before trying again.", failed: true)
            return
        }
        guard activeWorkloadRequests.insert(target).inserted else { return }
        Task {
            defer { activeWorkloadRequests.remove(target) }
            let notice: WorkloadNotice
            do {
                let message = try await client.performWorkloadAction(request.action, kind: target.kind, row: row,
                                                                     in: target.context.file, context: target.context.name)
                notice = WorkloadNotice(message: message, failed: false)
            } catch {
                let message = (row.namespace ?? "") + "/" + row.name + " · " + error.localizedDescription
                notice = WorkloadNotice(message: message, failed: true)
            }
            if connectedContext == target.context { workloadNotice = notice }
        }
    }

    func isTerminatingPod(_ row: ResourceRow) -> Bool {
        row.pod?.isTerminating == true || terminatingPods[row.id] != nil
    }

    func canTerminatePod(_ row: ResourceRow) -> Bool {
        row.pod != nil && row.namespace?.isEmpty == false && !row.id.isEmpty
            && !row.id.contains("/") && !isTerminatingPod(row)
    }

    func requestPodTermination(_ row: ResourceRow) {
        guard let context = connectedContext, isVisiblePod(row), canTerminatePod(row),
              let namespace = row.namespace else { return }
        keepTabOpen()
        let request = PodTerminationRequest(context: context, row: row, namespace: namespace)
        alert = WorkspaceAlert(message: request.confirmation, action: .terminatePod(request))
    }

    private func dismissPodTerminationPrompt() {
        if case .terminatePod = alert?.action { alert = nil }
    }

    func confirmPodTermination(_ request: PodTerminationRequest) {
        guard connectedContext == request.context, page == .cluster(.resources(.pods)) else { return }
        let row = request.row
        guard let current = resourceRow(id: row.id), current.name == row.name, current.namespace == request.namespace,
              canTerminatePod(current) else { return }
        terminatingPods[row.id] = request
        Task {
            do {
                try await client.terminatePod(row, in: request.context.file, context: request.context.name)
            } catch {
                guard connectedContext == request.context else { return }
                if terminatingPods[row.id]?.id == request.id { terminatingPods.removeValue(forKey: row.id) }
                alert = WorkspaceAlert(message: "\(request.namespace)/\(row.name) · \(request.context.name)\n\n\(error.localizedDescription)")
            }
        }
    }

    func openPodLogs(_ row: ResourceRow) {
        guard row.pod?.containers.isEmpty == false else { return }
        openLogs(for: row, kind: .pods)
    }

    func openDeploymentLogs(_ row: ResourceRow) {
        openLogs(for: row, kind: .deployments)
    }

    private func openLogs(for selected: ResourceRow, kind: ResourceKind) {
        guard page == .cluster(.resources(kind)), let context = connectedContext,
              let row = resourceRow(id: selected.id), let namespace = row.namespace else { return }
        keepTabOpen()
        showPodDrawerTab(.logs)
        if let target = podLogTarget, target.row.id == row.id, target.kind == kind, target.context == context { return }
        podLogTarget = PodLogTarget(context: context, namespace: namespace, kind: kind, row: row)
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
              let row = resourceRow(id: selectedRow.id), let namespace = row.namespace else { return }
        let containers = row.runningContainerNames
        guard !containers.isEmpty else { return }
        keepTabOpen()
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

    func loadDeploymentLogPods(for target: PodLogTarget) async throws -> [LogPod] {
        guard windowVisible, target.kind == .deployments, target.context == connectedContext,
              podLogTarget?.id == target.id else { throw CancellationError() }
        return try await client.deploymentLogPods(in: target.context.file, context: target.context.name,
                                                  deployment: target.row)
    }

    func loadPodLogs(for target: PodLogTarget, pod: LogPod, container: String, previous: Bool) async throws -> String {
        guard windowVisible, podLogTarget?.id == target.id, target.context == connectedContext,
              pod.containers.contains(where: { $0.name == container }) else { throw CancellationError() }
        return try await client.podLogs(in: target.context.file, context: target.context.name,
                                        namespace: target.namespace, pod: pod.name, container: container,
                                        previous: previous)
    }

    func showNamespace(of row: ResourceRow) {
        guard case .cluster(.resources) = page, resourceRow(id: row.id) != nil,
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
        guard page == .cluster(.argoDashboard), resourceRow(id: row.id) != nil else { return }
        reveal(.argoApplications, name: row.name, namespace: row.namespace, uid: row.id)
    }

    func showNodeClaimReference(_ kind: ResourceKind, name: String) {
        guard page == .cluster(.resources(.nodeClaims)), kind == .nodePools || kind == .nodes, !name.isEmpty else { return }
        reveal(kind, name: name)
    }

    private func reveal(_ kind: ResourceKind, name: String, namespace: String? = nil, uid: String? = nil) {
        keepTabOpen()
        let destination = ClusterSection.resources(kind)
        let changingScope = namespace != nil && namespace != namespaceFilter
        if changingScope { namespaceFilter = namespace }
        if page == .cluster(destination), changingScope { loadSection(destination) }
        else { openCluster(destination) }
        keepTabOpen()
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
