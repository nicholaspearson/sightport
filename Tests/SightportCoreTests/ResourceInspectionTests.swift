import Foundation
import XCTest
@testable import SightportCore

final class ResourceInspectionTests: XCTestCase {
    func testNodeTableProjectsAddressTypesAndWatchesAddressChanges() throws {
        let kind = ResourceKind.nodes
        let internalIP = try XCTUnwrap(kind.columns.firstIndex(of: "Internal IP"))
        let externalIP = try XCTUnwrap(kind.columns.firstIndex(of: "External IP"))
        let metadata = ["name": "worker", "uid": "worker-id", "resourceVersion": "7"]
        let addresses = [["type": "Hostname", "address": "worker.test"],
                         ["type": "ExternalIP", "address": "203.0.113.9"],
                         ["type": "InternalIP", "address": "192.0.2.10"],
                         ["type": "InternalIP", "address": "2001:db8::10"]]
        let rows = try projectResource(kind, items: [
            ["metadata": metadata, "status": ["addresses": addresses]],
            ["metadata": ["name": "pending"]]
        ])
        XCTAssertEqual(rows[0].values[internalIP], "192.0.2.10, 2001:db8::10")
        XCTAssertEqual(rows[0].values[externalIP], "203.0.113.9")
        XCTAssertEqual(rows[1].values[internalIP], "")
        XCTAssertEqual(rows[1].values[externalIP], "")

        let target = ResourceWatchTarget.resource(kind)
        let event: [String: Any] = ["type": "MODIFIED", "object": [
            "metadata": metadata, "status": ["addresses": [["type": "InternalIP", "address": "192.0.2.12"]]]
        ]]
        let update = try renderProjection(target.watchTemplate, object: event)
        let fields = String(decoding: update, as: UTF8.self).dropLast().split(separator: "\u{1f}", maxSplits: 1)
        let changed = try ResourceRowDecoder(target).decode(Data(try XCTUnwrap(fields.last).utf8), separator: "\u{1f}")
        XCTAssertEqual(changed.id, rows[0].id)
        XCTAssertEqual(changed.values[internalIP], "192.0.2.12")
        XCTAssertEqual(changed.values[externalIP], "")
    }

    func testNodeAndServiceAccountWatchChangesInvalidateDetails() throws {
        for kind in [ResourceKind.nodes, .serviceAccounts] {
            let target = ResourceWatchTarget.resource(kind)
            for version in ["7", "8"] {
                let object = ["metadata": ["name": "sample", "uid": "selected", "resourceVersion": version,
                                          "annotations": ["eks.amazonaws.com/role-arn": "private-account-annotation"]]]
                let rendered = try renderProjection(target.watchTemplate, object: ["type": "MODIFIED", "object": object])
                let line = String(decoding: rendered, as: UTF8.self).dropLast()
                let rowData = try XCTUnwrap(line.split(separator: "\u{1f}", maxSplits: 1).last)
                let row = try ResourceRowDecoder(target).decode(Data(rowData.utf8), separator: "\u{1f}")
                XCTAssertEqual(row.resourceVersion, version)
                XCTAssertFalse(line.contains("private-account-annotation"))
            }
        }
    }

    func testServiceAccountReadAndManifestKeepSelectedContextNamespaceAndUID() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        try Data().write(to: file)
        let helper = dir.appendingPathComponent("helper")
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$FIXTURE/args"
        /bin/cat "$FIXTURE/output"
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let client = KubernetesClient(environment: ["FIXTURE": dir.path], homeDirectory: dir, sdkExecutable: helper)
        let context = ContextID(file: file, name: "selected context")
        let row = ResourceRow(id: "selected-uid", name: "sample", namespace: "team-a", createdAt: nil, values: [])
        let fixtureOutput = dir.appendingPathComponent("output")
        let recorded = dir.appendingPathComponent("args")
        try #"{"eks.amazonaws.com/role-arn":"arn:example"}"#.write(to: fixtureOutput, atomically: true, encoding: .utf8)
        let annotations = try await client.serviceAccountAnnotations(row, context: context)
        XCTAssertEqual(annotations, ["eks.amazonaws.com/role-arn": "arn:example"])
        var args = try String(contentsOf: recorded, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(Array(args.dropLast()), ["--kubeconfig=" + file.path, "--context=selected context", "--request-timeout=8s",
                                               "inspect-resource", "serviceaccounts/sample", "--uid=selected-uid", "-o", "details", "--namespace=team-a"])
        try "kind: Pod\n".write(to: fixtureOutput, atomically: true, encoding: .utf8)
        let manifest = try await client.manifest(for: .pod, row: row, context: context)
        XCTAssertEqual(manifest, "kind: Pod\n")
        args = try String(contentsOf: recorded, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertTrue(args.contains("pods/sample"))
        XCTAssertTrue(args.contains("yaml"))
        try FileManager.default.removeItem(at: recorded)
        do {
            try await client.perform(.delete, on: row, context: context)
            XCTFail("A namespaced selection must not start node deletion")
        } catch KubernetesError.inspection(.invalid) { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.path))
    }
}
