import AppKit
import SightportCore
import SwiftUI

struct SecretInspector: View {
    let context: ContextID
    let row: ResourceRow
    let onShowNamespace: () -> Void
    let onClose: () -> Void

    var body: some View {
        ConfigInspectorPanel(title: "Secret", context: context, row: row, onClose: onClose) {
            ConfigInspectorSection("Properties") {
                ConfigPropertiesGrid(row: row, onShowNamespace: onShowNamespace) {
                    GridRow {
                        Text("Type").foregroundStyle(Palette.muted)
                        Text(verbatim: row.values.first ?? "—").textSelection(.enabled)
                    }
                }
            }
            Divider()
            ConfigInspectorSection("Events") {
                SecretReadSection(retryLabel: "Retry secret events") {
                    try await KubernetesClient().secretEvents(for: row, in: context.file, context: context.name)
                } content: { events, _ in
                    if events.isEmpty {
                        Text("No events found").foregroundStyle(Palette.muted)
                    } else {
                        ForEach(events) { event in eventSummary(event) }
                    }
                }
            }
            Divider()
            ConfigInspectorSection("Data") {
                SecretReadSection(version: row.resourceVersion, retryLabel: "Retry secret data") {
                    try await KubernetesClient().secretDetails(for: row, in: context.file, context: context.name)
                } content: { details, current in
                    if details.entries.isEmpty {
                        Text("No data keys").foregroundStyle(Palette.muted)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(details.entries) { SecretEntryView(entry: $0, current: current) }
                        }
                    }
                }
            }
        }
    }

    private func eventSummary(_ event: ResourceRow) -> some View {
        let fields = Dictionary(uniqueKeysWithValues: zip(ResourceKind.events.columns, event.values))
        let type = fields["Type"] ?? ""
        let reason = fields["Reason"] ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: reason.isEmpty ? event.name : reason).fontWeight(.medium)
                if !type.isEmpty {
                    Text(verbatim: type).foregroundStyle(type == "Warning" ? Color.orange : Palette.muted)
                }
            }
            if let message = fields["Message"], !message.isEmpty {
                Text(verbatim: message).textSelection(.enabled)
            }
            if let lastSeen = fields["Last seen"], !lastSeen.isEmpty {
                Text(verbatim: lastSeen).font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct SecretReadSection<Value, Content: View>: View {
    var version: String?
    let retryLabel: String
    let load: () async throws -> Value
    @ViewBuilder let content: (Value, Bool) -> Content
    @State private var loadedVersion: String?
    @State private var result: Result<Value, Error>?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch result {
            case .success(let value): content(value, loadedVersion == version)
            case .failure(let error):
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.localizedDescription).foregroundStyle(Palette.muted)
                    Button("Retry") { result = nil; attempt += 1 }
                        .controlSize(.small).accessibilityLabel(retryLabel)
                }
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .modifier(ConfigDetailRead(version: version, attempt: attempt, load: load, receive: {
            result = $0
            loadedVersion = version
        }))
    }
}

private struct SecretEntryView: View {
    let entry: SecretDataEntry
    let current: Bool
    @State private var revealed = false
    @State private var useBase64 = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(verbatim: entry.key).fontWeight(.medium)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 2)
                if current, revealed, entry.byteCount > 0 {
                    if entry.text != nil {
                        Picker("Format for " + entry.key, selection: $useBase64) {
                            Text("Text").tag(false)
                            Text("Base64").tag(true)
                        }.labelsHidden().fixedSize().controlSize(.small)
                        .accessibilityLabel("Format for " + entry.key)
                    } else {
                        Text("Binary · Base64").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                IconAction(symbol: revealed ? "eye.slash" : "eye", title: (revealed ? "Hide " : "Reveal ") + entry.key) {
                    revealed.toggle()
                    useBase64 = false
                }
            }
            Group {
                if !current {
                    Text("Updating…").foregroundStyle(Palette.muted)
                } else if revealed {
                    if entry.byteCount == 0 {
                        Text("Empty value").foregroundStyle(Palette.muted)
                    } else {
                        let value = useBase64 ? entry.base64 : (entry.text ?? entry.base64)
                        if value.utf8.count > 2048 || value.prefix(2048).filter({ $0 == "\n" }).count > 8 {
                            ScrollableConfigValue(value: value, key: entry.key).frame(height: 140)
                        } else {
                            Text(verbatim: value).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("••••••••").foregroundStyle(Palette.muted).accessibilityLabel("Value hidden")
                }
            }
            .padding(7).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
        }
    }
}
