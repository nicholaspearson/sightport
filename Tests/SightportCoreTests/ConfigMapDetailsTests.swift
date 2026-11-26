import Foundation
import XCTest
@testable import SightportCore

final class ConfigMapDetailsTests: XCTestCase {
    private let row = ResourceRow(id: "map-uid", name: "app-config", namespace: "sandbox", createdAt: nil, values: [])
    private let header = "map-uid\tapp-config\tsandbox\n"

    func testSDKProjectionPreservesMetadataTextAndBinary() throws {
        let content = "---\r\nvalue: \"a + b%\"\n\t✓\u{0}e\u{301}\n\n"
        let bytes = Data([0, 64, 255, 12])
        let object: [String: Any] = [
            "metadata": [
                "uid": row.id, "name": row.name, "namespace": "sandbox",
                "resourceVersion": "73",
                "labels": ["app.example.org/component": "worker"],
                "annotations": ["example.org/description": content],
                "managedFields": [["manager": "unrequested-metadata"]]
            ],
            "data": ["app.yaml": content, "blank.txt": ""],
            "binaryData": ["asset.bin": bytes.base64EncodedString(), "empty.bin": ""]
        ]
        let list = try renderProjection(ResourceKind.configMaps.listTemplate, object: ["items": [object]])
        XCTAssertEqual(String(decoding: list, as: UTF8.self), "map-uid\tapp-config\tsandbox\t\t2\t2\t73\n")
        XCTAssertEqual(try ResourceRow.decodeList(list, kind: .configMaps).first?.resourceVersion, "73")

        let output = try renderProjection(ConfigMapDetails.projection, object: object)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("unrequested-metadata"))
        let details = try ConfigMapDetails(output: output, row: row, namespace: "sandbox")
        XCTAssertEqual(details.labels, ["app.example.org/component": "worker"])
        XCTAssertEqual(details.annotations, ["example.org/description": content])
        XCTAssertEqual(details.data["app.yaml"].map { Data($0.utf8) }, Data(content.utf8))
        XCTAssertEqual(details.data["blank.txt"], "")
        XCTAssertEqual(details.binaryData, ["asset.bin": bytes, "empty.bin": Data()])
    }

    func testAbsentPropertiesAndReplacedObjects() throws {
        let fixture: [String: Any] = ["metadata": ["uid": row.id, "name": row.name, "namespace": "sandbox"]]
        let output = try renderProjection(ConfigMapDetails.projection, object: fixture)
        let empty = try ConfigMapDetails(output: output, row: row, namespace: "sandbox")
        XCTAssertTrue(empty.labels.isEmpty && empty.annotations.isEmpty && empty.data.isEmpty && empty.binaryData.isEmpty)
        for identity in ["replaced\tapp-config\tsandbox", "map-uid\tapp-config\tother", "map-uid\tother\tsandbox"] {
            do {
                _ = try ConfigMapDetails(output: Data((identity + "\nD\tdata.yaml\tfixture\n").utf8), row: row, namespace: "sandbox")
                XCTFail("Expected the mismatched identity to be rejected")
            } catch KubernetesError.configMapMissing {}
        }
        XCTAssertThrowsError(try ConfigMapDetails(output: Data((header + "B\tasset\t%%%\n").utf8), row: row, namespace: "sandbox"))
    }

    func testFetchUsesTheExactKubeconfigNamespaceNameAndContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("fixture config")
        try Data().write(to: config)
        let fixture = directory.appendingPathComponent("sightport-kube")
        try #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$TEST_DIR/args"
        printf 'map-uid\tapp-config\tsandbox\nD\tkey\tvalue\n'
        """#.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        let client = KubernetesClient(environment: ["PATH": directory.path, "TEST_DIR": directory.path], homeDirectory: directory, sdkExecutable: fixture)
        let result = try await client.configMapDetails(for: row, in: config, context: "selected context")
        XCTAssertEqual(result.data, ["key": "value"])
        let args = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(args.split(separator: "\n").map(String.init),
                       ["--kubeconfig=" + config.path, "--context=selected context", "--request-timeout=8s",
                        "get", "configmap/app-config", "--namespace=sandbox", "-o", "go-template=" + ConfigMapDetails.projection])
    }

    func testFailedGetsDoNotIncludeSDKDiagnostics() {
        for (diagnostic, error) in [("Forbidden", KubernetesError.configMapDenied), ("NotFound", .configMapMissing), ("other", .configMapUnavailable)] {
            let stderr = Data((diagnostic + " fixture-private-value").utf8)
            let result = KubernetesError.failure(stderr: stderr, operation: .configMapDetails)
            XCTAssertEqual(result.localizedDescription, error.localizedDescription)
            XCTAssertFalse(result.localizedDescription.contains("fixture-private-value"))
        }
    }
}
