import Foundation

public enum WorkloadAction: Hashable, Sendable {
    case restart, startJob, resumeJob, rerunJob

    public init?(kind: ResourceKind, row: ResourceRow? = nil) {
        switch kind {
        case .deployments, .daemonSets, .statefulSets: self = .restart
        case .cronJobs: self = .startJob
        case .jobs:
            if let row, let index = kind.columns.firstIndex(of: "Suspended"),
               row.values.indices.contains(index), row.values[index] == "true" {
                self = .resumeJob
            } else {
                self = .rerunJob
            }
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .restart: return "Restart Rollout"
        case .startJob, .resumeJob: return "Start Job"
        case .rerunJob: return "Run Again"
        }
    }

    public func confirmation(for row: ResourceRow, context: String) -> String {
        let target = [row.namespace, row.name].compactMap { $0 }.joined(separator: "/")
        switch self {
        case .restart:
            return "Restart \(target) in context \(context)? Kubernetes will update its pod template and follow the workload’s configured update strategy."
        case .startJob:
            return "Start a one-off Job from CronJob \(target) in context \(context)? It can run alongside scheduled Jobs."
        case .resumeJob:
            return "Start suspended Job \(target) in context \(context)? Kubernetes will resume this Job and schedule its pods."
        case .rerunJob:
            return "Create a new Job from \(target) in context \(context)? It will use the same pod template and can run alongside the original."
        }
    }
}

enum WorkloadFailure: String {
    case invalid = "workload-invalid-target"
    case changed = "workload-changed"
    case paused = "workload-paused"
    case manualSelector = "workload-manual-selector"
    case rejected = "workload-rejected"
    case unconfirmed = "workload-unconfirmed"
    case forbidden, missing

    var description: String {
        switch self {
        case .invalid: return "Select a workload with a namespace, name, and UID."
        case .changed: return "The selected workload changed. Check its current configuration before trying again."
        case .paused: return "This Deployment is paused. Resume it before requesting a restart."
        case .manualSelector: return "This template uses a manual pod selector. A new Job needs a distinct selector to avoid taking over existing pods."
        case .rejected: return "The API server rejected the workload change. Check the workload’s manifest and cluster policies."
        case .forbidden: return "This context lacks permission to perform the requested workload action."
        case .missing: return "The selected workload or namespace no longer exists."
        case .unconfirmed: return "Sightport could not confirm the request. Check the workload and Jobs in this namespace before trying again."
        }
    }
}

extension KubernetesClient {
    public func performWorkloadAction(_ action: WorkloadAction, kind: ResourceKind, row: ResourceRow,
                                      in file: URL, context: String) async throws -> String {
        guard action == WorkloadAction(kind: kind, row: row) else { throw KubernetesError.workloadAction(.invalid) }
        let namespace = try selectedNamespace(for: row, context: context, missing: .workloadAction(.invalid))
        let verb: String
        switch action {
        case .restart: verb = "restart-workload"
        case .resumeJob: verb = "resume-job"
        case .startJob, .rerunJob: verb = "start-job"
        }
        let args = ["--context=" + context, "--request-timeout=8s", verb, kind.rawValue.lowercased(), row.name,
                    "--namespace=" + namespace, "--uid=" + row.id]
        let data: Data
        do {
            data = try await run(args, file: file, operation: .workloadAction)
        } catch KubernetesError.timeout {
            throw KubernetesError.workloadAction(.unconfirmed)
        }
        let response = String(decoding: data, as: UTF8.self)
        if action == .restart {
            if response == "OnDelete" {
                return "Updated the pod template for \(namespace)/\(row.name). Its OnDelete strategy replaces pods when they are deleted individually."
            }
            guard response.isEmpty else { throw KubernetesError.workloadAction(.unconfirmed) }
            return "Restart requested for \(namespace)/\(row.name)."
        }
        if action == .resumeJob {
            guard response.isEmpty else { throw KubernetesError.workloadAction(.unconfirmed) }
            return "Start requested for Job \(namespace)/\(row.name)."
        }
        guard !response.isEmpty, response.utf8.count <= 63,
              response.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw KubernetesError.workloadAction(.unconfirmed)
        }
        return "Created Job \(namespace)/\(response)."
    }
}
