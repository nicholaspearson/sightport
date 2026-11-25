import Foundation
import XCTest
@testable import SightportCore

final class KarpenterResourceTests: XCTestCase {
    func testVersionNegotiatedClusterResources() {
        XCTAssertEqual(ResourceKind.nodePools.resourceName, "nodepools.karpenter.sh")
        XCTAssertEqual(ResourceKind.nodeClaims.resourceName, "nodeclaims.karpenter.sh")
        XCTAssertEqual(ResourceKind.ec2NodeClasses.resourceName, "ec2nodeclasses.karpenter.k8s.aws")
        for kind in [ResourceKind.nodePools, .nodeClaims, .ec2NodeClasses] {
            XCTAssertFalse(kind.isNamespaced)
        }
    }

    func testNodePoolNodeCountSupportsCurrentAndOlderStatus() throws {
        let rows = try projectResource(.nodePools, items: [
            ["metadata": ["name": "static"], "spec": ["weight": 0, "template": ["spec": ["nodeClassRef": [
                "kind": "EC2NodeClass", "name": "compute"]]]], "status": [
                "nodes": 0, "resources": ["nodes": "9", "cpu": "8", "memory": "32Gi"],
                "conditions": [["type": "Ready", "status": "False"]]]],
            ["metadata": ["name": "older"], "status": ["resources": ["nodes": "3"]]],
            ["metadata": ["name": "pending"]]
        ])
        XCTAssertEqual(rows.map(\.name), ["static", "older", "pending"])
        XCTAssertEqual(rows[0].values, ["False", "EC2NodeClass/compute", "0", "8", "32Gi", "0"])
        XCTAssertEqual(rows[1].values, ["", "", "3", "", "", ""])
        XCTAssertEqual(rows[2].values, ["", "", "", "", "", ""])
    }

    func testNodeClaimProjectsWellKnownLabelsAndNode() throws {
        let rows = try projectResource(.nodeClaims, items: [
            ["metadata": ["name": "compute-m8f", "labels": [
                "karpenter.sh/nodepool": "compute", "karpenter.sh/capacity-type": "spot",
                "node.kubernetes.io/instance-type": "m7g.large", "topology.kubernetes.io/zone": "eu-west-1b"]],
             "spec": ["nodeClassRef": ["name": "linux"]],
             "status": ["nodeName": "worker-a", "conditions": [
                ["type": "Registered", "status": "True"], ["type": "Ready", "status": "Unknown"]]]],
            ["metadata": ["name": "pending"]]
        ])
        XCTAssertEqual(rows[0].values, ["Unknown", "compute", "worker-a", "m7g.large", "spot", "eu-west-1b", "linux"])
        XCTAssertTrue(rows[1].values.allSatisfy(\.isEmpty))
    }

    func testEC2NodeClassShowsResolvedResourcesAndInstanceProfile() throws {
        let rows = try projectResource(.ec2NodeClasses, items: [
            ["metadata": ["name": "workers"], "spec": ["role": "worker-role", "amiFamily": "AL2023", "userData": "private"],
             "status": ["instanceProfile": "managed-profile", "subnets": [["id": "a"], ["id": "b"]],
                        "amis": [["id": "image"]], "conditions": [["type": "Ready", "status": "True"]]]],
            ["metadata": ["name": "provisioning"], "spec": ["instanceProfile": "provided-profile"]]
        ])
        XCTAssertEqual(rows[0].values, ["True", "worker-role", "managed-profile", "AL2023", "2", "0", "1"])
        XCTAssertEqual(rows[1].values, ["", "", "provided-profile", "", "0", "0", "0"])
    }
}
