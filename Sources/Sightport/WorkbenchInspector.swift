import SightportCore
import SwiftUI

struct WorkbenchInspector: View {
    @EnvironmentObject private var workspace: Workspace
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onCollapse) {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(Palette.forest)
                    Text("Inspector").fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundStyle(Palette.muted)
                        .frame(width: 26, height: 25)
                }
                .font(.system(size: 12))
                .padding(.leading, 14).padding(.trailing, 7)
                .frame(height: 31)
                .modifier(DisclosureHeaderFeedback())
            }
            .buttonStyle(.plain)
            .help("Collapse inspector")
            .accessibilityLabel("Collapse inspector")
            .accessibilityValue("Expanded")
            .background(Palette.surface)

            Rectangle().fill(Palette.line).frame(height: 1)
            Group {
                if case .cluster = workspace.page {
                    ClusterResourceInspector(workspace: workspace)
                } else {
                    selectionDetails
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
    }

    @ViewBuilder private var selectionDetails: some View {
        switch workspace.selection {
        case .context(let file, let name):
            let id = ContextID(file: file, name: name)
            if let context = workspace.context(for: id) {
                contextDetails(context, file: file)
            } else if workspace.favorites.contains(id) {
                detailPanel(title: name, symbol: "helm") {
                    FavoriteContextButton(workspace: workspace, id: id)
                } fields: {
                    field("Status", value: "Context unavailable", monospaced: false, isError: true)
                    field("Kubeconfig", value: displayPath(file))
                }
            } else { noSelection }
        case .file(let file):
            if let configuration = source(file) {
                detailPanel(title: file.lastPathComponent, symbol: "doc.text") {
                    Button("View contexts") { workspace.open(.file(file)) }
                } fields: {
                    field("Path", value: displayPath(file))
                    if let error = configuration.error {
                        field("Read error", value: error, monospaced: false, isError: true)
                    } else {
                        field("Contexts", value: String(configuration.contexts.count))
                        if let current = configuration.contexts.first(where: \.isCurrent) {
                            field("Current context", value: current.name)
                        }
                    }
                }
            } else { noSelection }
        case .resource, nil:
            noSelection
        }
    }

    private func contextDetails(_ context: KubeContext, file: URL) -> some View {
        let id = ContextID(file: file, name: context.name)
        return detailPanel(title: context.name, symbol: "helm") {
            FavoriteContextButton(workspace: workspace, id: id)
            ConnectContextButton(workspace: workspace, id: id)
        } fields: {
            switch workspace.checks[id] {
            case .checking: field("Connection", value: "Connecting…", monospaced: false)
            case .reachable: field("Last connection", value: "API reachable", monospaced: false)
            case .failed(let error): field("Connection failed", value: error, monospaced: false, isError: true)
            case nil: field("Connection", value: "Not checked this session", monospaced: false)
            }
            field("Cluster", value: context.cluster.isEmpty ? "Unspecified" : context.cluster)
            field("Namespace", value: context.namespace.flatMap { $0.isEmpty ? nil : $0 } ?? "default")
            field("Kubeconfig", value: displayPath(file))
            if context.isCurrent { field("Kubeconfig default", value: "Yes", monospaced: false) }
        }
    }

    private func source(_ file: URL) -> SourceFile? {
        workspace.sources.first { $0.url == file.standardizedFileURL }
    }

    private var noSelection: some View {
        HStack(spacing: 9) {
            Image(systemName: "cursorarrow").accessibilityHidden(true)
            Text("Select a row to inspect its details.")
        }
        .font(.system(size: 12)).foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailPanel<Actions: View, Fields: View>(
        title: String, symbol: String, @ViewBuilder actions: () -> Actions, @ViewBuilder fields: () -> Fields
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 14))
                        .foregroundStyle(Palette.forest).accessibilityHidden(true)
                    Text(verbatim: title).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).help(title)
                    Spacer(minLength: 6)
                    HStack(spacing: 6) { actions() }
                        .buttonStyle(.bordered).controlSize(.small).fixedSize()
                }
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) { fields() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func field(_ label: String, value: String, monospaced: Bool = true, isError: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize()
            Text(verbatim: value)
                .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(isError ? Color.orange : Palette.ink)
                .lineLimit(isError ? nil : 1)
                .truncationMode(.middle).help(value).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
