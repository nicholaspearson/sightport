import Foundation
import XCTest
@testable import SightportCore

final class PodDetailsTests: XCTestCase {
    private func row(_ details: String, phase: String = "Running", ready: String = "True") throws -> ResourceRow {
        let output = ["worker-uid", "worker", "blue", "2026-11-25T12%3A34%3A56Z", phase, ready, "pool-07", details]
            .joined(separator: "\t")
        let rows = try ResourceRow.decodeList(Data(output.utf8), kind: .pods)
        return try XCTUnwrap(rows.first)
    }

    func testPodContainerRolesStatusAndControllerFromProjectedRecord() throws {
        let details = [
            "pod,Burstable,,", "owner,apps%2Fv1,ReplicaSet,workers,owner-123",
            "spec,app,api,", "spec,app,pending,", "spec,init,setup,", "spec,ephemeral,helper,",
            "state,app,api,running,true,2,,,true", "state,app,pending,waiting,false,0,CrashLoopBackOff,,false",
            "state,init,setup,terminated,false,1,Completed,0,true",
            "state,ephemeral,helper,terminated,false,0,odd%2C+pipe%7Cplus%2Btab%09,137,false"
        ].joined(separator: "|")
        let resource = try row(details)
        let pod = try XCTUnwrap(resource.pod)
        XCTAssertEqual(resource.values, ["Running", "True", "pool-07"])
        XCTAssertEqual(pod.qos, "Burstable")
        XCTAssertEqual(pod.node, "pool-07")
        XCTAssertEqual(pod.controllerKind, "ReplicaSet")
        XCTAssertEqual(pod.controllerResource, .replicaSets)
        XCTAssertEqual(pod.controllerName, "workers")
        XCTAssertEqual(pod.controllerUID, "owner-123")
        XCTAssertEqual(pod.containers.map(\.name), ["api", "pending", "setup", "helper"])
        XCTAssertEqual(pod.containers.map(\.role), [.app, .app, .initContainer, .ephemeral])
        XCTAssertEqual(pod.containers.map(\.state), [.running, .waiting, .terminated, .terminated])
        XCTAssertEqual(pod.containers.last?.reason, "odd, pipe|plus+tab\t")
        XCTAssertEqual(pod.containers.last?.exitCode, 137)
        XCTAssertEqual(pod.status, "CrashLoopBackOff")
        XCTAssertTrue(pod.warning?.contains("pending") == true)
        XCTAssertEqual(pod.readyCount, 1)
        XCTAssertEqual(pod.readinessContainerCount, 2)
        XCTAssertEqual(pod.restartCount, 3)
    }

    func testPendingDeclaredContainersAndUnrecognizedOwners() throws {
        let pod = try XCTUnwrap(row("pod,,,|owner,example.com%2Fv1,Job,custom,uid|unscheduled,Unschedulable|spec,app,api,",
                                    phase: "Pending", ready: "").pod)
        XCTAssertEqual(pod.status, "Pending")
        XCTAssertEqual(pod.warning, "Unschedulable")
        XCTAssertEqual(pod.containers.first?.state, .unknown)
        XCTAssertEqual(pod.controllerName, "custom")
        XCTAssertNil(pod.controllerResource)
        XCTAssertNil(pod.qos)
        XCTAssertEqual(pod.restartCount, 0)
        XCTAssertEqual(try row("pod,,,|owner,v1,Node,mirror-node,id").pod?.controllerResource, .nodes)
    }

    func testInitAndSidecarStatesAndTerminatingPods() throws {
        let regular = "|spec,app,api,|spec,init,prepare,"
        let failedInit = "pod,,," + regular + "|state,init,prepare,terminated,false,1,,23,false"
        XCTAssertEqual(try row(failedInit, phase: "Pending").pod?.status, "Init:ExitCode 23")
        XCTAssertEqual(try row("pod,,," + regular, phase: "Pending").pod?.status, "Init:0/1")
        let sidecar = "pod,,,|spec,init,proxy,Always|spec,app,api,|state,init,proxy,running,true,1,,,true"
        XCTAssertEqual(try row(sidecar).pod?.status, "Running")
        XCTAssertEqual(try row(sidecar).pod?.readinessContainerCount, 2)
        XCTAssertEqual(try row(sidecar).pod?.readyCount, 1)
        let restarted = "pod,,,|initialized|spec,init,proxy,Always|state,init,proxy,waiting,false,7,CrashLoopBackOff,,false"
        XCTAssertEqual(try row(restarted).pod?.status, "CrashLoopBackOff")
        let terminating = try XCTUnwrap(row("pod,,timestamp,|spec,app,api,|state,app,api,waiting,false,2,CrashLoopBackOff,,false").pod)
        XCTAssertEqual(terminating.status, "Terminating")
        XCTAssertNil(terminating.warning)
    }

    func testTerminalPhasesOverrideContainerReadiness() throws {
        let detail = "pod,BestEffort,,|spec,app,worker,|state,app,worker,terminated,false,0,Completed,0,true"
        let completed = try XCTUnwrap(row(detail, phase: "Succeeded", ready: "False").pod)
        XCTAssertEqual(completed.status, "Succeeded")
        XCTAssertNil(completed.warning)
        let evicted = try XCTUnwrap(row("pod,Burstable,,Evicted", phase: "Failed", ready: "False").pod)
        XCTAssertEqual(evicted.status, "Evicted")
        XCTAssertNotNil(evicted.warning)
        let debugFailure = "pod,,,|spec,app,api,|spec,ephemeral,debug,|state,ephemeral,debug,terminated,false,0,Error,1,false"
        XCTAssertEqual(try row(debugFailure).pod?.status, "Running")
    }

    func testMalformedPodRecordsRejectWholeList() {
        XCTAssertThrowsError(try row("pod,,,|spec,app"))
        XCTAssertThrowsError(try row("pod,,,|spec,app,%zz,"))
        XCTAssertThrowsError(try row("pod,,,|state,app,api,running,true,-4,,,true"))
    }

    func testInspectorPropertiesPreserveDualStackAddressesAndMetadataKeys() throws {
        let records = ["pod,,,", "ip,10.0.0.8", "ip,10.0.0.8", "ip,fd00%3A%3A8", "account,web-reader",
                       "label,app.kubernetes.io%2Fname,web", "label,empty,",
                       "annotation,kubectl.kubernetes.io%2Flast-applied-configuration"]
        let pod = try XCTUnwrap(row(records.joined(separator: "|")).pod)
        XCTAssertEqual(pod.podIPs, ["10.0.0.8", "fd00::8"])
        XCTAssertEqual(pod.serviceAccount, "web-reader")
        XCTAssertEqual(pod.labels, ["app.kubernetes.io/name": "web", "empty": ""])
        XCTAssertEqual(pod.annotationKeys, ["kubectl.kubernetes.io/last-applied-configuration"])
        let pending = try XCTUnwrap(row("pod,,,", phase: "Pending").pod)
        XCTAssertTrue(pending.podIPs.isEmpty)
        XCTAssertNil(pending.serviceAccount)
    }
}
