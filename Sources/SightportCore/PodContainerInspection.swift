import Foundation

public struct PodContainerInspection: Sendable {
    public enum Section: Equatable, Sendable {
        case image, imageDetails, runtime, configuration, environment
    }

    public struct Field: Equatable, Sendable {
        public let name: String
        public let value: String
        public let section: Section
    }

    public let properties: [Field]
    public let environment: [Field]
    public let environmentFrom: [String]

    fileprivate init(spec: ContainerSpec?, status: ContainerStatus?) {
        var fields = [Field]()
        func add(_ section: Section, _ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(Field(name: name, value: value, section: section))
        }
        if let image = spec?.image, !image.isEmpty {
            add(.image, "Image", image)
            let version = Self.imageVersion(image)
            add(.imageDetails, "Image tag", version.tag)
            add(.imageDetails, "Image digest", version.digest)
        }
        if status?.image != spec?.image {
            add(spec?.image?.isEmpty == false ? .imageDetails : .image, "Runtime image", status?.image)
        }
        add(.imageDetails, "Image ID", status?.imageID)
        add(.imageDetails, "Container ID", status?.containerID)
        add(.imageDetails, "Image pull policy", spec?.imagePullPolicy)
        add(.configuration, "Command", spec?.command?.joined(separator: "\n"))
        add(.configuration, "Arguments", spec?.args?.joined(separator: "\n"))
        add(.configuration, "Working directory", spec?.workingDir)
        if let ports = spec?.ports {
            add(.configuration, "Ports", ports.map { port in
                let name = port.name.map { $0 + " " } ?? ""
                return name + String(port.containerPort) + "/" + (port.protocol ?? "TCP")
            }.joined(separator: "\n"))
        }
        func quantities(_ values: [String: String]?) -> String? {
            values?.sorted { $0.key < $1.key }.map { $0.key + " " + $0.value }.joined(separator: "\n")
        }
        add(.configuration, "Requests", quantities(spec?.resources?.requests))
        add(.configuration, "Limits", quantities(spec?.resources?.limits))
        add(.runtime, "Started", status?.state?.running?.startedAt)
        add(.runtime, "Waiting reason", status?.state?.waiting?.reason)
        add(.runtime, "Waiting message", status?.state?.waiting?.message)
        func addTermination(_ name: String, _ state: ContainerStatus.Termination?) {
            guard let state else { return }
            var summary = [state.reason, state.exitCode.map { "exit " + String($0) },
                           state.signal.flatMap { $0 == 0 ? nil : "signal " + String($0) }].compactMap { $0 }
            if let finished = state.finishedAt { summary.append(finished) }
            add(.runtime, name, summary.joined(separator: " · "))
            add(.runtime, name + " message", state.message)
        }
        addTermination("Termination", status?.state?.terminated)
        addTermination("Last termination", status?.lastState?.terminated)
        properties = fields
        environment = (spec?.env ?? []).map { field in
            Field(name: field.name, value: field.valueFrom?.description ?? (field.value ?? ""), section: .environment)
        }
        environmentFrom = (spec?.envFrom ?? []).map(\.description)
    }

    static func imageVersion(_ image: String) -> (tag: String?, digest: String?) {
        if image.hasPrefix("sha256:"), image.utf8.count == 71,
           image.dropFirst(7).allSatisfy(\.isHexDigit) {
            return (nil, image)
        }
        let parts = image.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let digest = parts.count == 2 ? String(parts[1]) : nil
        // A registry port occurs before the last slash. Only the final component can have a tag.
        let component = parts[0].split(separator: "/").last ?? ""
        if let colon = component.lastIndex(of: ":") {
            return (String(component[component.index(after: colon)...]), digest)
        }
        return (digest == nil ? "latest (implicit)" : nil, digest)
    }
}

public struct PodInspection: Sendable {
    public let containers: [String: PodContainerInspection]

    init(data: Data, row: ResourceRow) throws {
        let pod: PodDocument
        do { pod = try JSONDecoder().decode(PodDocument.self, from: data) }
        catch { throw KubernetesError.podInspectionUnavailable }
        guard pod.metadata.uid == row.id, pod.metadata.name == row.name, pod.metadata.namespace == row.namespace else {
            throw KubernetesError.logTargetMissing
        }
        var byName = [String: PodContainerInspection]()
        func collect(_ specs: [ContainerSpec]?, _ states: [ContainerStatus]?) {
            let statuses = Dictionary((states ?? []).map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
            for spec in specs ?? [] { byName[spec.name] = PodContainerInspection(spec: spec, status: statuses[spec.name]) }
            for (name, state) in statuses where byName[name] == nil {
                byName[name] = PodContainerInspection(spec: nil, status: state)
            }
        }
        collect(pod.spec.containers, pod.status?.containerStatuses)
        collect(pod.spec.initContainers, pod.status?.initContainerStatuses)
        collect(pod.spec.ephemeralContainers, pod.status?.ephemeralContainerStatuses)
        containers = byName
    }
}

private struct PodDocument: Decodable {
    struct Metadata: Decodable { let uid, name, namespace: String }
    struct Spec: Decodable { let containers, initContainers, ephemeralContainers: [ContainerSpec]? }
    struct Status: Decodable { let containerStatuses, initContainerStatuses, ephemeralContainerStatuses: [ContainerStatus]? }
    let metadata: Metadata
    let spec: Spec
    let status: Status?
}

private struct ContainerStatus: Decodable {
    struct Running: Decodable { let startedAt: String? }
    struct Waiting: Decodable { let reason, message: String? }
    struct Termination: Decodable {
        let reason, message, finishedAt: String?
        let exitCode, signal: Int?
    }
    struct State: Decodable {
        let waiting: Waiting?
        let running: Running?
        let terminated: Termination?
    }
    let name: String
    let image, imageID, containerID: String?
    let state, lastState: State?
}

private struct ContainerSpec: Decodable {
    struct Port: Decodable { let name: String?; let containerPort: Int; let `protocol`: String? }
    struct Resources: Decodable { let requests, limits: [String: String]? }
    let name: String
    let image, imagePullPolicy, workingDir: String?
    let command, args: [String]?
    let ports: [Port]?
    let resources: Resources?
    let env: [EnvironmentVariable]?
    let envFrom: [EnvironmentImport]?
}

private struct EnvironmentObjectReference: Decodable {
    let name: String
    let key: String?
    let optional: Bool?

    func description(kind: String) -> String {
        let keyPart = key.map { " · key " + $0 } ?? ""
        return kind + " " + name + keyPart + (optional == true ? " (optional)" : "")
    }
}

private struct EnvironmentVariable: Decodable {
    struct Source: Decodable {
        struct FieldReference: Decodable { let fieldPath: String }
        struct ResourceReference: Decodable { let resource: String; let containerName, divisor: String? }
        struct FileReference: Decodable { let volumeName, path, key: String; let optional: Bool? }
        let secretKeyRef, configMapKeyRef: EnvironmentObjectReference?
        let fieldRef: FieldReference?
        let resourceFieldRef: ResourceReference?
        let fileKeyRef: FileReference?

        var description: String {
            if let secretKeyRef { return secretKeyRef.description(kind: "Secret") }
            if let configMapKeyRef { return configMapKeyRef.description(kind: "ConfigMap") }
            if let fieldRef { return "Pod field " + fieldRef.fieldPath }
            if let ref = resourceFieldRef {
                return "Container resource " + ref.resource + (ref.containerName.map { " · " + $0 } ?? "")
                    + (ref.divisor.map { " · divisor " + $0 } ?? "")
            }
            if let ref = fileKeyRef {
                return "Volume " + ref.volumeName + "/" + ref.path + " · key " + ref.key + (ref.optional == true ? " (optional)" : "")
            }
            return "Environment reference"
        }
    }

    let name: String
    let value: String?
    let valueFrom: Source?
}

private struct EnvironmentImport: Decodable {
    let prefix: String?
    let secretRef, configMapRef: EnvironmentObjectReference?

    var description: String {
        let source = secretRef?.description(kind: "Secret") ?? configMapRef?.description(kind: "ConfigMap") ?? "Environment reference"
        guard let prefix, !prefix.isEmpty else { return source }
        return source + " · prefix " + prefix
    }
}

extension KubernetesClient {
    public func inspectPod(for row: ResourceRow, in file: URL, context: String) async throws -> PodInspection {
        let namespace = try selectedNamespace(for: row, context: context, missing: .podIdentityMissing)
        // Both path components must be Kubernetes object names. This also rejects dot segments.
        for segment in [namespace, row.name] {
            guard segment.range(of: #"^[a-z0-9](?:[-.a-z0-9]*[a-z0-9])?\z"#, options: .regularExpression) != nil else {
                throw KubernetesError.podIdentityMissing
            }
        }
        let path = "/api/v1/namespaces/" + namespace + "/pods/" + row.name
        let args = ["--context=" + context, "--request-timeout=8s", "get", "--raw=" + path]
        let data = try await run(args, file: file, operation: .podInspection)
        return try PodInspection(data: data, row: row)
    }
}
