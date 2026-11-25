extension ResourceField {
    static func joined(_ title: String, _ path: String, item: String = "{{urlquery .}}") -> Self {
        Self(name: title, template: "{{range $i, $item := \(path)}}{{if $i}}, {{end}}\(item){{end}}")
    }

    static func condition(_ type: String) -> Self {
        Self(name: type, template: "{{range .status.conditions}}{{if eq .type \"\(type)\"}}{{urlquery .status}}{{end}}{{end}}")
    }
}

enum NetworkFields {
    private static let ports = "{{with .name}}{{urlquery .}}={{end}}{{with .port}}{{urlquery .}}{{else}}*{{end}}"
        + "{{with .nodePort}}:{{urlquery .}}{{end}}{{with .protocol}}/{{urlquery .}}{{end}}"
    private static let ingressAddress = "{{with .ip}}{{urlquery .}}{{else}}{{with .hostname}}{{urlquery .}}{{end}}{{end}}"

    static let services: [ResourceField] = [
        .value("Type", ".spec.type"),
        ResourceField(name: "Cluster IPs", template: "{{with .spec.clusterIPs}}{{range $i, $ip := .}}{{if $i}}, {{end}}{{urlquery $ip}}{{end}}{{else}}{{with .spec.clusterIP}}{{urlquery .}}{{end}}{{end}}"),
        .joined("Ports", ".spec.ports", item: ports),
        .joined("Load balancer", ".status.loadBalancer.ingress", item: ingressAddress),
        .joined("External IPs", ".spec.externalIPs"), .value("External name", ".spec.externalName")
    ]

    static let endpointSlices: [ResourceField] = [
        ResourceField(name: "Service", template: #"{{with .metadata.labels}}{{with index . "kubernetes.io/service-name"}}{{urlquery .}}{{end}}{{end}}"#),
        .value("Address type", ".addressType"),
        .joined("Addresses", ".endpoints", item: "{{range $j, $addr := .addresses}}{{if $j}}, {{end}}{{urlquery $addr}}{{end}}"),
        .joined("Ports", ".ports", item: ports)
    ]

    static let endpoints: [ResourceField] = [
        subsetList("Ready addresses", path: ".addresses", item: "{{urlquery .ip}}"),
        subsetList("Not ready", path: ".notReadyAddresses", item: "{{urlquery .ip}}"),
        subsetList("Ports", path: ".ports", item: ports)
    ]

    private static func subsetList(_ name: String, path: String, item: String) -> ResourceField {
        ResourceField(name: name, template: #"{{$sep := ""}}{{range .subsets}}"# + "{{range \(path)}}{{$sep}}\(item)"
            + #"{{$sep = ", "}}{{end}}{{end}}"#)
    }

    static let ingresses: [ResourceField] = [
        ResourceField(name: "Class", template: #"{{with .spec.ingressClassName}}{{urlquery .}}{{else}}{{with .metadata.annotations}}{{with index . "kubernetes.io/ingress.class"}}{{urlquery .}}{{end}}{{end}}{{end}}"#),
        .joined("Hosts", ".spec.rules", item: "{{with .host}}{{urlquery .}}{{else}}*{{end}}"),
        .joined("Addresses", ".status.loadBalancer.ingress", item: ingressAddress),
        .count("TLS entries", ".spec.tls")
    ]

    static let ingressClasses: [ResourceField] = [
        .value("Controller", ".spec.controller"),
        .value("Parameter kind", ".spec.parameters.kind"), .value("Parameter name", ".spec.parameters.name")
    ]

    static let networkPolicies: [ResourceField] = [
        ResourceField(name: "Pod selector", template:
            #"{{$sep := ""}}{{range $key, $value := .spec.podSelector.matchLabels}}{{$sep}}{{urlquery $key}}={{urlquery $value}}{{$sep = ", "}}{{end}}"#
            + #"{{range .spec.podSelector.matchExpressions}}{{$sep}}{{urlquery .key}} {{urlquery .operator}}{{with .values}} ({{range $i, $v := .}}{{if $i}}, {{end}}{{urlquery $v}}{{end}}){{end}}{{$sep = ", "}}{{end}}{{if not $sep}}All pods{{end}}"#),
        .joined("Policy types", ".spec.policyTypes"), .count("Ingress rules", ".spec.ingress"), .count("Egress rules", ".spec.egress")
    ]

    static let gatewayClasses: [ResourceField] = [
        .value("Controller", ".spec.controllerName"), .condition("Accepted"), .value("Description", ".spec.description")
    ]
    static let gateways: [ResourceField] = [
        .value("Class", ".spec.gatewayClassName"), .condition("Programmed"),
        .joined("Listeners", ".spec.listeners", item: "{{urlquery .name}}={{urlquery .port}}/{{urlquery .protocol}}"),
        .joined("Addresses", ".status.addresses", item: "{{urlquery .value}}")
    ]

    private static let parent = "{{with .kind}}{{urlquery .}}{{else}}Gateway{{end}}/"
        + "{{with .namespace}}{{urlquery .}}/{{end}}{{urlquery .name}}{{with .sectionName}}#{{urlquery .}}{{end}}"
    static let routes: [ResourceField] = [
        .joined("Parents", ".spec.parentRefs", item: parent), .count("Rules", ".spec.rules"),
        .joined("Acceptance", ".status.parents", item: "{{with .parentRef}}\(parent){{end}}"
                + #"{{range .conditions}}{{if eq .type "Accepted"}}={{urlquery .status}}{{end}}{{end}}"#)
    ]
    static let hostRoutes: [ResourceField] = [.joined("Hostnames", ".spec.hostnames")] + routes

    static let referenceGrants: [ResourceField] = [
        .joined("From", ".spec.from", item: "{{urlquery .namespace}}: {{urlquery .kind}}{{with .group}}.{{urlquery .}}{{end}}"),
        .joined("To", ".spec.to", item: "{{urlquery .kind}}{{with .group}}.{{urlquery .}}{{end}}/{{with .name}}{{urlquery .}}{{else}}*{{end}}")
    ]

    static let backendTLSPolicies: [ResourceField] = [
        .joined("Targets", ".spec.targetRefs", item: "{{urlquery .kind}}/{{urlquery .name}}{{with .sectionName}}#{{urlquery .}}{{end}}"),
        .value("Hostname", ".spec.validation.hostname"), .count("CA references", ".spec.validation.caCertificateRefs"),
        .value("Well-known CAs", ".spec.validation.wellKnownCACertificates")
    ]
}
