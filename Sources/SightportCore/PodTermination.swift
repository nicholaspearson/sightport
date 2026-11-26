import Foundation

extension KubernetesClient {
    /// Requests graceful deletion of this specific pod incarnation.
    /// A successful return means the API server accepted the request.
    public func terminatePod(_ row: ResourceRow, in file: URL, context: String) async throws {
        let namespace = try selectedNamespace(for: row, context: context, missing: .podIdentityMissing)
        let arguments = ["--context=" + context, "--request-timeout=8s", "terminate-pod", row.name,
                         "--namespace=" + namespace, "--uid=" + row.id]
        do {
            _ = try await run(arguments, file: file, operation: .podTermination)
        } catch KubernetesError.timeout {
            throw KubernetesError.podTerminationUnconfirmed
        }
    }
}
