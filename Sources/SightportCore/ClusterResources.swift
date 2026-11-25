enum ClusterFields {
    static let persistentVolumeClaims: [ResourceField] = [
        .value("Phase", ".status.phase"), .value("Volume", ".spec.volumeName"),
        .value("Requested", ".spec.resources.requests.storage"), .value("Capacity", ".status.capacity.storage"),
        .value("Storage class", ".spec.storageClassName"), .joined("Access modes", ".spec.accessModes")
    ]
    static let persistentVolumes: [ResourceField] = [
        .value("Phase", ".status.phase"), .value("Capacity", ".spec.capacity.storage"),
        ResourceField(name: "Claim", template: "{{with .spec.claimRef}}{{with .namespace}}{{urlquery .}}/{{end}}{{urlquery .name}}{{end}}"),
        .value("Storage class", ".spec.storageClassName"), .value("Reclaim policy", ".spec.persistentVolumeReclaimPolicy"),
        .joined("Access modes", ".spec.accessModes")
    ]
    static let storageClasses: [ResourceField] = [
        .value("Provisioner", ".provisioner"), .value("Reclaim policy", ".reclaimPolicy"),
        .value("Binding mode", ".volumeBindingMode"), .value("Allow expansion", ".allowVolumeExpansion", fallback: "false"),
        ResourceField(name: "Default", template:
            #"{{with .metadata.annotations}}{{if or (eq (index . "storageclass.kubernetes.io/is-default-class") "true") (eq (index . "storageclass.beta.kubernetes.io/is-default-class") "true")}}true{{else}}false{{end}}{{else}}false{{end}}"#)
    ]

    // events.k8s.io also converts events originally written using the core/v1 API.
    static let events: [ResourceField] = [
        .value("Type", ".type"), .value("Reason", ".reason"),
        ResourceField(name: "Object", template: "{{with .regarding}}{{urlquery .kind}}/{{urlquery .name}}{{end}}"),
        .value("Message", ".note"),
        ResourceField(name: "Last seen", template: "{{with or .series.lastObservedTime .deprecatedLastTimestamp .eventTime .metadata.creationTimestamp}}{{urlquery .}}{{end}}"),
        ResourceField(name: "Count", template: "{{with or .series.count .deprecatedCount}}{{urlquery .}}{{else}}1{{end}}"),
        ResourceField(name: "Source", template: "{{with or .reportingController .deprecatedSource.component}}{{urlquery .}}{{end}}")
    ]

    static let serviceAccounts: [ResourceField] = [
        .count("Secret references", ".secrets"), .count("Image pull secrets", ".imagePullSecrets"),
        .value("Automount token", ".automountServiceAccountToken", fallback: "Default")
    ]

    private static let rule = #"{{range $i, $v := .verbs}}{{if $i}},{{end}}{{urlquery $v}}{{end}}"#
        + #"{{with .resources}} on {{range $i, $r := .}}{{if $i}},{{end}}{{urlquery $r}}{{end}}{{end}}"#
        + #"{{with .apiGroups}} [{{range $i, $g := .}}{{if $i}},{{end}}{{if $g}}{{urlquery $g}}{{else}}core{{end}}{{end}}]{{end}}"#
        + #"{{with .resourceNames}} named {{range $i, $n := .}}{{if $i}},{{end}}{{urlquery $n}}{{end}}{{end}}"#
        + #"{{with .nonResourceURLs}} on {{range $i, $u := .}}{{if $i}},{{end}}{{urlquery $u}}{{end}}{{end}}"#

    static let roles: [ResourceField] = [
        .count("Rules", ".rules"),
        ResourceField(name: "Permissions", template: "{{range $i, $rule := .rules}}{{if $i}}; {{end}}\(rule){{end}}")
    ]
    static let clusterRoles: [ResourceField] = roles + [.count("Aggregation selectors", ".aggregationRule.clusterRoleSelectors")]

    static let roleBindings: [ResourceField] = [
        ResourceField(name: "Role", template: "{{with .roleRef}}{{urlquery .kind}}/{{urlquery .name}}{{end}}"),
        .joined("Subjects", ".subjects", item: "{{urlquery .kind}}/{{with .namespace}}{{urlquery .}}/{{end}}{{urlquery .name}}")
    ]

    static let customResourceDefinitions: [ResourceField] = [
        .value("Kind", ".spec.names.kind"), .value("Group", ".spec.group"), .value("Scope", ".spec.scope"),
        ResourceField(name: "Served Versions", template:
            #"{{with .spec.versions}}{{$sep := ""}}{{range .}}{{if .served}}{{$sep}}{{urlquery .name}}{{$sep = ", "}}{{end}}{{end}}{{else}}{{with .spec.version}}{{urlquery .}}{{end}}{{end}}"#),
        .condition("Established")
    ]
}
