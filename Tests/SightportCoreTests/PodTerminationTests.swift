import Foundation
import XCTest
@testable import SightportCore

final class PodTerminationTests: XCTestCase {
    private var dir: URL!
    private var file: URL!
    private let row = ResourceRow(id: "selected-uid", name: "web-0", namespace: "sandbox", createdAt: nil, values: [])

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("selected config")
        try Data().write(to: file)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    func testPassesOnlyTheConfirmedIdentityToOneHelperProcess() async throws {
        let client = try fixture(#"printf '%s\n' "$@" >> "$DIR/args""#)
        try await client.terminatePod(row, in: file, context: "my context")
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(args.split(separator: "\n").map(String.init),
                       ["--kubeconfig=" + file.path, "--context=my context", "--request-timeout=8s", "terminate-pod",
                        "web-0", "--namespace=sandbox", "--uid=selected-uid"])
    }

    func testMissingUIDCannotStartADeletion() async throws {
        let client = try fixture(#": > "$DIR/called""#)
        for uid in ["", "sandbox/web-0"] {
            let invalid = ResourceRow(id: uid, name: row.name, namespace: row.namespace, createdAt: nil, values: [])
            do {
                try await client.terminatePod(invalid, in: file, context: "selected")
                XCTFail("Expected an invalid pod identity")
            } catch KubernetesError.podIdentityMissing {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("called").path))
    }

    func testMapsPodDeletionFailuresWithoutRepeatingTheMutation() async throws {
        let client = try fixture(#"""
            echo called >> "$DIR/calls"
            echo "private credential plugin diagnostic" >&2
            /bin/cat "$DIR/failure" >&2
            exit 1
            """#)
        let cases: [(String, KubernetesError)] = [
            ("pod-delete-forbidden", .podTerminationDenied), ("pod-delete-conflict", .podTerminationConflict),
            ("pod-delete-not-found", .podTerminationMissing), ("pod-delete-unconfirmed", .podTerminationUnconfirmed),
            ("unexpected connection error", .podTerminationUnconfirmed)
        ]
        for (message, expected) in cases {
            try message.write(to: dir.appendingPathComponent("failure"), atomically: true, encoding: .utf8)
            do {
                try await client.terminatePod(row, in: file, context: "selected")
                XCTFail("Expected deletion to fail")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
            }
        }
        let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n").count, cases.count)
    }

    func testHelperTimeoutLeavesTheOutcomeUnconfirmed() async throws {
        let client = try fixture("exec /bin/sleep 5", timeout: 0.15)
        do {
            try await client.terminatePod(row, in: file, context: "selected")
            XCTFail("Expected a timeout")
        } catch KubernetesError.podTerminationUnconfirmed {}
    }

    private func fixture(_ script: String, timeout: TimeInterval = 5) throws -> KubernetesClient {
        let executable = dir.appendingPathComponent("sightport-kube")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return KubernetesClient(environment: ["DIR": dir.path], homeDirectory: dir, timeout: timeout, sdkExecutable: executable)
    }
}
