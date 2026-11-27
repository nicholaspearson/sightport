import Darwin
import Foundation
import XCTest
@testable import SightportCore

final class PortForwardTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("config with spaces")
        try Data().write(to: file)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testServiceForwardReportsAssignedPortAndStopsChild() throws {
        let client = try fixture(#"""
        echo "$$" > "$FIXTURE/pid"
        printf '%s\n' "$@" > "$FIXTURE/args"
        printf 'Forwarding from 127.0.'
        printf '0.1:41235 -> 8080\n'
        exec /bin/sleep 60
        """#)
        let request = try PortForwardRequest(kind: .service, namespace: "blue", name: "front-end",
                                             localPort: "", remotePort: "http")
        let ready = expectation(description: "Assigned local port")
        let closed = expectation(description: "Forward stopped")
        let session = try client.openPortForward(in: file, context: "developer; one", request: request) { status in
            switch status {
            case .listening(41235): ready.fulfill()
            case .stopped: closed.fulfill()
            default: XCTFail("Unexpected status \(status)")
            }
        }
        defer { session.stop() }
        wait(for: [ready], timeout: 3)
        let args = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(args.split(separator: "\n").map(String.init), [
            "--kubeconfig=" + file.path, "--context=developer; one", "--namespace=blue",
            "port-forward", "--address=127.0.0.1", "service/front-end", ":http"
        ])
        let pid = try XCTUnwrap(Int32(try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        session.stop()
        session.stop()
        wait(for: [closed], timeout: 3)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOccupiedPortGivesActionableFailureAndHidesRawOutput() throws {
        let client = try fixture("echo 'helper-private-output: bind: address already in use' >&2\nexit 1")
        let request = try PortForwardRequest(kind: .pod, namespace: "default", name: "worker-0",
                                             localPort: "8080", remotePort: "8081")
        let failed = expectation(description: "Port conflict")
        let session = try client.openPortForward(in: file, context: "local", request: request) { status in
            if case .failed(let message) = status {
                XCTAssertTrue(message.contains("already in use"))
                XCTAssertFalse(message.contains("helper-private"))
                failed.fulfill()
            }
        }
        defer { session.stop() }
        wait(for: [failed], timeout: 3)
    }

    func testForwardFromPodInspectorPinsNamespaceNameAndUID() throws {
        let row = ResourceRow(id: "selected-uid", name: "argocd-server-abc", namespace: "gitops", createdAt: nil, values: [])
        let request = try PortForwardRequest(pod: row, localPort: "", remotePort: "8080")
        let client = try fixture(#"""
        printf '%s\n' "$@" > "$FIXTURE/args"
        echo 'selected pod changed' >&2
        exit 1
        """#)
        let failed = expectation(description: "Replaced pod")
        let session = try client.openPortForward(in: file, context: "development", request: request) { status in
            guard case .failed(let message) = status else { return }
            XCTAssertTrue(message.contains("replaced"))
            failed.fulfill()
        }
        defer { session.stop() }
        wait(for: [failed], timeout: 3)
        let args = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(args.split(separator: "\n").map(String.init), [
            "--kubeconfig=" + file.path, "--context=development", "--namespace=gitops",
            "port-forward", "--address=127.0.0.1", "--uid=selected-uid", "pod/argocd-server-abc", ":8080"
        ])
    }

    func testValidatesPortsAndMandatoryTargetScope() {
        for (namespace, name, local, remote) in [
            ("", "api", "", "80"), ("default", "svc/name", "8080", "80"),
            ("red", "api", "0", "80"), ("red", "api", "65536", "80"),
            ("red", "api", "", "0"), ("red", "api", "", "65536"),
            ("red", "api", "", "--port"), ("red", "api", "", "1:2")
        ] {
            XCTAssertThrowsError(try PortForwardRequest(kind: .pod, namespace: namespace, name: name,
                                                       localPort: local, remotePort: remote))
        }
    }

    private func fixture(_ script: String) throws -> KubernetesClient {
        let executable = directory.appendingPathComponent("sightport-kube")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return KubernetesClient(environment: ["PATH": directory.path, "FIXTURE": directory.path], homeDirectory: directory, sdkExecutable: executable)
    }
}
