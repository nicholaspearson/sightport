import SightportCore
import SwiftUI

struct ArgoDashboardView: View {
    let rows: [ResourceRow]
    let query: String
    let openApplications: () -> Void
    let inspect: (ResourceRow) -> Void

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let applications = rows.map(Application.init)
        let attention = applications.filter { $0.status.needsAttention }
        let visible = (term.isEmpty ? attention : applications).sorted {
            ($0.row.namespace ?? "", $0.row.name) < ($1.row.namespace ?? "", $1.row.name)
        }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Application health").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("View applications", action: openApplications).controlSize(.small)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    metric("Applications", applications.count, color: Palette.ink)
                    metric("Synced", applications.filter { $0.status.sync == "Synced" }.count, color: Palette.forest)
                    metric("Healthy", applications.filter { $0.status.health == "Healthy" }.count, color: Palette.forest)
                    metric("Need attention", attention.count, color: attention.isEmpty ? Palette.muted : .orange)
                }
                Text(term.isEmpty ? "Needs attention" : "Matching applications").font(.system(size: 13, weight: .semibold))
                if visible.isEmpty {
                    Label(term.isEmpty ? "No applications need attention." : "No matching applications.",
                          systemImage: term.isEmpty ? "checkmark.circle" : "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { item in
                            Button { inspect(item.row) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: item.row.name).lineLimit(1).truncationMode(.middle)
                                        if let namespace = item.row.namespace {
                                            Text(verbatim: namespace).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(verbatim: item.status.sync).foregroundStyle(statusColor(item.status.sync))
                                    Text(verbatim: item.status.health).foregroundStyle(statusColor(item.status.health))
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.muted)
                                }
                                .font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Inspect " + (item.row.namespace.map { $0 + "/" } ?? "") + item.row.name)
                            .accessibilityValue(item.status.sync + ", " + item.status.health)
                            Divider()
                        }
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct Application: Identifiable {
        let row: ResourceRow
        let status: ArgoApplicationStatus
        var id: String { row.id }

        init(_ row: ResourceRow) {
            self.row = row
            status = ArgoApplicationStatus(row: row)
        }
    }

    private func metric(_ title: String, _ value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(String(value)).font(.system(size: 20, weight: .semibold)).foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line))
        .accessibilityElement(children: .combine)
    }

    private func statusColor(_ state: String) -> Color {
        switch state {
        case "Healthy", "Synced": return Palette.forest
        case "Degraded", "OutOfSync", "Missing": return .orange
        default: return Palette.muted
        }
    }
}
