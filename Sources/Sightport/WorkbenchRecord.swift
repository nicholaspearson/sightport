import SightportCore
import SwiftUI

struct WorkbenchRecord: Identifiable {
    enum Content {
        case context(ContextID, available: Bool)
        case file(SourceFile)
    }

    let content: Content
    let name: String
    let detail: String
    let namespace: String
    let file: URL

    var id: WorkbenchItem {
        switch content {
        case .context(let id, _): return .context(id.file, id.name)
        case .file(let source): return .file(source.url)
        }
    }

    init(_ id: ContextID, context: KubeContext?) {
        content = .context(id, available: context != nil)
        name = id.name
        detail = context?.cluster ?? ""
        if let context {
            namespace = context.namespace.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        } else { namespace = "" }
        file = id.file
    }

    init(_ source: SourceFile) {
        content = .file(source)
        name = source.url.lastPathComponent
        detail = displayPath(source.url.deletingLastPathComponent())
        namespace = ""
        file = source.url
    }

    var sourcePath: String { displayPath(file) }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [name, detail, namespace, sourcePath].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct RecordName: View {
    let record: WorkbenchRecord
    let connectedContext: ContextID?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.forest)
                .frame(width: 16)
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)
            Text(record.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            if case .context(let id, let available) = record.content {
                if !available {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .help("Context unavailable")
                        .accessibilityLabel("Context unavailable")
                } else if connectedContext == id {
                    Text("Connected").font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(Palette.forest)
                        .background(Palette.selection, in: RoundedRectangle(cornerRadius: 3))
                        .fixedSize().accessibilityLabel("Connected")
                }
            }
        }
        .frame(minHeight: 31, alignment: .leading)
        .help(record.name)
    }

    private var symbol: String {
        if case .context = record.content { return "helm" }
        return "doc.text"
    }
}

struct FavoriteContextButton: View {
    @ObservedObject var workspace: Workspace
    let id: ContextID

    var body: some View {
        let favorite = workspace.favorites.contains(id)
        let action = favorite ? "Remove from favorites" : "Add to favorites"
        Button { workspace.toggleFavorite(id) } label: {
            Image(systemName: favorite ? "star.fill" : "star")
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .foregroundStyle(favorite ? Palette.forest : Palette.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action)
        .accessibilityLabel(action + ", " + id.name)
    }
}

struct ConnectContextButton: View {
    @ObservedObject var workspace: Workspace
    let id: ContextID?

    var body: some View {
        let busy = id.map { workspace.checks[$0] == .checking } ?? false
        let connected = id != nil && id == workspace.connectedContext
        Button(busy ? "Connecting…" : connected ? "Reconnect" : "Connect") {
            if let id { workspace.connect(id) }
        }
        .disabled(id.flatMap { workspace.context(for: $0) } == nil || busy)
        .help(id.map { "Connect using " + $0.name } ?? "Select a context to connect")
    }
}

struct ContextConnectionMenuAction: View {
    @ObservedObject var workspace: Workspace
    let id: ContextID

    var body: some View {
        if workspace.connectedContext == id || workspace.checks[id] == .checking {
            Button("Disconnect") { workspace.disconnect(id) }
        } else {
            Button("Connect") { workspace.connect(id) }
                .disabled(workspace.context(for: id) == nil)
        }
    }
}

struct RecordActions: View {
    let workspace: Workspace
    let record: WorkbenchRecord

    var body: some View {
        HStack(spacing: 2) {
            if case .context(let id, _) = record.content {
                FavoriteContextButton(workspace: workspace, id: id)
            }
            Menu {
                RecordMenu(workspace: workspace, record: record)
            } label: {
                Image(systemName: "ellipsis").frame(width: 21, height: 21)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize().foregroundStyle(Palette.muted)
            .accessibilityLabel("Actions for " + record.name)
            .help("Actions for " + record.name)
        }
    }
}

struct RecordMenu: View {
    @ObservedObject var workspace: Workspace
    let record: WorkbenchRecord

    var body: some View {
        switch record.content {
        case .context(let id, let available):
            ContextConnectionMenuAction(workspace: workspace, id: id)
            Button(workspace.favorites.contains(id) ? "Remove from favorites" : "Add to favorites") {
                workspace.toggleFavorite(id)
            }
            Divider()
            Button("Show kubeconfig contexts") {
                workspace.open(.file(id.file))
                if available { workspace.select(record.id) }
            }.disabled(!workspace.sources.contains { $0.url == id.file })
            Divider()
            Button("Remove from Sightport…", role: .destructive) { workspace.requestContextRemoval(id) }
        case .file(let source):
            Button("Browse contexts") { workspace.open(.file(source.url)) }
            if source.canForget {
                Button("Remove file from list") { workspace.forget(source.url) }
            }
        }
    }
}
