import AppKit
import SwiftUI
import SightportCore

struct PodLogsView: View {
    @ObservedObject var workspace: Workspace
    let target: PodLogTarget
    let isVisible: Bool

    @State private var deploymentPods: [LogPod]?
    @State private var discoveryError: String?
    @State private var selectedPodID: String?
    @State private var selectedContainer = ""
    @State private var previousPodID: String?
    @State private var refreshNumber = 0
    @State private var findRequest = 0
    @State private var result: LogResult?

    private struct Request: Equatable {
        let podID: String
        let container: String
        let previous: Bool
        let refreshNumber: Int
        let restartCount: Int?
    }

    private struct LogResult {
        let request: Request
        let lines: Result<String, Error>
    }

    private var selectedPod: LogPod? {
        if target.kind == .pods { return LogPod(row: target.row) }
        return deploymentPods?.first(where: { $0.id == selectedPodID }) ?? deploymentPods?.first
    }

    var body: some View {
        let pod = selectedPod
        let request = pod.flatMap { logRequest(for: $0) }
        let active = isVisible && workspace.windowVisible
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 10) {
                    if target.kind == .deployments {
                        Picker("Pod", selection: Binding(get: { pod?.id ?? "" }, set: {
                            selectedPodID = $0
                            previousPodID = nil
                        })) {
                            if deploymentPods?.isEmpty != false { Text("Unavailable").tag("") }
                            ForEach(deploymentPods ?? []) { Text(verbatim: $0.name).tag($0.id) }
                        }
                        .accessibilityLabel("Deployment pod")
                        .disabled(deploymentPods?.isEmpty != false)
                        .frame(maxWidth: 310)
                    }
                    Picker("Container", selection: Binding(get: { request?.container ?? "" }, set: { selectedContainer = $0 })) {
                        if pod?.containers.isEmpty != false { Text("Unavailable").tag("") }
                        ForEach(pod?.containers ?? [], id: \.name) { item in
                            Text(verbatim: item.name).tag(item.name)
                        }
                    }
                    .accessibilityLabel("Log container")
                    .disabled(request == nil).frame(maxWidth: 265)
                    Toggle("Previous instance", isOn: Binding(get: { request?.previous == true }, set: {
                        previousPodID = $0 ? pod?.id : nil
                    })).toggleStyle(.checkbox).fixedSize().disabled(request == nil)
                        .help("Read the last terminated instance of this container")
                    Spacer(minLength: 0)
                    if let request, result?.request == request, case .success(let text) = result?.lines, !text.isEmpty {
                        IconAction(symbol: "magnifyingglass", title: "Find in logs") { findRequest += 1 }
                    }
                    IconAction(symbol: "arrow.clockwise", title: "Refresh logs") { refreshNumber += 1 }
                }
                .controlSize(.small)
                .padding(.leading, 12).padding(.trailing, 6).frame(height: 34)
                Divider()
                output(for: request)
                    .background(Palette.sidebar)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .task(id: active && target.kind == .deployments ? refreshNumber : nil) {
            guard active, target.kind == .deployments else { return }
            await observeDeploymentPods()
        }
        .task(id: active ? request : nil) {
            guard active, let pod, let request else { return }
            while !Task.isCancelled {
                let lines: Result<String, Error>
                do {
                    lines = .success(try await workspace.loadPodLogs(for: target, pod: pod, container: request.container,
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

    private func logRequest(for pod: LogPod) -> Request? {
        guard let container = pod.containers.first(where: { $0.name == selectedContainer }) ?? pod.containers.first else { return nil }
        let previous = pod.id == previousPodID
        return Request(podID: pod.id, container: container.name, previous: previous,
                       refreshNumber: refreshNumber, restartCount: previous ? container.restartCount : nil)
    }

    @ViewBuilder
    private func output(for request: Request?) -> some View {
        if let discoveryError {
            message(discoveryError, symbol: "exclamationmark.circle")
        } else if target.kind == .deployments && deploymentPods?.isEmpty == true {
            message("This Deployment has no pods.", symbol: "shippingbox")
        } else if selectedPod?.containers.isEmpty == true {
            message("This pod has no containers.", symbol: "shippingbox")
        } else if let request, let result, result.request == request {
            switch result.lines {
            case .success(let text) where text.isEmpty:
                message("No log output for this container instance.", symbol: "text.alignleft")
            case .success(let text):
                LogText(text: text, findRequest: findRequest)
            case .failure(let error):
                message(error.localizedDescription, symbol: "exclamationmark.circle")
            }
        } else {
            ProgressView(target.kind == .deployments && deploymentPods == nil ? "Loading deployment pods…" : "Loading logs…")
                .controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func observeDeploymentPods() async {
        while !Task.isCancelled {
            do {
                let pods = try await workspace.loadDeploymentLogPods(for: target)
                guard !Task.isCancelled, workspace.podLogTarget?.id == target.id else { return }
                if selectedPodID == nil || !pods.contains(where: { $0.id == selectedPodID }) {
                    selectedPodID = pods.first?.id
                    previousPodID = nil
                }
                if deploymentPods != pods { deploymentPods = pods }
                if discoveryError != nil { discoveryError = nil }
            } catch {
                guard !Task.isCancelled, workspace.podLogTarget?.id == target.id else { return }
                deploymentPods = nil
                result = nil
                discoveryError = error.localizedDescription
            }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
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

    private static let logAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return [.foregroundColor: NSColor(Palette.ink),
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .paragraphStyle: paragraph]
    }()

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
            view.textContainerInset = NSSize(width: 12, height: 10)
            view.isHorizontallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
            view.setAccessibilityLabel("Container log output")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let oldText = view.string
        if oldText != text {
            let viewport = scroll.documentVisibleRect
            let selection = view.selectedRange()
            let followTail = oldText.isEmpty || (selection.length == 0 && viewport.maxY >= view.bounds.maxY - 2)
            let newText = text as NSString
            // Plain string edits to NSTextStorage can drop the console's font and foreground color.
            if text.utf8.starts(with: oldText.utf8) {
                let suffix = newText.substring(from: storage.length)
                storage.append(NSAttributedString(string: suffix, attributes: Self.logAttributes))
            } else {
                storage.setAttributedString(NSAttributedString(string: text, attributes: Self.logAttributes))
                if NSMaxRange(selection) <= newText.length { view.setSelectedRange(selection) }
            }
            var offset = viewport.origin
            if followTail {
                if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
                offset.y = max(0, view.bounds.maxY - viewport.height)
            }
            scroll.contentView.scroll(to: offset)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if context.coordinator.handledFindRequest != findRequest {
            context.coordinator.handledFindRequest = findRequest
            let command = NSMenuItem()
            command.tag = NSTextFinder.Action.showFindInterface.rawValue
            view.performTextFinderAction(command)
        }
    }
}
