import Foundation

public enum ResourceWatchTarget: Hashable, Sendable {
    case resource(ResourceKind)
    case custom(CustomResourceType)

    func arguments(context: String, namespace: String?, requestTimeout: String = "8s") throws -> [String] {
        guard !context.isEmpty, !context.utf8.contains(0) else { throw KubernetesError.missingContext }
        let name: String, namespaced: Bool, selector: String?
        switch self {
        case .resource(let kind):
            (name, namespaced, selector) = (kind.resourceName, kind.isNamespaced, kind.argoLabelSelector)
        case .custom(let type):
            (name, namespaced, selector) = (type.versionedName, type.isNamespaced, nil)
        }
        var args = ["--context=" + context, "--request-timeout=" + requestTimeout, "get", name]
        if namespaced {
            guard namespace?.isEmpty != true else { throw ResourceReadError.emptyNamespace }
            args.append(namespace.map { "--namespace=" + $0 } ?? "--all-namespaces")
        }
        if let selector { args.append("--selector=" + selector) }
        if case .custom(let type) = self { args.append("--api-version=" + type.version) }
        return args
    }

    func operation(namespace: String?) -> ClusterOperation {
        switch self {
        case .resource(let kind): return .resources(kind, namespace)
        case .custom(let type): return .customResources(type.resourceName, type.isNamespaced ? namespace : nil)
        }
    }

    private var rowTemplate: String {
        switch self {
        case .resource(let kind): return kind.rowTemplate
        case .custom: return CustomResourceType.rowTemplate
        }
    }

    var listTemplate: String { "{{range .items}}" + rowTemplate + #"{{"\n"}}{{end}}"# }

    var watchTemplate: String {
        // Framing uses a separator outside the URL-escaped field alphabet.
        let separator = #"{{"\x1f"}}"#
        let fields = rowTemplate.replacingOccurrences(of: #"{{"\t"}}"#, with: separator)
        return #"{{$action := .type}}{{if eq .type "ERROR"}}ERROR{{"\n"}}{{else if ne .type "BOOKMARK"}}{{.type}}"# + separator
            + #"{{with .object}}{{if eq $action "DELETED"}}{{if .metadata.uid}}{{urlquery .metadata.uid}}{{else}}{{with .metadata.namespace}}{{urlquery .}}{{end}}/{{urlquery .metadata.name}}{{end}}{{else}}"#
            + fields + #"{{end}}{{end}}{{"\n"}}{{end}}"#
    }

    func decode(_ data: Data) throws -> [ResourceRow] {
        switch self {
        case .resource(let kind): return try ResourceRow.decodeList(data, kind: kind)
        case .custom: return try ResourceRow.decodeList(data, columnCount: CustomResourceType.columns.count)
        }
    }
}

// Mutated exclusively on the SDK reader. Only complete, immutable snapshots
// cross into the UI, and a slower consumer only needs the newest snapshot.
private final class WatchedRows {
    let target: ResourceWatchTarget
    private var rows: [String: ResourceRow] = [:]
    private var order: [String] = []
    private var pending = Data()
    private var dirty = false
    private var synchronized = false
    private let initialDeadline: TimeInterval
    private var lastPublish = ProcessInfo.processInfo.systemUptime

    init(target: ResourceWatchTarget, timeout: TimeInterval) {
        self.target = target
        initialDeadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    func consume(_ data: Data, publish: ([ResourceRow]) -> Void) throws {
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]
            if line.elementsEqual("SYNC".utf8) {
                guard !synchronized else { throw ResourceReadError.invalidWatch }
                // The SDK has finished the list, including all pages. Its watch starts
                // at this list's resourceVersion, even when the list was empty.
                synchronized = true
                publish(order.compactMap { rows[$0] })
                lastPublish = ProcessInfo.processInfo.systemUptime
                dirty = false
                pending.removeSubrange(...end)
                continue
            }
            guard let split = line.firstIndex(of: 31) else { throw ResourceReadError.invalidWatch }
            let action = String(decoding: line[..<split], as: UTF8.self)
            let payload = line[line.index(after: split)...]
            switch action {
            case "ADDED", "MODIFIED":
                let bytes = Data(payload.map { $0 == 31 ? 9 : $0 })
                guard let row = try target.decode(bytes).first else { throw ResourceReadError.invalidWatch }
                if rows[row.id] != row {
                    if rows.updateValue(row, forKey: row.id) == nil { order.append(row.id) }
                    dirty = true
                }
            case "DELETED":
                guard let id = String(data: payload, encoding: .utf8)?.removingPercentEncoding, !id.isEmpty else {
                    throw ResourceReadError.invalidWatch
                }
                remove(id)
            default: throw ResourceReadError.invalidWatch
            }
            pending.removeSubrange(...end)
        }
        guard pending.count <= 4 * 1024 * 1024 else { throw KubernetesError.output }
    }

    private func remove(_ id: String) {
        if rows.removeValue(forKey: id) != nil {
            order.removeAll { $0 == id }
            dirty = true
        }
    }

    func tick(publish: ([ResourceRow]) -> Void, force: Bool = false) throws -> Int32 {
        let now = ProcessInfo.processInfo.systemUptime
        if !synchronized {
            guard now < initialDeadline else { throw KubernetesError.timeout }
            if force { throw ResourceReadError.invalidWatch }
            return 250
        }
        if force && !pending.isEmpty { throw ResourceReadError.invalidWatch }
        if dirty, force || now - lastPublish >= 0.12 {
            publish(order.compactMap { rows[$0] })
            lastPublish = now
            dirty = false
        }
        if dirty { return 120 }
        return 5000
    }
}

func streamResourceRows(_ target: ResourceWatchTarget, executable: URL, file: URL, context: String,
                        namespace: String?, environment: [String: String], timeout: TimeInterval,
                        onSnapshot: @escaping @Sendable ([ResourceRow]) async -> Void) async throws {
    let config = ["--kubeconfig=" + file.path]
    let watch = config + (try target.arguments(context: context, namespace: namespace, requestTimeout: "10m"))
        + ["--watch", "--initial-snapshot", "--output-watch-events", "-o", "go-template=" + target.watchTemplate]
    let operation = target.operation(namespace: namespace)
    let (stream, continuation) = AsyncThrowingStream<[ResourceRow], Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let cancellation = ClusterReadCancellation()
    @Sendable func read() {
        func publish(_ rows: [ResourceRow]) { continuation.yield(rows) }
        do {
            let state = WatchedRows(target: target, timeout: timeout)
            _ = try runClusterCommand(executable: executable, arguments: watch, environment: environment,
                                      operation: operation, timeout: 610, cancellation: cancellation,
                                      onOutput: { try state.consume($0, publish: publish) },
                                      onTick: { try state.tick(publish: publish) })
            _ = try state.tick(publish: publish, force: true)
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
    try await withTaskCancellationHandler {
        // Blocking pipe I/O on the cooperative Swift executor can starve other windows.
        async let reader: Void = withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                read()
                done.resume()
            }
        }
        for try await rows in stream {
            try Task.checkCancellation()
            await onSnapshot(rows)
        }
        await reader
        try Task.checkCancellation()
    } onCancel: {
        cancellation.cancel()
    }
}
