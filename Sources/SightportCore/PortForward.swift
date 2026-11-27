import Darwin
import Foundation

public enum PortForwardTargetKind: String, CaseIterable, Sendable { case pod, service }

public struct PortForwardRequest: Equatable, Sendable {
    public let kind: PortForwardTargetKind
    public let namespace: String
    public let name: String
    public private(set) var podUID: String?
    public let localPort: UInt16?
    public let remotePort: String

    public init(pod row: ResourceRow, localPort: String, remotePort: String) throws {
        guard !row.id.isEmpty, !row.id.utf8.contains(0) else { throw KubernetesError.podIdentityMissing }
        try self.init(kind: .pod, namespace: row.namespace ?? "", name: row.name,
                      localPort: localPort, remotePort: remotePort)
        podUID = row.id
    }

    public init(kind: PortForwardTargetKind, namespace: String, name: String,
                localPort: String, remotePort: String) throws {
        let namespace = try Self.validatedNamespace(namespace)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remotePort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.utf8.count <= 253, !name.isEmpty,
              name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Self.validLabel(String($0)) })
        else { throw PortForwardError.name }
        let number = Self.port(local)
        guard local.isEmpty || number != nil else { throw PortForwardError.local }
        let named = Self.validLabel(remote) && remote.utf8.count <= 15 && !remote.contains("--")
            && remote.utf8.contains(where: { (97...122).contains($0) })
        guard Self.port(remote) != nil || named else { throw PortForwardError.remote }
        self.kind = kind
        self.namespace = namespace
        self.name = name
        self.localPort = number
        self.remotePort = remote
    }

    static func validatedNamespace(_ text: String) throws -> String {
        let namespace = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard namespace.utf8.count <= 63, validLabel(namespace) else { throw PortForwardError.namespace }
        return namespace
    }

    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.first != "-" && value.last != "-"
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func port(_ text: String) -> UInt16? {
        guard text.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(text), port > 0 else { return nil }
        return port
    }
}

private enum PortForwardError: LocalizedError {
    case namespace, name, local, remote, launch
    var errorDescription: String? {
        switch self {
        case .namespace: return "Enter a valid Kubernetes namespace."
        case .name: return "Enter a valid pod or service name."
        case .local: return "Use a local port from 1 to 65535, or leave it blank for an available port."
        case .remote: return "Enter a remote port from 1 to 65535 or a Kubernetes port name."
        case .launch: return "Sightport could not start the Kubernetes client for port forwarding."
        }
    }
}

public enum PortForwardStatus: Equatable, Sendable {
    case listening(UInt16), stopped, failed(String)
}

public final class PortForwardSession: Sendable {
    private let worker: ForwardWorker

    init(executable: URL, arguments: [String], environment: [String: String],
         onStatus: @escaping @Sendable (PortForwardStatus) -> Void) throws {
        worker = try ForwardWorker(executable: executable, arguments: arguments, environment: environment, onStatus: onStatus)
    }

    public func stop() { worker.stop() }
    deinit { worker.stop() }
}

private final class ForwardWorker: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let queue = DispatchQueue(label: "app.sightport.mac.port-forward", qos: .utility)
    private let reader: DispatchSourceRead
    private let startupTimer: DispatchSourceTimer
    private let onStatus: @Sendable (PortForwardStatus) -> Void
    private let lock = NSLock()
    private var stopped = false

    // Output parsing and the one-shot startup deadline share the serial dispatch queue.
    private var pending = Data()
    private var listening = false
    private var problem: String?

    init(executable: URL, arguments: [String], environment: [String: String],
         onStatus: @escaping @Sendable (PortForwardStatus) -> Void) throws {
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { throw PortForwardError.launch }
        self.onStatus = onStatus
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        startupTimer = DispatchSource.makeTimerSource(queue: queue)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        reader.setEventHandler { [weak self] in self?.drain() }
        startupTimer.setEventHandler { [weak self] in
            guard let self, !self.listening else { return }
            self.problem = "Timed out waiting for the pod or service. Check the target and cluster connection."
            self.lock.withLock { self.terminateChild() }
        }
        process.terminationHandler = { [self] _ in queue.async { self.finish() } }
        reader.activate()
        startupTimer.schedule(deadline: .now() + 40)
        startupTimer.activate()
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            reader.cancel()
            startupTimer.cancel()
            throw PortForwardError.launch
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            terminateChild()
        }
    }

    private func terminateChild() {
        guard process.isRunning else { return }
        // Release the listening socket immediately, including when the app is terminating.
        let pid = process.processIdentifier
        _ = Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
    }

    private func drain() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let fd = pipe.fileHandleForReading.fileDescriptor
        // Bound the work per event so a noisy child cannot starve its startup deadline.
        for _ in 0..<32 {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { reader.cancel(); return }
            guard count > 0 else { return }
            pending.append(contentsOf: chunk.prefix(count))
            while let end = pending.firstIndex(of: 10) {
                consume(String(decoding: pending[..<end], as: UTF8.self))
                pending.removeSubrange(...end)
            }
            if pending.count > 8192 { pending.removeFirst(pending.count - 8192) }
        }
    }

    private func consume(_ line: String) {
        let prefix = "Forwarding from 127.0.0.1:"
        if !listening, line.hasPrefix(prefix) {
            let address = line.dropFirst(prefix.count)
            if let split = address.range(of: " -> "),
               let local = UInt16(address[..<split.lowerBound]), local > 0,
               let remote = UInt16(address[split.upperBound...]), remote > 0 {
                listening = true
                startupTimer.cancel()
                onStatus(.listening(local))
            }
        } else if let diagnostic = Self.diagnostic(for: line) {
            problem = diagnostic
        }
    }

    private func finish() {
        drain()
        if !pending.isEmpty { consume(String(decoding: pending, as: UTF8.self)) }
        reader.cancel()
        startupTimer.cancel()
        process.terminationHandler = nil
        if lock.withLock({ stopped }) { onStatus(.stopped) }
        else if let problem { onStatus(.failed(problem)) }
        else { onStatus(.failed(listening ? "The connection to the pod ended." : "Sightport could not establish the port forward.")) }
    }

    // Credential helpers can write to stderr. Publish only known failure categories.
    private static func diagnostic(for line: String) -> String? {
        let line = line.lowercased()
        if line.contains("address already in use") { return "This local port is already in use. Choose another port or leave it blank." }
        if line.contains("forbidden") { return "The cluster denied access to port forwarding for this target." }
        if line.contains("unauthorized") || line.contains("getting credentials") { return "Refresh your cluster credentials and try again." }
        if line == "selected pod changed" { return "The selected pod was replaced. Select the current pod and try again." }
        if line.contains("not found") || line.contains("notfound") { return "The namespace, target or remote port could not be found." }
        if line.contains("does not have") && line.contains("port") { return "The target does not expose that port." }
        if line.contains("without a selector") || line.contains("defined without a selector") { return "This service has no pod selector." }
        if line.contains("not running") || line.contains("timed out waiting") { return "The target has no running pod available." }
        return nil
    }
}
