import Foundation

public enum ResourceKind: String, CaseIterable, Hashable, Sendable {
    case namespaces, nodes, pods, deployments, daemonSets, statefulSets, replicaSets, replicationControllers
    case jobs, cronJobs, configMaps, secrets, resourceQuotas, limitRanges, horizontalPodAutoscalers
    case podDisruptionBudgets, priorityClasses, runtimeClasses, leases
    case argoApplications, argoApplicationSets, argoProjects, argoRepositories, argoClusters
    case nodePools, nodeClaims, ec2NodeClasses
    case services, endpointSlices, endpoints, ingresses, ingressClasses, networkPolicies
    case gatewayClasses, gateways, httpRoutes, grpcRoutes, tlsRoutes, tcpRoutes, udpRoutes, referenceGrants, backendTLSPolicies
    case persistentVolumeClaims, persistentVolumes, storageClasses, events
    case serviceAccounts, clusterRoles, roles, clusterRoleBindings, roleBindings, customResourceDefinitions

    public static let workloads: [Self] = [.pods, .deployments, .daemonSets, .statefulSets, .replicaSets,
                                           .replicationControllers, .jobs, .cronJobs]
    public static let configuration: [Self] = [.configMaps, .secrets, .resourceQuotas, .limitRanges,
                                               .horizontalPodAutoscalers, .podDisruptionBudgets,
                                               .priorityClasses, .runtimeClasses, .leases]
    public static let argoResources: [Self] = [.argoApplications, .argoApplicationSets, .argoProjects]
    public static let argoSettings: [Self] = [.argoRepositories, .argoClusters]
    public static let karpenter: [Self] = [.nodePools, .nodeClaims, .ec2NodeClasses]

    public static let network: [Self] = [.services, .endpointSlices, .endpoints, .ingresses, .ingressClasses, .networkPolicies]
    public static let gatewayAPI: [Self] = [.gatewayClasses, .gateways, .httpRoutes, .grpcRoutes, .tlsRoutes,
                                           .tcpRoutes, .udpRoutes, .referenceGrants, .backendTLSPolicies]
    public static let storage: [Self] = [.persistentVolumeClaims, .persistentVolumes, .storageClasses]
    public static let accessControl: [Self] = [.serviceAccounts, .clusterRoles, .roles, .clusterRoleBindings, .roleBindings]

    public var title: String {
        switch self {
        case .namespaces: return "Namespaces"
        case .nodes: return "Nodes"
        case .pods: return "Pods"
        case .deployments: return "Deployments"
        case .daemonSets: return "Daemon Sets"
        case .statefulSets: return "Stateful Sets"
        case .replicaSets: return "Replica Sets"
        case .replicationControllers: return "Replication Controllers"
        case .jobs: return "Jobs"
        case .cronJobs: return "Cron Jobs"
        case .configMaps: return "Config Maps"
        case .secrets: return "Secrets"
        case .resourceQuotas: return "Resource Quotas"
        case .limitRanges: return "Limit Ranges"
        case .horizontalPodAutoscalers: return "Horizontal Pod Autoscalers"
        case .podDisruptionBudgets: return "Pod Disruption Budgets"
        case .priorityClasses: return "Priority Classes"
        case .runtimeClasses: return "Runtime Classes"
        case .leases: return "Leases"
        case .argoApplications: return "Applications"
        case .argoApplicationSets: return "Application Sets"
        case .argoProjects: return "Projects"
        case .argoRepositories: return "Repositories"
        case .argoClusters: return "Clusters"
        case .nodePools: return "Node Pools"
        case .nodeClaims: return "Node Claims"
        case .ec2NodeClasses: return "EC2 Node Classes"
        case .services: return "Services"
        case .endpointSlices: return "Endpoint Slices"
        case .endpoints: return "Endpoints"
        case .ingresses: return "Ingresses"
        case .ingressClasses: return "Ingress Classes"
        case .networkPolicies: return "Network Policies"
        case .gatewayClasses: return "Gateway Classes"
        case .gateways: return "Gateways"
        case .httpRoutes: return "HTTP Routes"
        case .grpcRoutes: return "GRPC Routes"
        case .tlsRoutes: return "TLS Routes"
        case .tcpRoutes: return "TCP Routes"
        case .udpRoutes: return "UDP Routes"
        case .referenceGrants: return "Reference Grants"
        case .backendTLSPolicies: return "Backend TLS Policies"
        case .persistentVolumeClaims: return "Persistent Volume Claims"
        case .persistentVolumes: return "Persistent Volumes"
        case .storageClasses: return "Storage Classes"
        case .events: return "Events"
        case .serviceAccounts: return "Service Accounts"
        case .clusterRoles: return "Cluster Roles"
        case .roles: return "Roles"
        case .clusterRoleBindings: return "Cluster Role Bindings"
        case .roleBindings: return "Role Bindings"
        case .customResourceDefinitions: return "Custom Resource Definitions"
        }
    }

    public var isNamespaced: Bool {
        switch self {
        case .namespaces, .nodes, .priorityClasses, .runtimeClasses, .nodePools, .nodeClaims, .ec2NodeClasses,
             .ingressClasses, .gatewayClasses, .persistentVolumes, .storageClasses,
             .clusterRoles, .clusterRoleBindings, .customResourceDefinitions:
            return false
        default: return true
        }
    }

    var resourceName: String {
        let plural = rawValue.lowercased()
        switch self {
        case .deployments, .daemonSets, .statefulSets, .replicaSets: return plural + ".apps"
        case .jobs, .cronJobs: return plural + ".batch"
        case .horizontalPodAutoscalers: return plural + ".autoscaling"
        case .podDisruptionBudgets: return plural + ".policy"
        case .priorityClasses: return plural + ".scheduling.k8s.io"
        case .runtimeClasses: return plural + ".node.k8s.io"
        case .leases: return plural + ".coordination.k8s.io"
        case .argoApplications: return "applications.argoproj.io"
        case .argoApplicationSets: return "applicationsets.argoproj.io"
        case .argoProjects: return "appprojects.argoproj.io"
        case .argoRepositories, .argoClusters: return "secrets"
        case .nodePools, .nodeClaims: return plural + ".karpenter.sh"
        case .ec2NodeClasses: return plural + ".karpenter.k8s.aws"
        case .endpointSlices: return plural + ".discovery.k8s.io"
        case .ingresses, .ingressClasses, .networkPolicies: return plural + ".networking.k8s.io"
        case .gatewayClasses, .gateways, .httpRoutes, .grpcRoutes, .tlsRoutes, .tcpRoutes, .udpRoutes,
             .referenceGrants, .backendTLSPolicies: return plural + ".gateway.networking.k8s.io"
        case .storageClasses: return plural + ".storage.k8s.io"
        case .events: return "events.events.k8s.io"
        case .roles, .clusterRoles, .roleBindings, .clusterRoleBindings: return plural + ".rbac.authorization.k8s.io"
        case .customResourceDefinitions: return plural + ".apiextensions.k8s.io"
        default: return plural
        }
    }

    private static let columnsByKind = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.fields.map(\.name)) })
    public var columns: [String] { Self.columnsByKind[self]! }

    private var fields: [ResourceField] {
        let ready = ResourceField(name: "Ready", template: #"{{range .status.conditions}}{{if eq .type "Ready"}}{{urlquery .status}}{{end}}{{end}}"#)
        switch self {
        case .namespaces: return [.value("Status", ".status.phase")]
        case .nodes: return [ready, .value("Kubelet", ".status.nodeInfo.kubeletVersion"), .value("OS", ".status.nodeInfo.osImage")]
        case .pods: return [.value("Phase", ".status.phase"), ready, .value("Node", ".spec.nodeName")]
        case .deployments, .statefulSets, .replicaSets, .replicationControllers:
            return [.number("Ready", ".status.readyReplicas"), .number("Desired", ".spec.replicas"),
                    .number("Current", ".status.replicas")]
        case .daemonSets:
            return [.number("Ready", ".status.numberReady"), .number("Desired", ".status.desiredNumberScheduled"),
                    .number("Current", ".status.currentNumberScheduled")]
        case .jobs: return [.number("Active", ".status.active"), .number("Succeeded", ".status.succeeded"), .number("Failed", ".status.failed")]
        case .cronJobs: return [.value("Schedule", ".spec.schedule"), .value("Suspended", ".spec.suspend", fallback: "false"),
                                .value("Last scheduled", ".status.lastScheduleTime")]
        case .configMaps: return [.count("Text keys", ".data"), .count("Binary keys", ".binaryData")]
        case .secrets: return [.value("Type", ".type"), .count("Keys", ".data")]
        case .resourceQuotas: return [.quantities("Hard limits", ".spec.hard"), .quantities("Used", ".status.used")]
        case .limitRanges: return [ResourceField(name: "Limit types", template: """
            {{range $i, $limit := .spec.limits}}{{if $i}}, {{end}}{{urlquery $limit.type}}{{end}}
            """)]
        case .horizontalPodAutoscalers:
            return [.value("Target", ".spec.scaleTargetRef.name"), .number("Current", ".status.currentReplicas"),
                    .number("Desired", ".status.desiredReplicas")]
        case .podDisruptionBudgets: return [.number("Allowed disruptions", ".status.disruptionsAllowed"),
                                            .number("Healthy", ".status.currentHealthy"), .number("Desired", ".status.desiredHealthy")]
        case .priorityClasses: return [.number("Value", ".value"), .value("Global default", ".globalDefault", fallback: "false"),
                                       .value("Preemption", ".preemptionPolicy")]
        case .runtimeClasses: return [.value("Handler", ".handler")]
        case .leases: return [.value("Holder", ".spec.holderIdentity"), .value("Duration (s)", ".spec.leaseDurationSeconds"),
                              .value("Renewed", ".spec.renewTime")]
        case .argoApplications: return ArgoFields.applications
        case .argoApplicationSets: return ArgoFields.applicationSets
        case .argoProjects: return ArgoFields.projects
        case .argoRepositories: return ArgoFields.repositories
        case .argoClusters: return ArgoFields.clusters
        case .nodePools: return KarpenterFields.nodePools
        case .nodeClaims: return KarpenterFields.nodeClaims
        case .ec2NodeClasses: return KarpenterFields.ec2NodeClasses
        case .services: return NetworkFields.services
        case .endpointSlices: return NetworkFields.endpointSlices
        case .endpoints: return NetworkFields.endpoints
        case .ingresses: return NetworkFields.ingresses
        case .ingressClasses: return NetworkFields.ingressClasses
        case .networkPolicies: return NetworkFields.networkPolicies
        case .gatewayClasses: return NetworkFields.gatewayClasses
        case .gateways: return NetworkFields.gateways
        case .httpRoutes, .grpcRoutes, .tlsRoutes: return NetworkFields.hostRoutes
        case .tcpRoutes, .udpRoutes: return NetworkFields.routes
        case .referenceGrants: return NetworkFields.referenceGrants
        case .backendTLSPolicies: return NetworkFields.backendTLSPolicies
        case .persistentVolumeClaims: return ClusterFields.persistentVolumeClaims
        case .persistentVolumes: return ClusterFields.persistentVolumes
        case .storageClasses: return ClusterFields.storageClasses
        case .events: return ClusterFields.events
        case .serviceAccounts: return ClusterFields.serviceAccounts
        case .roles: return ClusterFields.roles
        case .clusterRoles: return ClusterFields.clusterRoles
        case .roleBindings, .clusterRoleBindings: return ClusterFields.roleBindings
        case .customResourceDefinitions: return ClusterFields.customResourceDefinitions
        }
    }

    // The SDK emits only these columns. Escaping each field also keeps literal newlines,
    // tabs, percent signs, and plus signs in a Lease or CronJob from changing the row layout.
    var listTemplate: String { "{{range .items}}" + rowTemplate + #"{{"\n"}}{{end}}"# }

    var includesResourceVersion: Bool { self == .configMaps || self == .secrets }

    var rowTemplate: String {
        let metadata = [".metadata.uid", ".metadata.name", ".metadata.namespace", ".metadata.creationTimestamp"]
            .map { ResourceField.value("", $0).template }
        var cells = metadata + fields.map(\.template)
        if self == .pods { cells.append(PodDetails.projection) }
        if includesResourceVersion { cells.append(ResourceField.value("", ".metadata.resourceVersion").template) }
        return cells.joined(separator: #"{{"\t"}}"#)
    }
}

struct ResourceField {
    let name: String
    let template: String

    static func value(_ name: String, _ path: String, fallback: String = "") -> Self {
        Self(name: name, template: "{{if ne \(path) nil}}{{urlquery \(path)}}{{else}}\(fallback){{end}}")
    }

    static func number(_ name: String, _ path: String) -> Self { value(name, path, fallback: "0") }

    static func count(_ name: String, _ path: String) -> Self {
        Self(name: name, template: "{{with \(path)}}{{len .}}{{else}}0{{end}}")
    }

    static func quantities(_ name: String, _ path: String) -> Self {
        Self(name: name, template: "{{range $key, $value := \(path)}}{{urlquery $key}}={{urlquery $value}} {{end}}")
    }
}

public struct ResourceRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let namespace: String?
    public let createdAt: Date?
    public let values: [String]
    public let pod: PodDetails?
    public let resourceVersion: String?

    public init(id: String, name: String, namespace: String?, createdAt: Date?, values: [String], pod: PodDetails? = nil,
                resourceVersion: String? = nil) {
        self.id = id
        self.name = name
        self.namespace = namespace
        self.createdAt = createdAt
        self.values = values
        self.pod = pod
        self.resourceVersion = resourceVersion
    }

    static func decodeList(_ data: Data, kind: ResourceKind) throws -> [Self] {
        guard let text = String(data: data, encoding: .utf8) else { throw ResourceReadError.invalidList }
        let columnCount = kind.columns.count
        return try text.split(separator: "\n").map {
            try decodeRow($0, separator: "\t", columnCount: columnCount, kind: kind)
        }
    }

    static func decodeRow(_ line: Substring, separator: Character, columnCount: Int, kind: ResourceKind?) throws -> Self {
        let baseCount = 4 + columnCount
        let includesPod = kind == .pods
        let cells = line.split(separator: separator, omittingEmptySubsequences: false)
        let hasVersion = kind?.includesResourceVersion == true
        guard cells.count == baseCount + ((includesPod || hasVersion) ? 1 : 0) else { throw ResourceReadError.invalidList }
        let fields = try cells.prefix(baseCount).map(unescapeResourceField)
        guard !fields[1].isEmpty else { throw ResourceReadError.invalidList }
        let uid = fields[0], name = fields[1], namespace = fields[2], timestamp = fields[3]
        let rawValues = Array(fields.dropFirst(4))
        let values = kind.map { ArgoFields.displayValues(rawValues, for: $0) } ?? rawValues
        let pod = includesPod ? try PodDetails(projection: cells[baseCount], phase: values[0],
                                              ready: values[1], node: values[2]) : nil
        return ResourceRow(id: uid.isEmpty ? namespace + "/" + name : uid, name: name,
                           namespace: namespace.isEmpty ? nil : namespace,
                           createdAt: try? Date.ISO8601FormatStyle(includingFractionalSeconds: timestamp.contains(".")).parse(timestamp),
                           values: values, pod: pod,
                           resourceVersion: hasVersion && !cells[baseCount].isEmpty ? try unescapeResourceField(cells[baseCount]) : pod?.resourceVersion)
    }
}

func unescapeResourceField(_ escaped: Substring) throws -> String {
    let hasSpace = escaped.utf8.contains(43)
    if !hasSpace && !escaped.utf8.contains(37) { return String(escaped) }
    let normalized = hasSpace ? escaped.replacingOccurrences(of: "+", with: " ") : String(escaped)
    guard let value = normalized.removingPercentEncoding else {
        throw ResourceReadError.invalidList
    }
    return value
}

enum ResourceReadError: LocalizedError {
    case invalidList, invalidWatch, emptyNamespace

    var errorDescription: String? {
        switch self {
        case .invalidWatch: return "The resource watch was interrupted."
        case .invalidList: return "Sightport could not read the resource list."
        case .emptyNamespace: return "Choose a namespace or select All namespaces."
        }
    }
}
