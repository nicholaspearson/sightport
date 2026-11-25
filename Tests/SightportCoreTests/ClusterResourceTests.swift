import XCTest
@testable import SightportCore

final class ClusterResourceTests: XCTestCase {
    private func projection(_ kind: ResourceKind, _ object: [String: Any]) throws -> [String: String] {
        var object = object
        if object["metadata"] == nil { object["metadata"] = ["name": "test"] }
        let row = try XCTUnwrap(projectResource(kind, items: [object]).first)
        return Dictionary(uniqueKeysWithValues: zip(kind.columns, row.values))
    }

    func testCatalogScopesAndDiscoveryNames() {
        let clusterKinds: Set<ResourceKind> = [.ingressClasses, .gatewayClasses, .persistentVolumes, .storageClasses,
                                                .clusterRoles, .clusterRoleBindings, .customResourceDefinitions]
        let kinds = ResourceKind.network + ResourceKind.gatewayAPI + ResourceKind.storage + ResourceKind.accessControl
            + [.events, .customResourceDefinitions]
        for kind in kinds {
            XCTAssertEqual(kind.isNamespaced, !clusterKinds.contains(kind), kind.title)
        }
        XCTAssertEqual(ResourceKind.endpointSlices.resourceName, "endpointslices.discovery.k8s.io")
        XCTAssertEqual(ResourceKind.networkPolicies.resourceName, "networkpolicies.networking.k8s.io")
        XCTAssertEqual(ResourceKind.clusterRoleBindings.resourceName, "clusterrolebindings.rbac.authorization.k8s.io")
        XCTAssertEqual(ResourceKind.events.resourceName, "events.events.k8s.io")
        XCTAssertTrue(ResourceKind.gatewayAPI.allSatisfy { $0.resourceName.hasSuffix(".gateway.networking.k8s.io") })
    }

    func testAllViewsAcceptObjectsWithOptionalFieldsAbsent() throws {
        for kind in ResourceKind.network + ResourceKind.gatewayAPI + ResourceKind.storage + ResourceKind.accessControl
            + [.events, .customResourceDefinitions] {
            let values = try projection(kind, [:])
            XCTAssertFalse(values.values.contains(where: { $0.contains("<no value>") || $0.contains("<nil>") }), kind.title)
        }
    }

    func testDualStackServicesSlicesAndEndpoints() throws {
        let service = try projection(.services, ["spec": ["clusterIPs": ["10.1.2.3", "fd::1"], "type": "LoadBalancer",
            "ports": [["name": "web", "port": 80, "nodePort": 32080, "protocol": "TCP"], ["port": 443, "protocol": "TCP"]]],
            "status": ["loadBalancer": ["ingress": [["ip": "192.0.2.1"], ["hostname": "lb.example"]]]]])
        XCTAssertEqual(service["Cluster IPs"], "10.1.2.3, fd::1")
        XCTAssertEqual(service["Ports"], "web=80:32080/TCP, 443/TCP")
        XCTAssertEqual(service["Load balancer"], "192.0.2.1, lb.example")
        XCTAssertEqual(try projection(.services, ["spec": ["clusterIP": "None"]])["Cluster IPs"], "None")
        let slice = try projection(.endpointSlices, ["metadata": ["name": "test", "labels": ["kubernetes.io/service-name": "web"]],
            "addressType": "IPv4", "endpoints": [["addresses": ["10.2.0.1", "10.2.0.2"]], ["addresses": ["10.2.0.3"]]]])
        XCTAssertEqual(slice["Service"], "web")
        XCTAssertEqual(slice["Addresses"], "10.2.0.1, 10.2.0.2, 10.2.0.3")
        let endpoints = try projection(.endpoints, ["subsets": [
            ["notReadyAddresses": [["ip": "10.2.0.11"]]],
            ["addresses": [["ip": "10.2.0.2"], ["ip": "10.2.0.3"]], "ports": [["port": 80, "protocol": "TCP"]]]]])
        XCTAssertEqual(endpoints["Ready addresses"], "10.2.0.2, 10.2.0.3")
        XCTAssertEqual(endpoints["Not ready"], "10.2.0.11")
        XCTAssertEqual(endpoints["Ports"], "80/TCP")
    }

    func testIngressGatewayAndNetworkPolicy() throws {
        let ingress = try projection(.ingresses, ["metadata": ["name": "one", "annotations": ["kubernetes.io/ingress.class": "nginx"]],
                                                  "spec": ["rules": [["host": "one.example"], ["http": [:]]]]])
        XCTAssertEqual(ingress["Class"], "nginx")
        XCTAssertEqual(ingress["Hosts"], "one.example, *")
        let selector: [String: Any] = ["matchLabels": ["env": "prod"], "matchExpressions": [["key": "app", "operator": "In", "values": ["api", "worker"]]]]
        XCTAssertEqual(try projection(.networkPolicies, ["spec": ["podSelector": selector]])["Pod selector"], "env=prod, app In (api, worker)")
        let parent = ["name": "edge", "namespace": "infra", "sectionName": "public"]
        let route = try projection(.httpRoutes, ["spec": ["parentRefs": [parent], "hostnames": ["api.example"]],
            "status": ["parents": [["parentRef": parent, "conditions": [["type": "Accepted", "status": "False"]]]]]])
        XCTAssertEqual(route["Parents"], "Gateway/infra/edge#public")
        XCTAssertEqual(route["Acceptance"], "Gateway/infra/edge#public=False")
        XCTAssertEqual(try projection(.gateways, ["spec": ["listeners": [["name": "web", "port": 443, "protocol": "HTTPS"]]]])["Listeners"], "web=443/HTTPS")
    }

    func testStoragePermissionsAndEventSeries() throws {
        let storage = try projection(.storageClasses, ["metadata": ["name": "test", "annotations": ["storageclass.kubernetes.io/is-default-class": "true"]], "allowVolumeExpansion": false])
        XCTAssertEqual(storage["Default"], "true")
        XCTAssertEqual(storage["Allow expansion"], "false")
        XCTAssertEqual(try projection(.persistentVolumes, ["spec": ["claimRef": ["namespace": "web", "name": "cache"]]])["Claim"], "web/cache")
        let role = try projection(.roles, ["rules": [["verbs": ["get", "list"], "apiGroups": [""], "resources": ["pods"], "resourceNames": ["web"]],
                                                     ["verbs": ["get"], "nonResourceURLs": ["/healthz"]]]])
        XCTAssertEqual(role["Permissions"], "get,list on pods [core] named web; get on /healthz")
        let event = try projection(.events, ["regarding": ["kind": "Pod", "name": "cache"], "note": "failed\tto\nmount + retry",
            "eventTime": "first", "deprecatedLastTimestamp": "old", "series": ["lastObservedTime": "latest", "count": 3]])
        XCTAssertEqual(event["Message"], "failed\tto\nmount + retry")
        XCTAssertEqual(event["Object"], "Pod/cache")
        XCTAssertEqual(event["Last seen"], "latest")
        XCTAssertEqual(event["Count"], "3")
        XCTAssertEqual(try projection(.events, ["deprecatedCount": 7, "deprecatedLastTimestamp": "older"])["Count"], "7")
    }

    func testCRDVersionProjectionOmitsUnservedVersions() throws {
        let definition = try projection(.customResourceDefinitions, ["spec": ["group": "example.io", "scope": "Namespaced",
            "names": ["kind": "Widget"], "versions": [["name": "v1alpha1", "served": false], ["name": "v1beta1", "served": true], ["name": "v1", "served": true]]]])
        XCTAssertEqual(definition["Served Versions"], "v1beta1, v1")
        XCTAssertEqual(definition["Scope"], "Namespaced")
        XCTAssertEqual(try projection(.customResourceDefinitions, ["spec": ["version": "v1beta1"]])["Served Versions"], "v1beta1")
    }
}
