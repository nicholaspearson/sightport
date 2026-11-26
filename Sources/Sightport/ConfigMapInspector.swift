import AppKit
import SightportCore
import SwiftUI

struct ConfigMapInspector: View {
    let context: ContextID
    let row: ResourceRow
    let onShowNamespace: () -> Void
    let onClose: () -> Void

    var body: some View {
        ConfigInspectorPanel(title: "Config Map", context: context, row: row, onClose: onClose) {
            ConfigMapContent(context: context, row: row, onShowNamespace: onShowNamespace)
        }
    }
}

struct ConfigInspectorPanel<Content: View>: View {
    let title: String
    let context: ContextID
    let row: ResourceRow
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    private struct Target: Hashable {
        let context: ContextID
        let namespace: String?
        let name: String
        let uid: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(Palette.muted)
                Text(verbatim: row.name).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.middle).help(row.name)
                Spacer(minLength: 4)
                IconAction(symbol: "xmark", title: "Close " + title.lowercased() + " details", action: onClose)
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 43)
            .background(Palette.surface)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
            }
            .id(Target(context: context, namespace: row.namespace, name: row.name, uid: row.id))
        }
        .font(.system(size: 12)).foregroundStyle(Palette.ink).background(Palette.canvas)
    }
}

struct ConfigInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigPropertiesGrid<Content: View>: View {
    let row: ResourceRow
    let onShowNamespace: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
            if let date = row.createdAt {
                GridRow {
                    Text("Created").foregroundStyle(Palette.muted)
                    ResourceAgeText(createdAt: date, includeDate: true)
                }
            }
            GridRow {
                Text("Name").foregroundStyle(Palette.muted)
                Text(verbatim: row.name).textSelection(.enabled)
            }
            if let namespace = row.namespace {
                GridRow {
                    Text("Namespace").foregroundStyle(Palette.muted)
                    Button(action: onShowNamespace) { Text(verbatim: namespace).underline() }
                        .buttonStyle(.plain).foregroundStyle(Palette.forest)
                        .accessibilityLabel("Show namespace " + namespace)
                }
            }
            content()
        }
    }
}

struct ResourceDetailRead<Value>: ViewModifier {
    @EnvironmentObject private var workspace: Workspace
    let version: String?
    let attempt: Int
    let load: () async throws -> Value
    let receive: (Result<Value, Error>) -> Void

    private struct Request: Equatable {
        let version: String?
        let attempt: Int
        let refresh: Int
    }

    func body(content: Content) -> some View {
        let request = Request(version: version, attempt: attempt, refresh: workspace.detailRefreshID)
        content.task(id: workspace.windowVisible ? request : nil) {
            guard workspace.windowVisible else { return }
            while !Task.isCancelled {
                let response: Result<Value, Error>
                do { response = .success(try await load()) }
                catch { response = .failure(error) }
                guard !Task.isCancelled else { return }
                receive(response)
                // Versioned objects refresh on change. Events and older servers have no revision here.
                if case .success = response, version != nil { return }
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
    }
}

private struct ConfigMapContent: View {
    let context: ContextID
    let row: ResourceRow
    let onShowNamespace: () -> Void
    @State private var result: Result<ConfigMapDetails, Error>?
    @State private var attempt = 0
    @State private var labelsExpanded = false
    @State private var annotationsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConfigInspectorSection("Properties") {
                ConfigPropertiesGrid(row: row, onShowNamespace: onShowNamespace) {
                    if case .success(let details) = result {
                        metadata("Labels", details.labels, expanded: $labelsExpanded)
                        metadata("Annotations", details.annotations, expanded: $annotationsExpanded)
                    }
                }
            }
            Divider()
            ConfigInspectorSection("Data") {
                switch result {
                case .success(let details):
                    if details.data.isEmpty {
                        Text("No text data keys").foregroundStyle(Palette.muted)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(details.data.keys.sorted(), id: \.self) { key in
                                ConfigMapValueRow(key: key, value: details.data[key] ?? "")
                            }
                        }
                    }
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(Palette.muted)
                    Button("Retry") { result = nil; attempt += 1 }
                        .controlSize(.small).accessibilityLabel("Retry config map data")
                case nil:
                    ProgressView().controlSize(.small)
                }
            }
            if case .success(let details) = result, !details.binaryData.isEmpty {
                Divider()
                ConfigInspectorSection("Binary Data") {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(details.binaryData.keys.sorted(), id: \.self) { key in
                            if let bytes = details.binaryData[key] {
                                ConfigMapValueRow(key: key, value: bytes.base64EncodedString(), binary: true)
                            }
                        }
                    }
                }
            }
        }
        .modifier(ResourceDetailRead(version: row.resourceVersion, attempt: attempt, load: {
            try await KubernetesClient().configMapDetails(for: row, in: context.file, context: context.name)
        }, receive: { result = $0 }))
    }

    @ViewBuilder private func metadata(_ title: String, _ entries: [String: String],
                                        expanded: Binding<Bool>) -> some View {
        GridRow {
            Text(title).foregroundStyle(Palette.muted)
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 5) {
                    Text(entries.count.formatted())
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                }
            }
            .buttonStyle(.plain).disabled(entries.isEmpty).foregroundStyle(entries.isEmpty ? Palette.muted : Palette.ink)
            .accessibilityLabel(title)
            .accessibilityValue("\(entries.count), " + (expanded.wrappedValue ? "expanded" : "collapsed"))
        }
        if expanded.wrappedValue {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries.keys.sorted(), id: \.self) { key in
                    let value = entries[key] ?? ""
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: key).fontWeight(.medium).textSelection(.enabled)
                        if value.isEmpty {
                            Text("Empty value").foregroundStyle(Palette.muted)
                        } else {
                            ConfigValueText(value: value, key: key, numbered: false)
                        }
                    }
                }
            }
            .gridCellColumns(2)
        }
    }
}

private struct ConfigMapValueRow: View {
    let key: String
    let value: String
    var binary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(verbatim: key).fontWeight(.medium).textSelection(.enabled)
                if binary { Text("Base64").font(.caption).foregroundStyle(Palette.muted) }
            }
            Group {
                if value.isEmpty {
                    Text("Empty value").foregroundStyle(Palette.muted).padding(8)
                } else {
                    ConfigValueText(value: value, key: key, numbered: !binary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
        }
    }
}

private struct ConfigValueText: View {
    let value: String
    let key: String
    let numbered: Bool

    var body: some View {
        let count = value.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        let visibleLines = numbered || value.utf8.count < 256 ? min(count, 10) : 8
        let height = CGFloat(visibleLines) * ConfigLineRuler.lineHeight + 14
        ScrollableConfigValue(value: value, key: key, lineCount: numbered ? count : nil)
            .frame(height: height)
            .clipped()
    }
}

final class ConfigLineRuler: NSRulerView {
    static let lineHeight: CGFloat = 17
    var lineCount = 1 {
        didSet {
            ruleThickness = CGFloat(String(lineCount).count) * 7 + 14
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView else { return }
        let startY = convert(view.textContainerOrigin, from: view).y
        let first = max(0, Int(floor((rect.minY - startY) / Self.lineHeight)))
        let end = min(lineCount, Int(ceil((rect.maxY - startY) / Self.lineHeight)))
        guard first < end else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(Palette.muted)
        ]
        for index in first..<end {
            let number = String(index + 1) as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: ruleThickness - size.width - 5,
                                    y: startY + (CGFloat(index) + 0.5) * Self.lineHeight - size.height / 2),
                        withAttributes: attributes)
        }
    }
}

struct ScrollableConfigValue: NSViewRepresentable {
    let value: String
    let key: String
    var lineCount: Int? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.clipsToBounds = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isRichText = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textColor = NSColor(Palette.ink)
            view.setAccessibilityLabel("Value for " + key)
            if let lineCount {
                scroll.hasHorizontalScroller = true
                scroll.hasHorizontalRuler = false
                view.isHorizontallyResizable = true
                view.textContainer?.widthTracksTextView = false
                view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                          height: CGFloat.greatestFiniteMagnitude)
                view.textContainerInset = NSSize(width: 2, height: 6)
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = ConfigLineRuler.lineHeight
                style.maximumLineHeight = ConfigLineRuler.lineHeight
                view.defaultParagraphStyle = style
                let ruler = ConfigLineRuler(scrollView: scroll, orientation: .verticalRuler)
                ruler.clipsToBounds = true
                ruler.clientView = view
                ruler.lineCount = lineCount
                scroll.verticalRulerView = ruler
                scroll.hasVerticalRuler = true
                scroll.rulersVisible = true
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != value else { return }
        view.string = value
        if let ruler = scroll.verticalRulerView as? ConfigLineRuler, let lineCount {
            ruler.lineCount = lineCount
        }
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
