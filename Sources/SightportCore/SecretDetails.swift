import Foundation

public struct SecretDataEntry: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    fileprivate let bytes: Data

    public var byteCount: Int { bytes.count }
    public var base64: String { bytes.base64EncodedString() }

    public var text: String? {
        guard let value = String(data: bytes, encoding: .utf8) else { return nil }
        // Some binary formats are valid UTF-8 but contain NULs or other non-printing control bytes.
        let binary = value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0..<9, 11, 12, 14..<32, 127...159: return true
            default: return false
            }
        }
        return binary ? nil : value
    }
}

public struct SecretDetails: Sendable {
    public let entries: [SecretDataEntry]

    // Kubernetes data keys contain only letters, numbers, dashes, periods and underscores.
    // Their base64 values contain neither tabs nor newlines, including for multiline text.
    static let projection = #"{{.metadata.uid}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{.metadata.namespace}}{{"\n"}}{{range $key, $value := .data}}{{$key}}{{"\t"}}{{$value}}{{"\n"}}{{end}}"#

    init(output: Data, row: ResourceRow, namespace: String) throws {
        guard let output = String(data: output, encoding: .utf8) else { throw KubernetesError.secretUnavailable }
        let lines = output.split(separator: "\n")
        guard let header = lines.first else { throw KubernetesError.secretUnavailable }
        let identity = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard identity.count == 3 else { throw KubernetesError.secretUnavailable }
        guard identity[0] == row.id, identity[1] == row.name, identity[2] == namespace else {
            throw KubernetesError.secretMissing
        }
        entries = try lines.dropFirst().map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, let bytes = Data(base64Encoded: String(fields[1])) else {
                throw KubernetesError.secretUnavailable
            }
            return SecretDataEntry(key: String(fields[0]), bytes: bytes)
        }.sorted { $0.key < $1.key }
    }
}

extension KubernetesClient {
    public func secretDetails(for row: ResourceRow, in file: URL, context: String) async throws -> SecretDetails {
        let namespace = try selectedNamespace(for: row, context: context, missing: .secretMissing)
        let arguments = ["--context=" + context, "--request-timeout=8s", "get", "secret/" + row.name,
                         "--namespace=" + namespace, "-o", "go-template=" + SecretDetails.projection]
        let output = try await run(arguments, file: file, operation: .secretDetails)
        return try SecretDetails(output: output, row: row, namespace: namespace)
    }

    public func secretEvents(for row: ResourceRow, in file: URL, context: String) async throws -> [ResourceRow] {
        let namespace = try selectedNamespace(for: row, context: context, missing: .secretMissing)
        let uid = row.id.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "=", with: "\\=")
        let output = try await resourceOutput(.events, in: file, context: context, namespace: namespace,
                                              template: ResourceKind.events.listTemplate, fieldSelector: "regarding.uid=" + uid)
        return try ResourceRow.decodeList(output, kind: .events)
    }
}
