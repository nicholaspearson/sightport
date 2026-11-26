import Darwin
import Foundation

public struct KubeContext: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let cluster: String
    public let namespace: String?
    public let isCurrent: Bool
}

public struct KubernetesClient: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL
    private let timeout: TimeInterval
    private let sdkExecutable: URL

    private var sdkEnvironment: [String: String] {
        var values = environment
        values["SIGHTPORT_PARENT_PID"] = String(getpid())
        return values
    }

    public init() {
        self.init(environment: ProcessInfo.processInfo.environment,
                  homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    init(environment: [String: String], homeDirectory: URL, timeout: TimeInterval = 15,
         sdkExecutable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sightport-kube")) {
        var environment = environment
        let searchPaths = (environment["PATH"] ?? "").components(separatedBy: ":")
            + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
               homeDirectory.appendingPathComponent(".local/bin").path,
               "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = searchPaths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .joined(separator: ":")
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.timeout = timeout
        self.sdkExecutable = sdkExecutable
    }

    public func defaultSources() -> [URL] {
        let paths = environment["KUBECONFIG"].flatMap { $0.isEmpty ? nil : $0 }?
            .split(separator: ":").map(String.init) ?? ["~/.kube/config"]
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = path.hasPrefix("~/")
                ? homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
                : URL(fileURLWithPath: path).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  seen.insert(resolved.path).inserted else { return nil }
            return url
        }
    }

    public func contexts(in file: URL) async throws -> [KubeContext] {
        // Read only local context metadata. The users and clusters sections may contain secrets.
        let output = try await run(["contexts"], file: file, operation: .discovery)
        guard let result = try? JSONDecoder().decode(ContextList.self, from: output) else {
            throw KubernetesError.invalidContexts
        }
        return result.entries.map {
            KubeContext(name: $0.name, cluster: $0.context.cluster ?? "",
                        namespace: $0.context.namespace, isCurrent: $0.name == result.current)
        }
    }

    public func testConnection(in file: URL, context: String) async throws {
        guard !context.isEmpty else { throw KubernetesError.missingContext }
        let arguments = ["--context=\(context)", "--request-timeout=8s", "get", "--raw=/version"]
        let output = try await run(arguments, file: file, operation: .connection)
        struct ServerVersion: Decodable { let gitVersion: String }
        guard let version = try? JSONDecoder().decode(ServerVersion.self, from: output),
              !version.gitVersion.isEmpty else {
            throw KubernetesError.unexpectedServer
        }
    }

    public func resources(_ kind: ResourceKind, in file: URL, context: String,
                          namespace: String? = nil) async throws -> [ResourceRow] {
        let output = try await resourceOutput(kind, in: file, context: context, namespace: namespace, template: kind.listTemplate)
        return try ResourceRow.decodeList(output, kind: kind)
    }

    public func resourceCount(_ kind: ResourceKind, in file: URL, context: String,
                              namespace: String? = nil) async throws -> Int {
        let output = try await resourceOutput(kind, in: file, context: context, namespace: namespace, template: "{{len .items}}")
        guard let text = String(data: output, encoding: .utf8),
              let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 else {
            throw ResourceReadError.invalidList
        }
        return count
    }

    public func podMetrics(in file: URL, context: String, namespace: String?) async throws -> [PodKey: PodUsage] {
        guard !context.isEmpty else { throw KubernetesError.missingContext }
        if namespace?.isEmpty == true { throw ResourceReadError.emptyNamespace }
        let scope = namespace.map { "--namespace=\($0)" } ?? "--all-namespaces"
        let arguments = ["--context=\(context)", "--request-timeout=8s", "metrics", scope]
        let output = try await run(arguments, file: file, operation: .podMetrics)
        return try PodUsage.decodeTable(output, namespace: namespace)
    }

    public func podLogs(in file: URL, context: String, namespace: String, pod: String,
                        container: String, previous: Bool) async throws -> String {
        guard !context.isEmpty else { throw KubernetesError.missingContext }
        guard !namespace.isEmpty else { throw ResourceReadError.emptyNamespace }
        guard !pod.isEmpty, !pod.contains("/"), !container.isEmpty else { throw PodReadError.missingLogTarget }
        let limit = 256 * 1024
        var arguments = ["--context=\(context)", "--request-timeout=8s", "logs", "pod/\(pod)",
                         "--namespace=\(namespace)", "--container=\(container)", "--tail=200", "--limit-bytes=\(limit)"]
        if previous { arguments.append("--previous") }
        let output = try await run(arguments, file: file, operation: .podLogs)
        return String(decoding: output.suffix(limit), as: UTF8.self)
    }

    func resourceOutput(_ kind: ResourceKind, in file: URL, context: String,
                        namespace: String?, template: String, fieldSelector: String? = nil) async throws -> Data {
        var arguments = try ResourceWatchTarget.resource(kind).arguments(context: context, namespace: namespace)
        if let fieldSelector { arguments.append("--field-selector=" + fieldSelector) }
        arguments += ["-o", "go-template=" + template]
        return try await run(arguments, file: file, operation: .resources(kind, namespace))
    }

    public func watchResources(_ target: ResourceWatchTarget, in file: URL, context: String, namespace: String? = nil,
                               onSnapshot: @escaping @Sendable ([ResourceRow]) async -> Void) async throws {
        let executable = try executable(for: file)
        try await streamResourceRows(target, executable: executable, file: file, context: context, namespace: namespace,
                                     environment: sdkEnvironment, timeout: timeout, onSnapshot: onSnapshot)
    }

    public func portForwardNames(_ kind: PortForwardTargetKind, in file: URL, context: String,
                                 namespace: String) async throws -> [String] {
        let namespace = try PortForwardRequest.validatedNamespace(namespace)
        let output = try await resourceOutput(kind == .pod ? .pods : .services, in: file, context: context,
                                              namespace: namespace, template: #"{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}"#)
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    }

    public func openPortForward(in file: URL, context: String, request: PortForwardRequest,
                                onStatus: @escaping @Sendable (PortForwardStatus) -> Void) throws -> PortForwardSession {
        guard !context.isEmpty, !context.utf8.contains(0) else { throw KubernetesError.missingContext }
        let executable = try executable(for: file)
        let local = request.localPort.map { String($0) } ?? ""
        let arguments = ["--kubeconfig=\(file.path)", "--context=\(context)", "--namespace=\(request.namespace)",
                         "port-forward", "--address=127.0.0.1",
                         request.kind.rawValue + "/" + request.name, local + ":" + request.remotePort]
        return try PortForwardSession(executable: executable, arguments: arguments, environment: sdkEnvironment,
                                      onStatus: onStatus)
    }

    public func openPodTerminal(in file: URL, context: String, namespace: String, pod: String, container: String,
                                shell: String = "/bin/sh", columns: Int = 80, rows: Int = 24,
                                onOutput: @escaping @Sendable (Data) -> Void,
                                onExit: @escaping @Sendable (Int32) -> Void) throws -> PodTerminalSession {
        guard !context.isEmpty, !context.utf8.contains(0) else { throw KubernetesError.missingContext }
        guard !namespace.isEmpty, !pod.isEmpty, !container.isEmpty,
              [namespace, pod, container].allSatisfy({ !$0.contains("/") && !$0.utf8.contains(0) }),
              shell.hasPrefix("/"), !shell.utf8.contains(0) else { throw PodTerminalError.invalidTarget }
        let executable = try executable(for: file)
        let arguments = ["--kubeconfig=\(file.path)", "--context=\(context)", "--namespace=\(namespace)",
                         "exec", "--stdin", "--tty", "--container=\(container)", "pod/\(pod)", "--", shell]
        var terminalEnvironment = sdkEnvironment
        terminalEnvironment["TERM"] = "xterm-256color"
        return try PodTerminalSession(executable: executable, arguments: arguments, environment: terminalEnvironment,
                                      columns: columns, rows: rows, onOutput: onOutput, onExit: onExit)
    }

    private func executable(for file: URL, helm: Bool = false) throws -> URL {
        let resolvedFile = file.resolvingSymlinksInPath()
        guard file.isFileURL,
              (try? resolvedFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: file.path) else {
            throw KubernetesError.unreadableFile
        }
        if !helm {
            guard FileManager.default.isExecutableFile(atPath: sdkExecutable.path) else { throw KubernetesError.missingSDK }
            return sdkExecutable
        }
        let executable = environment["PATH", default: ""].split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("helm") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable else { throw KubernetesError.missingHelm }
        return executable
    }

    func run(_ arguments: [String], file: URL, operation: ClusterOperation) async throws -> Data {
        let executable = try executable(for: file, helm: operation.usesHelm)
        // Helm's global connection overrides must not silently redirect the selected context.
        let commandEnvironment = operation.usesHelm
            ? environment.filter { !$0.key.hasPrefix("HELM_KUBE") && $0.key != "HELM_NAMESPACE" }
            : sdkEnvironment
        let worker = Task.detached(priority: .userInitiated) {
            try runClusterCommand(executable: executable, arguments: ["--kubeconfig=\(file.path)"] + arguments,
                                  environment: commandEnvironment, operation: operation, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func selectedNamespace(for row: ResourceRow, context: String, missing: KubernetesError) throws -> String {
        guard !context.isEmpty, !context.utf8.contains(0) else { throw KubernetesError.missingContext }
        guard let namespace = row.namespace, !namespace.isEmpty,
              !row.name.isEmpty, !row.id.isEmpty, row.id != namespace + "/" + row.name,
              [row.name, namespace, row.id].allSatisfy({ !$0.contains("/") && !$0.utf8.contains(0) }) else {
            throw missing
        }
        return namespace
    }
}

private struct ContextList: Decodable {
    struct Entry: Decodable {
        struct Details: Decodable {
            let cluster: String?
            let namespace: String?
        }
        let name: String
        let context: Details
    }
    let current: String
    let entries: [Entry]

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        current = try values.decodeIfPresent(String.self) ?? ""
        entries = try values.decodeIfPresent([Entry].self) ?? []
    }
}

enum ClusterOperation {
    case discovery, connection, resources(ResourceKind, String?), podMetrics, podLogs, podInspection
    case secretDetails, configMapDetails, podTermination
    case customResources(String, String?), helmReleases

    var usesHelm: Bool {
        if case .helmReleases = self { return true }
        return false
    }
}

enum KubernetesError: LocalizedError {
    case missingSDK, missingHelm, unreadableFile, launch, invalidContexts, missingContext
    case helmLaunch, helmUnavailable, helmDenied, customResourceDenied(String), customResourceUnavailable(String)
    case resourceDenied(ResourceKind, String?), unsupported(ResourceKind), namespaceMissing(String)
    case secretDenied, secretMissing, secretUnavailable
    case podInspectionUnavailable, podInspectionDenied
    case podIdentityMissing, podTerminationDenied, podTerminationMissing, podTerminationConflict, podTerminationUnconfirmed
    case configMapDenied, configMapMissing, configMapUnavailable
    case metricsDenied, metricsUnavailable, logsDenied, logTargetMissing, containerWaiting, previousUnavailable, logsUnavailable
    case unavailable, authentication, denied, certificate, credentialHelper, timeout, unexpectedServer, output

    var errorDescription: String? {
        switch self {
        case .podInspectionUnavailable: return "Could not read this pod’s container details."
        case .podInspectionDenied: return "This context does not have permission to get this pod."
        case .podIdentityMissing: return "Select a pod with a namespace, name, and UID."
        case .podTerminationDenied: return "This context lacks permission to terminate the pod."
        case .podTerminationMissing: return "The selected pod no longer exists."
        case .podTerminationConflict: return "The cluster rejected the deletion because the pod changed. Select the current pod to continue."
        case .podTerminationUnconfirmed: return "Sightport could not confirm whether the cluster accepted termination. Check the pod’s status before trying again."
        case .missingSDK: return "The bundled Kubernetes client is missing. Reinstall Sightport and reopen the app."
        case .missingHelm: return "Install the Helm 3 or 4 command-line tool to view releases. Sightport checks your PATH and standard Homebrew locations."
        case .helmLaunch: return "Sightport could not start Helm. Check that it can run on this Mac."
        case .helmUnavailable: return "Helm could not list releases. Check your connection and Helm installation."
        case .helmDenied: return "Access denied. This context cannot list Helm releases in the selected scope."
        case .customResourceDenied(let resource): return "Access denied. This context cannot list " + resource + " in the selected scope."
        case .customResourceUnavailable(let resource): return "The API for " + resource + " is unavailable on this cluster. Refresh the custom resource definitions."
        case .unreadableFile: return "The kubeconfig file is missing or unreadable. Choose its current location."
        case .launch: return "Sightport could not start its bundled Kubernetes client."
        case .invalidContexts: return "Sightport could not read the contexts. Check that the file contains a valid kubeconfig."
        case .missingContext: return "This context is missing from the kubeconfig. Choose an available context."
        case .unavailable: return "Could not reach the Kubernetes API. Check the server address, network, and VPN."
        case .secretDenied: return "Access denied. This context cannot get this Secret."
        case .secretMissing: return "This Secret is no longer available. Refresh the Secrets list."
        case .secretUnavailable: return "Could not read the selected Secret."
        case .configMapDenied: return "Access denied. This context cannot get this Config Map."
        case .configMapMissing: return "This Config Map is no longer available. Refresh the Config Maps list."
        case .configMapUnavailable: return "Could not read the selected Config Map."
        case .authentication: return "The cluster rejected these credentials. Refresh your login and test again."
        case .resourceDenied(let kind, let namespace):
            let scope = kind.isNamespaced ? (namespace.map { " in namespace “" + $0 + "”" } ?? " across all namespaces") : ""
            if ResourceKind.argoSettings.contains(kind) {
                return "Access denied. Viewing Argo CD " + kind.title.lowercased() + " requires permission to list Secrets" + scope + "."
            }
            return "Access denied. This context cannot list " + kind.title.lowercased() + scope + "."
        case .unsupported(let kind):
            if ResourceKind.argoResources.contains(kind) || ResourceKind.karpenter.contains(kind) {
                return "The API for " + kind.resourceName + " is unavailable on this cluster."
            }
            return "This cluster does not serve " + kind.title.lowercased() + "."
        case .namespaceMissing(let name): return "The namespace “" + name + "” was not found."
        case .metricsDenied: return "This context does not have permission to read pod metrics in this scope."
        case .metricsUnavailable: return "Pod usage is unavailable from the cluster’s Metrics API."
        case .logsDenied: return "This context does not have permission to read this pod’s logs."
        case .logTargetMissing: return "The pod or container could not be found. Refresh the Pods table."
        case .containerWaiting: return "This container is waiting to start. Try refreshing its logs after it starts."
        case .previousUnavailable: return "There are no logs available for a previous instance of this container."
        case .logsUnavailable: return "Could not read this container’s logs."
        case .denied: return "The cluster denied access to its version endpoint."
        case .certificate: return "The server certificate could not be verified. Check the kubeconfig certificate authority."
        case .credentialHelper: return "The credential helper failed. Check that it is installed and that you are signed in."
        case .timeout: return "The check timed out. Check the network and any credentials required by this context."
        case .unexpectedServer: return "The server response did not contain a Kubernetes version. Check the API address."
        case .output: return "The cluster query exceeded Sightport’s 4 MiB output limit."
        }
    }

    static func failure(stderr: Data, operation: ClusterOperation) -> Self {
        if case .discovery = operation { return .invalidContexts }
        // Credential helpers control stderr. Use it only for classification, never for display or storage.
        let message = String(decoding: stderr, as: UTF8.self).lowercased()
        if case .podTermination = operation {
            // The final helper diagnostic describes this DELETE. Credential plugins
            // can write unrelated messages to the same stderr stream.
            switch message.split(whereSeparator: \.isNewline).last {
            case "pod-delete-invalid-target": return .podIdentityMissing
            case "pod-delete-forbidden": return .podTerminationDenied
            case "pod-delete-not-found": return .podTerminationMissing
            case "pod-delete-conflict": return .podTerminationConflict
            case "unauthorized": return .authentication
            case "context not found": return .missingContext
            default: return .podTerminationUnconfirmed
            }
        }
        if message.contains("context") && (message.contains("not exist") || message.contains("not found")) { return .missingContext }
        if message.contains("unauthorized") || message.contains("credentials (get") { return .authentication }
        if case .customResources(let resource, let namespace) = operation {
            if message.contains("forbidden") { return .customResourceDenied(resource) }
            if let namespace, message.contains("namespaces"), message.contains("not found") { return .namespaceMissing(namespace) }
            if message.contains("doesn't have a resource type") || message.contains("could not find the requested resource")
                || message.contains("no matches for") { return .customResourceUnavailable(resource) }
        }
        if case .resources(let kind, let namespace) = operation {
            if message.contains("forbidden") { return .resourceDenied(kind, namespace) }
            if let namespace, kind.isNamespaced, message.contains("namespaces"), message.contains("not found") {
                return .namespaceMissing(namespace)
            }
            if message.contains("doesn't have a resource type") || message.contains("could not find the requested resource")
                || message.contains("no matches for") {
                return .unsupported(kind)
            }
        }
        if message.contains("forbidden") {
            switch operation {
            case .podMetrics: return .metricsDenied
            case .podLogs: return .logsDenied
            case .podInspection: return .podInspectionDenied
            case .helmReleases: return .helmDenied
            case .secretDetails: return .secretDenied
            case .configMapDetails: return .configMapDenied
            default: return .denied
            }
        }
        if message.contains("x509") || message.contains("certificate") { return .certificate }
        if message.contains("getting credentials") || message.contains("exec plugin") { return .credentialHelper }
        if message.contains("timeout") || message.contains("deadline exceeded") { return .timeout }
        if case .helmReleases = operation { return .helmUnavailable }
        if case .configMapDetails = operation {
            if message.contains("notfound") || message.contains("not found") { return .configMapMissing }
            return .configMapUnavailable
        }
        if case .secretDetails = operation {
            if message.contains("notfound") || message.contains("not found") { return .secretMissing }
            return .secretUnavailable
        }
        if case .podMetrics = operation { return .metricsUnavailable }
        if case .podInspection = operation {
            return message.contains("not found") ? .logTargetMissing : .podInspectionUnavailable
        }
        if case .podLogs = operation {
            if message.contains("previous terminated container") { return .previousUnavailable }
            if message.contains("waiting to start") { return .containerWaiting }
            if message.contains("not found") || message.contains("is not valid for pod") { return .logTargetMissing }
            return .logsUnavailable
        }
        return .unavailable
    }
}

// An idle long-lived watch can sleep in poll until the SDK sends new bytes.
// Closing this private pipe wakes it immediately when its view disappears.
final class ClusterReadCancellation: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            try? pipe.fileHandleForWriting.close()
        }
    }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

// Read both pipes on the worker task. Polling bounds cancellation latency even when an
// external credential helper hangs with an output descriptor open.
func runClusterCommand(executable: URL, arguments: [String], environment: [String: String],
                       operation: ClusterOperation, timeout: TimeInterval, cancellation: ClusterReadCancellation? = nil,
                       onOutput: ((Data) throws -> Void)? = nil, onTick: (() throws -> Int32)? = nil) throws -> Data {
    try Task.checkCancellation()
    try cancellation?.check()
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch {
        throw operation.usesHelm ? KubernetesError.helmLaunch : KubernetesError.launch
    }
    defer {
        if process.isRunning {
            let pid = process.processIdentifier
            // Foundation typically puts the child in its own process group. Stop any
            // helper in that group too, without targeting the application's group.
            _ = Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            process.waitUntilExit()
        }
    }

    let pipes = [stdout, stderr]
    var descriptors = pipes.map { pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0) }
    for descriptor in descriptors {
        let flags = fcntl(descriptor.fd, F_GETFL)
        guard flags >= 0, fcntl(descriptor.fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw KubernetesError.launch }
    }
    if let cancellation {
        descriptors.append(pollfd(fd: cancellation.pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0))
    }
    var pollInterval: Int32 = 100
    var buffers = [Data(), Data()]
    var chunk = [UInt8](repeating: 0, count: 16_384)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
        try Task.checkCancellation()
        try cancellation?.check()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw KubernetesError.timeout }
        let running = process.isRunning
        // Pipe EOF can arrive just before Foundation observes process exit. Once
        // both pipes are drained, don't wait an idle watch interval to report it.
        let interval = descriptors.prefix(2).allSatisfy { $0.fd < 0 } ? min(pollInterval, 20) : pollInterval
        let ready = poll(&descriptors, nfds_t(descriptors.count), running ? interval : 0)
        if ready < 0 {
            if errno == EINTR { continue }
            throw KubernetesError.launch
        }
        for index in buffers.indices where descriptors[index].fd >= 0 {
            let descriptor = descriptors[index]
            guard descriptor.revents != 0 || !running else { continue }
            // Give cancellation, timers and the other pipe a turn under sustained output.
            for _ in 0..<64 {
                let count = Darwin.read(descriptor.fd, &chunk, chunk.count)
                if count == 0 { descriptors[index].fd = -1; break }
                if count < 0 {
                    if errno == EINTR { continue }
                    guard errno == EAGAIN || errno == EWOULDBLOCK else { throw KubernetesError.launch }
                    break
                }
                if index == 0, let onOutput {
                    try onOutput(Data(chunk.prefix(count)))
                    continue
                }
                guard buffers[index].count + count <= 4 * 1024 * 1024 else { throw KubernetesError.output }
                buffers[index].append(contentsOf: chunk.prefix(count))
            }
        }
        try cancellation?.check()
        pollInterval = try onTick?() ?? 100
        if !running && descriptors.prefix(2).allSatisfy({ $0.fd < 0 || $0.revents == 0 }) { break }
    }
    guard process.terminationStatus == 0 else {
        throw KubernetesError.failure(stderr: buffers[1], operation: operation)
    }
    return buffers[0]
}
