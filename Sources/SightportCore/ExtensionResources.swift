import Foundation

public struct CustomResourceType: Hashable, Sendable {
    public let kind: String
    public let resourceName: String
    public let isNamespaced: Bool
    public let version: String
    let versionedName: String

    public init?(definition: ResourceRow) {
        let fields = Dictionary(uniqueKeysWithValues: zip(ResourceKind.customResourceDefinitions.columns, definition.values))
        guard let kind = fields["Kind"], !kind.isEmpty, let group = fields["Group"],
              let scope = fields["Scope"], ["Namespaced", "Cluster"].contains(scope),
              definition.name.hasSuffix("." + group),
              let firstVersion = fields["Served Versions"]?.split(whereSeparator: { $0 == "," || $0.isWhitespace }).first else { return nil }
        let plural = String(definition.name.dropLast(group.count + 1))
        let version = String(firstVersion)
        // CRD names arrive over the network. Restrict the resource argument to a single API type.
        let labels = group.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard ([plural, version] + labels).allSatisfy({
            $0.count <= 63 && $0.range(of: #"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?\z"#, options: .regularExpression) != nil
        }) else { return nil }
        self.kind = kind
        self.resourceName = definition.name
        self.isNamespaced = scope == "Namespaced"
        self.version = version
        self.versionedName = [plural, version, group].joined(separator: ".")
    }

    public static let columns = fields.map(\.name)
    private static let fields: [ResourceField] = [
        .value("API Version", ".apiVersion"), .value("Generation", ".metadata.generation"),
        ResourceField(name: "Phase", template: #"""
            {{if eq (printf "%T" .status) "map[string]interface {}"}}{{if eq (printf "%T" .status.phase) "string"}}{{urlquery .status.phase}}{{end}}{{end}}
            """#),
        ResourceField(name: "Controller", template: #"""
            {{range .metadata.ownerReferences}}{{if .controller}}{{urlquery .kind}}/{{urlquery .name}}{{end}}{{end}}
            """#)
    ]
    static let rowTemplate: String = {
        let metadata = [".metadata.uid", ".metadata.name", ".metadata.namespace", ".metadata.creationTimestamp"]
            .map { ResourceField.value("", $0).template }
        return (metadata + fields.map(\.template)).joined(separator: #"{{"\t"}}"#)
    }()
}

public enum HelmReleases {
    public static let columns = ["Status", "Chart", "App Version", "Revision", "Updated"]

    fileprivate struct Release: Decodable {
        let name: String
        let namespace: String
        let status: String
        let chart: String
        let app_version: String
        let revision: String
        let updated: String

        var row: ResourceRow {
            ResourceRow(id: namespace + "/" + name, name: name, namespace: namespace, createdAt: nil,
                        values: [status, chart, app_version, revision, updated])
        }
    }
}

extension KubernetesClient {
    public func customResources(_ type: CustomResourceType, in file: URL, context: String,
                                namespace: String?) async throws -> [ResourceRow] {
        let target = ResourceWatchTarget.custom(type)
        let args = try target.arguments(context: context, namespace: namespace) + ["-o", "go-template=" + target.listTemplate]
        let data = try await run(args, file: file, operation: .customResources(type.resourceName, type.isNamespaced ? namespace : nil))
        return try ResourceRow.decodeList(data, columnCount: CustomResourceType.columns.count)
    }

    public func helmReleases(in file: URL, context: String, namespace: String?) async throws -> [ResourceRow] {
        guard !context.isEmpty else { throw KubernetesError.missingContext }
        guard namespace?.isEmpty != true else { throw ResourceReadError.emptyNamespace }
        let scope = namespace.map { "--namespace=" + $0 } ?? "--all-namespaces"
        // Helm sorts the latest releases before applying its local row limit. Ask for the
        // complete snapshot in one call so equal names across namespaces cannot drift between pages.
        // Explicit state filters give Helm 3 and 4 the same semantics.
        let args = ["list", "--kube-context=" + context, scope, "--deployed", "--failed", "--pending",
                    "--uninstalling", "--uninstalled", "--superseded", "--max=\(Int32.max)", "--output=json"]
        let data = try await run(args, file: file, operation: .helmReleases)
        guard let releases = try? JSONDecoder().decode([HelmReleases.Release].self, from: data),
              releases.allSatisfy({ !$0.name.isEmpty && !$0.namespace.isEmpty }) else { throw KubernetesError.helmUnavailable }
        return releases.map(\.row)
    }
}
