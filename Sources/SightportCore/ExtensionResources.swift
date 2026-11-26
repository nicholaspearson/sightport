import Foundation

public struct CustomResourceType: Hashable, Sendable {
    public let kind: String
    public let group: String
    public let resourceName: String
    public let isNamespaced: Bool
    public let version: String
    let versionedName: String

    public init?(definition: ResourceRow) {
        let fields = Dictionary(uniqueKeysWithValues: zip(ResourceKind.customResourceDefinitions.columns, definition.values))
        guard let kind = fields["Kind"], let group = fields["Group"],
              let scope = fields["Scope"], ["Namespaced", "Cluster"].contains(scope),
              definition.name.hasSuffix("." + group), group.utf8.count <= 253, group.contains("."),
              fields["Established"] != "False" else { return nil }
        let plural = String(definition.name.dropLast(group.count + 1))
        func validLabel(_ value: String) -> Bool {
            value.utf8.count <= 63 && value.range(of: #"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?\z"#, options: .regularExpression) != nil
        }
        func validAPIName(_ value: String) -> Bool {
            value.first?.isLetter == true && validLabel(value)
        }
        let labels = group.components(separatedBy: ".")
        guard labels.allSatisfy(validLabel), validAPIName(plural), validAPIName(kind.lowercased()) else { return nil }
        let served = fields["Served Versions"]?.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init).filter(validAPIName) ?? []
        guard let version = fields["Storage Version"].flatMap({ served.contains($0) ? $0 : nil }) ?? served.first else { return nil }
        self.kind = kind
        self.group = group
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

public struct CustomResourceGroup: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let types: [CustomResourceType]

    public static func catalog(from definitions: [ResourceRow]) -> [Self] {
        // During deletion/recreation a watch can briefly contain two UIDs for the same API endpoint.
        let latest = Dictionary(definitions.lazy.map { ($0.name, $0) }, uniquingKeysWith: { previous, next in
            if let previousDate = previous.createdAt, let nextDate = next.createdAt, previousDate > nextDate { return previous }
            return next
        })
        let groups = Dictionary(grouping: latest.values.compactMap(CustomResourceType.init(definition:)), by: \.group)
        return groups.map { name, types in
            Self(name: name, types: types.sorted { ($0.kind, $0.resourceName) < ($1.kind, $1.resourceName) })
        }.sorted { $0.name < $1.name }
    }
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
        try await listResourceRows(.custom(type), in: file, context: context, namespace: namespace)
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
