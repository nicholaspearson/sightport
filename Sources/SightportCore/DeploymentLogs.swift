import Foundation

public struct LogPod: Decodable, Equatable, Identifiable, Sendable {
    public struct Container: Decodable, Equatable, Sendable {
        public let name: String
        public let restartCount: Int
    }

    public let id: String
    public let name: String
    public let containers: [Container]

    public init?(row: ResourceRow) {
        guard let pod = row.pod else { return nil }
        id = row.id
        name = row.name
        containers = pod.containers.map { Container(name: $0.name, restartCount: $0.restartCount) }
    }
}

extension KubernetesClient {
    public func deploymentLogPods(in file: URL, context: String, deployment: ResourceRow) async throws -> [LogPod] {
        let namespace = try selectedNamespace(for: deployment, context: context, missing: .deploymentLogTargetMissing)
        let arguments = ["--context=\(context)", "--request-timeout=12s", "--namespace=\(namespace)",
                         "--uid=\(deployment.id)", "deployment-log-pods", deployment.name]
        let output = try await run(arguments, file: file, operation: .deploymentLogPods)
        guard let pods = try? JSONDecoder().decode([LogPod].self, from: output) else {
            throw KubernetesError.deploymentLogPodsUnavailable
        }
        return pods
    }
}
