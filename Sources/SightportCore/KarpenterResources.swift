enum KarpenterFields {
    private static let ready = ResourceField(name: "Ready", template:
        #"{{range .status.conditions}}{{if eq .type "Ready"}}{{urlquery .status}}{{end}}{{end}}"#)

    static let nodePools: [ResourceField] = [
        ready, nodeClass(".spec.template.spec.nodeClassRef"),
        // Older NodePool controllers published the node count alongside CPU and memory.
        ResourceField(name: "Nodes", template:
            #"{{if ne .status.nodes nil}}{{urlquery .status.nodes}}{{else if ne .status.resources.nodes nil}}{{urlquery .status.resources.nodes}}{{end}}"#),
        .value("CPU", ".status.resources.cpu"), .value("Memory", ".status.resources.memory"),
        .value("Weight", ".spec.weight")
    ]

    static let nodeClaims: [ResourceField] = [
        ready, label("Node Pool", "karpenter.sh/nodepool"), .value("Node", ".status.nodeName"),
        label("Instance Type", "node.kubernetes.io/instance-type"), label("Capacity Type", "karpenter.sh/capacity-type"),
        label("Zone", "topology.kubernetes.io/zone"), nodeClass(".spec.nodeClassRef")
    ]

    static let ec2NodeClasses: [ResourceField] = [
        ready, .value("Role", ".spec.role"),
        ResourceField(name: "Instance Profile", template:
            #"{{with .status.instanceProfile}}{{urlquery .}}{{else}}{{with .spec.instanceProfile}}{{urlquery .}}{{end}}{{end}}"#),
        .value("AMI Family", ".spec.amiFamily"), .count("Subnets", ".status.subnets"),
        .count("Security Groups", ".status.securityGroups"), .count("AMIs", ".status.amis")
    ]

    private static func nodeClass(_ path: String) -> ResourceField {
        ResourceField(name: "Node Class", template:
            "{{with \(path)}}{{if .name}}{{with .kind}}{{urlquery .}}/{{end}}{{urlquery .name}}{{end}}{{end}}")
    }

    private static func label(_ title: String, _ key: String) -> ResourceField {
        ResourceField(name: title, template:
            "{{with .metadata.labels}}{{with index . \"\(key)\"}}{{urlquery .}}{{end}}{{end}}")
    }
}
