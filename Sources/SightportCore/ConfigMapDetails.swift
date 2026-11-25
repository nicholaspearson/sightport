import Foundation

public struct ConfigMapDetails: Sendable {
    public private(set) var labels: [String: String] = [:]
    public private(set) var annotations: [String: String] = [:]
    public private(set) var data: [String: String] = [:]
    public private(set) var binaryData: [String: Data] = [:]

    // Escape free-form text so tabs, trailing newlines and empty values survive the projection.
    // Kubernetes keys and the base64 supplied for binaryData are already single-line fields.
    static let projection = #"{{.metadata.uid}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{.metadata.namespace}}{{"\n"}}"#
        + #"{{range $key, $v := .metadata.labels}}L{{"\t"}}{{$key}}{{"\t"}}{{urlquery $v}}{{"\n"}}{{end}}"#
        + #"{{range $key, $v := .metadata.annotations}}A{{"\t"}}{{$key}}{{"\t"}}{{urlquery $v}}{{"\n"}}{{end}}"#
        + #"{{range $key, $v := .data}}D{{"\t"}}{{$key}}{{"\t"}}{{urlquery $v}}{{"\n"}}{{end}}"#
        + #"{{range $key, $v := .binaryData}}B{{"\t"}}{{$key}}{{"\t"}}{{$v}}{{"\n"}}{{end}}"#

    init(output: Data, row: ResourceRow, namespace: String) throws {
        guard let text = String(data: output, encoding: .utf8) else { throw KubernetesError.configMapUnavailable }
        var lines = text.split(separator: "\n").makeIterator()
        guard let header = lines.next() else { throw KubernetesError.configMapUnavailable }
        let identity = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard identity.count == 3 else { throw KubernetesError.configMapUnavailable }
        guard identity[0] == row.id, identity[1] == row.name, identity[2] == namespace else {
            throw KubernetesError.configMapMissing
        }
        while let line = lines.next() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[1].isEmpty else { throw KubernetesError.configMapUnavailable }
            let key = String(parts[1])
            switch parts[0] {
            case "L": labels[key] = try unescapeResourceField(parts[2])
            case "A": annotations[key] = try unescapeResourceField(parts[2])
            case "D": data[key] = try unescapeResourceField(parts[2])
            case "B":
                guard let bytes = Data(base64Encoded: String(parts[2])) else { throw KubernetesError.configMapUnavailable }
                binaryData[key] = bytes
            default: throw KubernetesError.configMapUnavailable
            }
        }
    }
}

extension KubernetesClient {
    public func configMapDetails(for row: ResourceRow, in file: URL, context: String) async throws -> ConfigMapDetails {
        let namespace = try selectedNamespace(for: row, context: context, missing: .configMapMissing)
        let args = ["--context=" + context, "--request-timeout=8s", "get", "configmap/" + row.name,
                    "--namespace=" + namespace, "-o", "go-template=" + ConfigMapDetails.projection]
        let output = try await run(args, file: file, operation: .configMapDetails)
        return try ConfigMapDetails(output: output, row: row, namespace: namespace)
    }
}
