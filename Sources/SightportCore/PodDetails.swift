import Foundation

public struct PodContainer: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case app, initContainer = "init", ephemeral }
    public enum State: String, Hashable, Sendable { case running, waiting, terminated, unknown }

    public let name: String
    public let role: Role
    public fileprivate(set) var state: State = .unknown
    public fileprivate(set) var ready = false
    public fileprivate(set) var reason: String?
    public fileprivate(set) var restartCount = 0
    public fileprivate(set) var exitCode: Int?
    fileprivate var restartable = false
    fileprivate var started = false
    fileprivate var countsTowardReadiness: Bool { role == .app || (role == .initContainer && restartable) }

    fileprivate var failure: String? {
        switch state {
        case .waiting:
            guard let reason, !["ContainerCreating", "PodInitializing"].contains(reason) else { return nil }
            return reason
        case .terminated:
            guard let exitCode, exitCode != 0 else { return nil }
            return reason ?? "ExitCode \(exitCode)"
        default: return nil
        }
    }
}

public struct PodDetails: Hashable, Sendable {
    public let containers: [PodContainer]
    public let controllerKind: String?
    public let controllerName: String?
    public let controllerUID: String?
    public let controllerResource: ResourceKind?
    public let node: String?
    public let qos: String?
    public let status: String
    public let isTerminating: Bool
    public let warning: String?
    public private(set) var podIPs: [String] = []
    public private(set) var serviceAccount: String?
    public private(set) var labels: [String: String] = [:]
    public private(set) var annotationKeys: [String] = []
    private(set) var resourceVersion: String?

    public var restartCount: Int { containers.reduce(0) { $0 + $1.restartCount } }
    public var readinessContainerCount: Int { containers.filter(\.countsTowardReadiness).count }
    public var readyCount: Int { containers.filter { $0.countsTowardReadiness && $0.ready }.count }

    // Separators are outside urlquery-escaped values. A reason containing a literal
    // pipe, comma, tab or newline therefore stays inside its own field.
    static let projection: String = {
        func scalar(_ path: String) -> String { "{{if ne \(path) nil}}{{urlquery \(path)}}{{end}}" }
        var output = ["pod", scalar(".status.qosClass"), scalar(".metadata.deletionTimestamp"), scalar(".status.reason")]
            .joined(separator: ",")
        output += "{{with .metadata.resourceVersion}}|version,{{urlquery .}}{{end}}"
        output += "{{with .status.podIP}}|ip,{{urlquery .}}{{end}}{{range .status.podIPs}}{{with .ip}}|ip,{{urlquery .}}{{end}}{{end}}"
        output += "{{with .spec.serviceAccountName}}|account,{{urlquery .}}{{end}}"
        output += "{{range $key, $value := .metadata.labels}}|label,{{urlquery $key}},{{urlquery $value}}{{end}}"
        output += "{{range $key, $value := .metadata.annotations}}|annotation,{{urlquery $key}}{{end}}"
        let ownerFields = [".apiVersion", ".kind", ".name", ".uid"].map(scalar).joined(separator: ",")
        output += "{{range .metadata.ownerReferences}}{{if .controller}}|owner," + ownerFields + "{{end}}{{end}}"
        output += #"{{range .status.conditions}}{{if and (eq .type "PodScheduled") (eq .status "False")}}|unscheduled,"#
            + scalar(".reason") + #"{{else if and (eq .type "Initialized") (eq .status "True")}}|initialized{{end}}{{end}}"#
        let groups = [("app", "containers", "containerStatuses"), ("init", "initContainers", "initContainerStatuses"),
                      ("ephemeral", "ephemeralContainers", "ephemeralContainerStatuses")]
        for (role, spec, _) in groups {
            output += "{{range .spec.\(spec)}}|spec,\(role)," + scalar(".name") + "," + scalar(".restartPolicy") + "{{end}}"
        }
        let state = "{{if ne .state.running nil}}running{{else if ne .state.waiting nil}}waiting"
            + "{{else if ne .state.terminated nil}}terminated{{else}}unknown{{end}}"
        let reason = "{{if ne .state.waiting nil}}" + scalar(".state.waiting.reason")
            + "{{else if ne .state.terminated nil}}" + scalar(".state.terminated.reason") + "{{end}}"
        for (role, _, status) in groups {
            let fields = ["|state", role, scalar(".name"), state, scalar(".ready"), scalar(".restartCount"),
                          reason, scalar(".state.terminated.exitCode"), scalar(".started")]
            output += "{{range .status.\(status)}}" + fields.joined(separator: ",") + "{{end}}"
        }
        return output
    }()

    init(projection: Substring, phase: String, ready: String, node: String) throws {
        var records = projection.split(separator: "|").makeIterator()
        guard let heading = try records.next()?.split(separator: ",", omittingEmptySubsequences: false).map(unescapeResourceField),
              heading.count == 4, heading[0] == "pod" else { throw ResourceReadError.invalidList }
        self.qos = heading[1].nonEmpty
        isTerminating = !heading[2].isEmpty
        self.node = node.nonEmpty
        var owner: (version: String, kind: String, name: String, uid: String)?
        var schedulingFailure: String?
        var initialized = false
        var orderedNames: [String] = []
        var byName: [String: PodContainer] = [:]
        while let record = records.next() {
            let parts = try record.split(separator: ",", omittingEmptySubsequences: false).map(unescapeResourceField)
            switch parts.first {
            case "version" where parts.count == 2:
                resourceVersion = parts[1].nonEmpty
            case "ip" where parts.count == 2 && !parts[1].isEmpty:
                if !podIPs.contains(parts[1]) { podIPs.append(parts[1]) }
            case "account" where parts.count == 2:
                serviceAccount = parts[1].nonEmpty
            case "label" where parts.count == 3 && !parts[1].isEmpty:
                labels[parts[1]] = parts[2]
            case "annotation" where parts.count == 2 && !parts[1].isEmpty:
                annotationKeys.append(parts[1])
            case "owner" where parts.count == 5:
                owner = (parts[1], parts[2], parts[3], parts[4])
            case "unscheduled" where parts.count == 2:
                schedulingFailure = parts[1].nonEmpty ?? "Unschedulable"
            case "initialized" where parts.count == 1:
                initialized = true
            case "spec" where parts.count == 4, "state" where parts.count == 9:
                let name = parts[2]
                guard !name.isEmpty, let role = PodContainer.Role(rawValue: parts[1]) else { throw ResourceReadError.invalidList }
                if byName[name] == nil {
                    byName[name] = PodContainer(name: name, role: role)
                    orderedNames.append(name)
                }
                if parts[0] == "spec" {
                    byName[name]?.restartable = parts[3] == "Always"
                } else {
                    guard let state = PodContainer.State(rawValue: parts[3]) else { throw ResourceReadError.invalidList }
                    byName[name]?.state = state
                    byName[name]?.ready = parts[4] == "true"
                    if !parts[5].isEmpty {
                        guard let restarts = Int32(parts[5]), restarts >= 0 else { throw ResourceReadError.invalidList }
                        byName[name]?.restartCount = Int(restarts)
                    }
                    byName[name]?.reason = parts[6].nonEmpty
                    byName[name]?.exitCode = Int(parts[7])
                    byName[name]?.started = parts[8] == "true"
                }
            default: throw ResourceReadError.invalidList
            }
        }
        containers = orderedNames.compactMap { byName[$0] }
        controllerKind = owner?.kind.nonEmpty
        controllerName = owner?.name.nonEmpty
        controllerUID = owner?.uid.nonEmpty
        controllerResource = owner.flatMap { owner in
            guard !owner.version.isEmpty, let kind = ResourceKind(controllerKind: owner.kind) else { return nil }
            let group = owner.version.split(separator: "/").dropLast().joined(separator: "/")
            let builtInGroup = kind.resourceName.split(separator: ".").dropFirst().joined(separator: ".")
            guard group == builtInGroup || (group == "extensions" && builtInGroup == "apps") else { return nil }
            return kind
        }
        (status, warning) = Self.health(phase: phase, ready: ready, reason: heading[3].nonEmpty,
                                        deleting: isTerminating, schedulingFailure: schedulingFailure,
                                        initialized: initialized, containers: containers)
    }

    private static func health(phase: String, ready: String, reason: String?, deleting: Bool,
                               schedulingFailure: String?, initialized: Bool, containers: [PodContainer]) -> (String, String?) {
        if deleting {
            return reason == "NodeLost" ? ("Unknown", "The node was lost while the pod was terminating.") : ("Terminating", nil)
        }
        if phase == "Succeeded" { return ("Succeeded", nil) }
        if phase == "Failed" || phase == "Unknown" {
            return (reason ?? phase, reason ?? (phase == "Failed" ? "The pod failed." : "Pod status is unknown."))
        }
        if let schedulingFailure { return (phase.nonEmpty ?? "Pending", schedulingFailure) }

        let initializers = initialized ? [] : containers.filter { $0.role == .initContainer }
        for (index, container) in initializers.enumerated() {
            if container.restartable && container.started { continue }
            if container.state == .terminated && container.exitCode == 0 { continue }
            if let failure = container.failure { return ("Init:" + failure, "\(container.name) · \(failure)") }
            return ("Init:\(index)/\(initializers.count)", nil)
        }

        let workload = containers.filter(\.countsTowardReadiness)
        if let container = workload.first(where: { $0.failure != nil }), let failure = container.failure {
            return (failure, "\(container.name) · \(failure)")
        }
        if let waiting = workload.first(where: { $0.state == .waiting }), let reason = waiting.reason {
            return (reason, nil)
        }
        if phase == "Running" && ready == "False" { return ("Running", "The pod’s Ready condition is false.") }
        return (reason ?? phase.nonEmpty ?? "Unknown", nil)
    }
}

public extension ResourceKind {
    init?(controllerKind: String) {
        switch controllerKind {
        case "Node": self = .nodes
        case "ReplicaSet": self = .replicaSets
        case "StatefulSet": self = .statefulSets
        case "DaemonSet": self = .daemonSets
        case "Job": self = .jobs
        case "ReplicationController": self = .replicationControllers
        case "Deployment": self = .deployments
        case "CronJob": self = .cronJobs
        default: return nil
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
