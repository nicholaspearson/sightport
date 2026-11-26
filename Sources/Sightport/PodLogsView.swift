import AppKit
import SwiftUI
import SightportCore

struct PodLogsView: View {
    @ObservedObject var workspace: Workspace
    let target: PodLogTarget
    let isVisible: Bool

    @State private var container: String
    @State private var previous = false
    @State private var refreshNumber = 0
    @State private var findRequest = 0
    @State private var result: LogResult?

    private struct Request: Equatable {
        let container: String
        let previous: Bool
        let refreshNumber: Int
        let restartCount: Int?
    }

    private struct LogResult {
        let request: Request
        let lines: Result<String, Error>
    }

    init(workspace: Workspace, target: PodLogTarget, isVisible: Bool) {
        self.workspace = workspace
        self.target = target
        self.isVisible = isVisible
        let first = target.containers.first { $0.role == .app } ?? target.containers.first
        _container = State(initialValue: first?.name ?? "")
    }

    var body: some View {
        let restartCount = previous ? workspace.rows.first(where: { $0.id == target.podID })?.pod?
            .containers.first(where: { $0.name == container })?.restartCount : nil
        let request = Request(container: container, previous: previous, refreshNumber: refreshNumber, restartCount: restartCount)
        let active = isVisible && workspace.windowVisible
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 10) {
                    Picker("Container", selection: $container) {
                        ForEach(target.containers, id: \.name) { item in
                            Text(item.name).tag(item.name)
                        }
                    }
                    .accessibilityLabel("Log container")
                    .controlSize(.small).frame(maxWidth: 265)
                    Toggle("Previous instance", isOn: $previous).toggleStyle(.checkbox)
                        .controlSize(.small).fixedSize()
                        .help("Read the last terminated instance of this container")
                    Spacer(minLength: 0)
                    if result?.request == request, case .success(let text) = result?.lines, !text.isEmpty {
                        IconAction(symbol: "magnifyingglass", title: "Find in logs") { findRequest += 1 }
                    }
                    IconAction(symbol: "arrow.clockwise", title: "Refresh logs") { refreshNumber += 1 }
                }
                .padding(.leading, 12).padding(.trailing, 6).frame(height: 34)
                Divider()
                Group {
                    if let result, result.request == request {
                        switch result.lines {
                        case .success(let text) where text.isEmpty:
                            message("No log output for this container instance.", symbol: "text.alignleft")
                        case .success(let text):
                            LogText(text: text, findRequest: findRequest)
                        case .failure(let error):
                            message(error.localizedDescription, symbol: "exclamationmark.circle")
                        }
                    } else {
                        ProgressView("Loading logs…").controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Palette.sidebar)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .onChange(of: target.containers.map(\.name)) { _, names in
            guard !names.contains(container) else { return }
            container = target.containers.first { $0.role == .app }?.name ?? names.first ?? ""
            previous = false
        }
        .task(id: active ? request : nil) {
            guard active else { return }
            while !Task.isCancelled {
                let lines: Result<String, Error>
                do {
                    lines = .success(try await workspace.loadPodLogs(for: target, container: request.container,
                                                                     previous: request.previous))
                } catch { lines = .failure(error) }
                guard !Task.isCancelled, workspace.podLogTarget?.id == target.id else { return }
                result = LogResult(request: request, lines: lines)
                if request.previous { return }
                let delay: Duration
                switch lines {
                case .success: delay = .seconds(3)
                case .failure: delay = .seconds(15)
                }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center).textSelection(.enabled).padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// A selectable, plain-text AppKit buffer keeps long lines horizontally scrollable.
private struct LogText: NSViewRepresentable {
    let text: String
    let findRequest: Int

    final class Coordinator {
        var handledFindRequest: Int
        init(_ request: Int) { handledFindRequest = request }
    }

    func makeCoordinator() -> Coordinator { Coordinator(findRequest) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            view.drawsBackground = false
            view.textColor = NSColor(Palette.ink)
            view.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            view.textContainerInset = NSSize(width: 10, height: 8)
            view.isHorizontallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
            view.setAccessibilityLabel("Container log output")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            let viewport = scroll.documentVisibleRect
            let selection = view.selectedRange()
            let followTail = view.string.isEmpty || (selection.length == 0 && viewport.maxY >= view.bounds.maxY - 2)
            let previousLength = (view.string as NSString).length
            let newText = text as NSString
            if text.utf8.starts(with: view.string.utf8), let storage = view.textStorage {
                storage.replaceCharacters(in: NSRange(location: previousLength, length: 0),
                                          with: newText.substring(from: previousLength))
            } else {
                view.string = text
                if NSMaxRange(selection) <= newText.length { view.setSelectedRange(selection) }
            }
            if followTail {
                view.scrollRangeToVisible(NSRange(location: newText.length, length: 0))
            } else {
                scroll.contentView.scroll(to: viewport.origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if context.coordinator.handledFindRequest != findRequest {
            context.coordinator.handledFindRequest = findRequest
            let command = NSMenuItem()
            command.tag = NSTextFinder.Action.showFindInterface.rawValue
            view.performTextFinderAction(command)
        }
    }
}
