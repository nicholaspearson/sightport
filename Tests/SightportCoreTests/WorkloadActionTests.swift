import Foundation
import XCTest
@testable import SightportCore

final class WorkloadActionTests: XCTestCase {
    func testSupportedKinds() {
        XCTAssertEqual(ResourceKind.allCases.filter { WorkloadAction(kind: $0) != nil },
                       [.deployments, .daemonSets, .statefulSets, .jobs, .cronJobs])
    }

    func testActionNamesAndCredentialsScope() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("example config")
        let sdk = dir.appendingPathComponent("sightport-kube")
        try Data().write(to: file)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$ARGS"
        case "$4" in
        restart-workload) printf OnDelete ;;
        start-job) printf backup-run-abcde ;;
        resume-job) exit 0 ;;
        *) exit 1 ;;
        esac
        """#
        try script.write(to: sdk, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sdk.path)
        let args = dir.appendingPathComponent("args")
        let client = KubernetesClient(environment: ["ARGS": args.path], homeDirectory: dir, sdkExecutable: sdk)
        let row = ResourceRow(id: "verified-uid", name: "backup", namespace: "work", createdAt: nil, values: [])
        for (kind, action, command) in [(ResourceKind.cronJobs, WorkloadAction.startJob, "start-job"),
                                         (.jobs, .rerunJob, "start-job"), (.statefulSets, .restart, "restart-workload")] {
            let message = try await client.performWorkloadAction(action, kind: kind, row: row, in: file, context: "my context")
            XCTAssertEqual(try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init),
                           ["--kubeconfig=" + file.path, "--context=my context", "--request-timeout=8s", command,
                            kind.rawValue.lowercased(), "backup", "--namespace=work", "--uid=verified-uid"])
            XCTAssertTrue(message.contains(action == .restart ? "OnDelete" : "work/backup-run-abcde"))
        }
        let suspended = try XCTUnwrap(projectResource(.jobs, items: [
            ["metadata": ["uid": row.id, "name": row.name, "namespace": "work"], "spec": ["suspend": true]]
        ]).first)
        XCTAssertEqual(WorkloadAction(kind: .jobs, row: suspended), .resumeJob)
        let message = try await client.performWorkloadAction(.resumeJob, kind: .jobs, row: suspended, in: file, context: "my context")
        XCTAssertEqual(message, "Start requested for Job work/backup.")
        XCTAssertTrue(try String(contentsOf: args, encoding: .utf8).contains("\nresume-job\njobs\nbackup\n"))
        try FileManager.default.removeItem(at: args)
        do {
            _ = try await client.performWorkloadAction(.startJob, kind: .deployments, row: row, in: file, context: "my context")
            XCTFail("Expected mismatched action to fail")
        } catch KubernetesError.workloadAction(.invalid) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: args.path))
    }

    func testFailureUsesOnlyFinalSDKDiagnostic() {
        for failure in [WorkloadFailure.changed, .paused, .manualSelector, .rejected, .unconfirmed] {
            let stderr = Data(("private plugin message forbidden\n" + failure.rawValue + "\n").utf8)
            XCTAssertEqual(KubernetesError.failure(stderr: stderr, operation: .workloadAction).localizedDescription, failure.description)
        }
    }
}
