import Foundation

public enum InspectableResource: String, Sendable {
    case node = "nodes"
    case pod = "pods"
    case serviceAccount = "serviceaccounts"
}

public struct NodeDetails: Decodable, Sendable {
    public struct SystemInfo: Decodable, Sendable {
        public let kubeletVersion, osImage, architecture, kernelVersion, containerRuntimeVersion: String?
    }
    public struct Address: Decodable, Sendable {
        public let type, address: String
    }
    public struct Condition: Decodable, Sendable {
        public let type, status: String
        public let reason, message: String?
    }
    public struct Taint: Decodable, Sendable {
        public let key, effect: String
        public let value: String?
    }

    public let unschedulable: Bool
    public let system: SystemInfo
    public let addresses: [Address]?
    public let conditions: [Condition]?
    public let capacity, allocatable, labels: [String: String]?
    public let taints: [Taint]?
}

public enum NodeOperation: String, Identifiable, Sendable {
    case drain = "drain-node"
    case delete = "delete-node"
    public var id: Self { self }
}

enum InspectionFailure: String {
    case invalid = "resource-invalid-selection"
    case changed = "resource-selection-changed"
    case unmanaged = "node-drain-unmanaged-pod"
    case localData = "node-drain-local-data"
    case scheduling = "node-drain-scheduling-enabled"
    case eviction = "node-drain-eviction-unavailable"
    case budget = "node-drain-budget-timeout"
    case readDenied, mutationDenied, drainIncomplete, deleteUnconfirmed, readUnavailable

    var description: String {
        switch self {
        case .invalid: return "Select a resource with a valid name and UID."
        case .changed: return "The selected resource changed or was removed. Refresh and select it again."
        case .unmanaged: return "Drain stopped because a pod has no managing controller. Check the pods on this node before retrying."
        case .localData: return "Drain stopped because a pod uses emptyDir storage. Migrate the workload and its local data before retrying."
        case .scheduling: return "Drain stopped because scheduling was enabled again on this node."
        case .eviction: return "The cluster does not serve the required policy/v1 pod eviction API."
        case .budget: return "Drain timed out waiting for evictions. Check PodDisruptionBudgets and available capacity. The node remains cordoned."
        case .readDenied: return "This context does not have permission to read the selected resource."
        case .mutationDenied: return "Kubernetes denied the operation. Check this context’s permissions and the node’s current state."
        case .drainIncomplete: return "Drain did not complete. Check the node’s scheduling status, remaining pods, and disruption budgets before retrying."
        case .deleteUnconfirmed: return "Could not confirm whether deletion was accepted. Refresh the Nodes list before retrying."
        case .readUnavailable: return "Could not read this resource from the selected cluster."
        }
    }
}

extension KubernetesClient {
    public func manifest(for kind: InspectableResource, row: ResourceRow, context: ContextID) async throws -> String {
        guard kind == .pod || kind == .node else { throw KubernetesError.inspection(.invalid) }
        let data = try await inspection(kind, row: row, context: context, format: "yaml")
        guard let yaml = String(data: data, encoding: .utf8), !yaml.isEmpty else {
            throw KubernetesError.inspection(.readUnavailable)
        }
        return yaml
    }

    public func nodeDetails(_ row: ResourceRow, context: ContextID) async throws -> NodeDetails {
        let data = try await inspection(.node, row: row, context: context, format: "details")
        guard let details = try? JSONDecoder().decode(NodeDetails.self, from: data) else {
            throw KubernetesError.inspection(.readUnavailable)
        }
        return details
    }

    public func serviceAccountAnnotations(_ row: ResourceRow, context: ContextID) async throws -> [String: String] {
        let data = try await inspection(.serviceAccount, row: row, context: context, format: "details")
        guard let annotations = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw KubernetesError.inspection(.readUnavailable)
        }
        return annotations
    }

    private func inspection(_ kind: InspectableResource, row: ResourceRow, context: ContextID, format: String) async throws -> Data {
        var args = ["--context=" + context.name, "--request-timeout=8s", "inspect-resource",
                    kind.rawValue + "/" + row.name, "--uid=" + row.id, "-o", format]
        if kind == .node {
            try validateNode(row, context: context)
        } else {
            let namespace = try selectedNamespace(for: row, context: context.name, missing: .inspection(.invalid))
            args.append("--namespace=" + namespace)
        }
        return try await run(args, file: context.file, operation: .inspection(nil))
    }

    public func perform(_ operation: NodeOperation, on row: ResourceRow, context: ContextID) async throws {
        try validateNode(row, context: context)
        let duration = operation == .drain ? "5m" : "8s"
        let args = ["--context=" + context.name, "--request-timeout=" + duration, operation.rawValue, row.name, "--uid=" + row.id]
        do {
            _ = try await run(args, file: context.file, operation: .inspection(operation),
                              commandTimeout: operation == .drain ? 310 : nil)
        } catch KubernetesError.timeout {
            throw KubernetesError.inspection(operation == .drain ? .drainIncomplete : .deleteUnconfirmed)
        }
    }

    private func validateNode(_ row: ResourceRow, context: ContextID) throws {
        guard !context.name.isEmpty, !context.name.utf8.contains(0) else { throw KubernetesError.missingContext }
        guard row.namespace == nil, [row.name, row.id].allSatisfy({
            !$0.isEmpty && !$0.contains("/") && !$0.utf8.contains(0)
        }) else { throw KubernetesError.inspection(.invalid) }
    }
}
