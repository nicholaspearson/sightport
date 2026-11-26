import Foundation

extension ResourceKind {
    var argoLabelSelector: String? {
        switch self {
        case .argoRepositories: return "argocd.argoproj.io/secret-type=repository"
        case .argoClusters: return "argocd.argoproj.io/secret-type=cluster"
        default: return nil
        }
    }
}

enum ArgoFields {
    static let applications: [ResourceField] = [
        .value("Sync", ".status.sync.status", fallback: "Unknown"),
        .value("Health", ".status.health.status", fallback: "Unknown"),
        .value("Project", ".spec.project", fallback: "default"),
        .value("Target namespace", ".spec.destination.namespace"),
        ResourceField(name: "Sync policy", template: """
            {{if and (ne .spec.syncPolicy.automated nil) (ne .spec.syncPolicy.automated.enabled false)}}Automated{{else}}Manual{{end}}
            """),
        ResourceField(name: "Resources", template: "{{if ne .status.resources nil}}{{len .status.resources}}{{end}}")
    ]

    static let applicationSets: [ResourceField] = [
        .value("Template project", ".spec.template.spec.project"),
        .count("Generators", ".spec.generators"),
        condition("Parameters generated", type: "ParametersGenerated"),
        condition("Up to date", type: "ResourcesUpToDate"),
        .value("Application policy", ".spec.syncPolicy.applicationsSync", fallback: "Inherited")
    ]

    static let projects: [ResourceField] = [
        .value("Description", ".spec.description"),
        .count("Source rules", ".spec.sourceRepos"),
        .count("Destination rules", ".spec.destinations"),
        .count("Roles", ".spec.roles")
    ]

    // Only these explicitly named identity fields enter the table projection.
    // Secret payloads and connection credentials never enter the resource table.
    static let repositories: [ResourceField] = [
        .value("Repository", ".data.url"), .value("Type", ".data.type"), .value("Project", ".data.project")
    ]

    static let clusters: [ResourceField] = [
        .value("Cluster", ".data.name"), .value("API server", ".data.server"), .value("Project", ".data.project"),
        ResourceField(name: "Skip reconciliation", template: """
            {{if .metadata.annotations}}{{if eq (index .metadata.annotations "argocd.argoproj.io/skip-reconcile") "true"}}Yes{{else}}No{{end}}{{else}}No{{end}}
            """)
    ]

    static func displayValues(_ fields: [String], for kind: ResourceKind) -> [String] {
        switch kind {
        case .argoRepositories:
            return [address(identity(fields[0]), allowShorthand: true), identity(fields[1]), identity(fields[2])]
        case .argoClusters:
            let name = identity(fields[0])
            return [name.contains("://") ? address(name) : name, address(identity(fields[1])), identity(fields[2]), fields[3]]
        default:
            return fields
        }
    }

    private static func identity(_ encoded: String) -> String {
        guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8),
              data.count <= 8192, value.rangeOfCharacter(from: .controlCharacters) == nil else { return "" }
        return value
    }

    private static func address(_ value: String, allowShorthand: Bool = false) -> String {
        guard !value.isEmpty, !value.contains("\\"), value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return "" }
        if value.contains("://") {
            guard var url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
                  ["https", "http", "ssh", "git", "git+ssh", "oci"].contains(scheme),
                  let host = url.host, !host.isEmpty,
                  host.rangeOfCharacter(from: CharacterSet(charactersIn: "@/?#\\").union(.controlCharacters)) == nil else { return "" }
            url.user = nil
            url.password = nil
            url.query = nil
            url.fragment = nil
            return url.string ?? ""
        }
        // Git SCP-style remotes and scheme-less Helm OCI registries.
        guard allowShorthand else { return "" }
        let bare = value.prefix { $0 != "?" && $0 != "#" }
        let authority = bare.prefix { $0 != "/" }
        let tail = authority.lastIndex(of: "@").map { bare[bare.index(after: $0)...] } ?? bare
        guard tail.range(of: #"^(?:\[[A-Fa-f0-9:]+\]|[A-Za-z0-9.-]+)[:/][^@]+$"#, options: .regularExpression) != nil,
              !tail.hasPrefix(".") else { return "" }
        return String(tail)
    }

    private static func condition(_ title: String, type: String) -> ResourceField {
        ResourceField(name: title, template: """
            {{range .status.conditions}}{{if eq .type "\(type)"}}{{urlquery .status}}{{end}}{{end}}
            """)
    }
}

public struct ArgoApplicationStatus {
    public let sync: String
    public let health: String

    public init(row: ResourceRow) {
        sync = row.values.indices.contains(0) && !row.values[0].isEmpty ? row.values[0] : "Unknown"
        health = row.values.indices.contains(1) && !row.values[1].isEmpty ? row.values[1] : "Unknown"
    }

    public var needsAttention: Bool {
        sync != "Synced" || ["Degraded", "Missing", "Unknown"].contains(health)
    }
}
