import Foundation
import XCTest
@testable import SightportCore

final class SecretDetailsTests: XCTestCase {
    private var directory: URL!
    private var config: URL!
    private var client: KubernetesClient!
    private let row = ResourceRow(id: "secret-uid-1", name: "example", namespace: "sandbox",
                                  createdAt: nil, values: ["Opaque", "4"])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = directory.appendingPathComponent("fixture config")
        try Data().write(to: config)
        let executable = directory.appendingPathComponent("sightport-kube")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$FIXTURE/args"
        if test -f "$FIXTURE/error"; then cat "$FIXTURE/error" >&2; exit 1; fi
        cat "$FIXTURE/output"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        client = KubernetesClient(environment: ["PATH": directory.path, "FIXTURE": directory.path], homeDirectory: directory, sdkExecutable: executable)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func write(_ text: String, to name: String = "output") throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    private var arguments: [String] {
        get throws {
            let text = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
            return text.split(separator: "\n").map(String.init)
        }
    }

    func testSDKListAndDetailProjections() throws {
        let fixture: [String: Any] = [
            "metadata": ["uid": row.id, "name": row.name, "namespace": "sandbox",
                         "resourceVersion": "92", "annotations": ["fixture": "private-annotation"]],
            "type": "Opaque", "data": ["alpha.config": "ZXhhbXBsZQ==", "beta": ""]
        ]
        let list = try renderProjection(ResourceKind.secrets.listTemplate, object: ["items": [fixture]])
        XCTAssertEqual(String(decoding: list, as: UTF8.self), "secret-uid-1\texample\tsandbox\t\tOpaque\t2\t92\n")
        XCTAssertEqual(try ResourceRow.decodeList(list, kind: .secrets).first?.resourceVersion, "92")
        let detail = try renderProjection(SecretDetails.projection, object: fixture)
        XCTAssertEqual(String(decoding: detail, as: UTF8.self), "secret-uid-1\texample\tsandbox\nalpha.config\tZXhhbXBsZQ==\nbeta\t\n")
        XCTAssertEqual(try SecretDetails(output: detail, row: row, namespace: "sandbox").entries.map(\.text), ["example", ""])
    }

    func testDetailFetchIsScopedAndKeepsExactBytes() async throws {
        let text = "demo+value%\t✓\nsecond line\n"
        let encoded = Data(text.utf8).base64EncodedString()
        try write("secret-uid-1\texample\tsandbox\ntext\t\(encoded)\nempty\t\nbinary\tAP8=\ncontrol\tYQBi\n")
        let details = try await client.secretDetails(for: row, in: config, context: "test cluster")
        XCTAssertEqual(try arguments, ["--kubeconfig=" + config.path, "--context=test cluster", "--request-timeout=8s",
                                       "get", "secret/example", "--namespace=sandbox", "-o", "go-template=" + SecretDetails.projection])
        XCTAssertFalse(SecretDetails.projection.contains("annotations"))
        XCTAssertEqual(details.entries.map(\.key), ["binary", "control", "empty", "text"])
        XCTAssertEqual(details.entries.map(\.text), [nil, nil, "", text])
        XCTAssertEqual(details.entries.map(\.byteCount), [2, 3, 0, text.utf8.count])
        XCTAssertEqual(details.entries.map(\.base64), ["AP8=", "YQBi", "", encoded])

        try write("secret-uid-1\texample\tsandbox\n")
        let empty = try await client.secretDetails(for: row, in: config, context: "test cluster")
        XCTAssertTrue(empty.entries.isEmpty)
    }

    func testReplacedOrWrongNamespaceSecretIsDiscarded() async throws {
        for identity in ["replacement\texample\tsandbox", "secret-uid-1\texample\tother", "secret-uid-1\tother\tsandbox"] {
            try write(identity + "\nvalue\tbW9jaw==\n")
            do {
                _ = try await client.secretDetails(for: row, in: config, context: "lab")
                XCTFail("Expected identity mismatch")
            } catch KubernetesError.secretMissing {}
        }
        try write("secret-uid-1\texample\tsandbox\nbad\t%%%\n")
        do {
            _ = try await client.secretDetails(for: row, in: config, context: "lab")
            XCTFail("Expected invalid base64 to fail")
        } catch KubernetesError.secretUnavailable {}
    }

    func testSecretGetAndEventListFailIndependentlyWithSafeErrors() async throws {
        try write("Forbidden: synthetic confidential diagnostic", to: "error")
        do {
            _ = try await client.secretDetails(for: row, in: config, context: "lab")
            XCTFail("Expected get denial")
        } catch KubernetesError.secretDenied {}
        do {
            _ = try await client.secretEvents(for: row, in: config, context: "lab")
            XCTFail("Expected events denial")
        } catch KubernetesError.resourceDenied(.events, "sandbox") {}
        XCTAssertFalse(KubernetesError.secretDenied.localizedDescription.contains("synthetic"))

        try write("NotFound: sample Secret not found", to: "error")
        do {
            _ = try await client.secretDetails(for: row, in: config, context: "lab")
            XCTFail("Expected missing Secret")
        } catch KubernetesError.secretMissing {}
    }

    func testEventsUseTheSelectedUIDAndNamespace() async throws {
        let columns = ["Normal", "Updated", "Secret%2Fexample", "Fixture+event", "", "1", "fixture-controller"]
        try write((["event-1", "secret-event", "sandbox", ""] + columns).joined(separator: "\t") + "\n")
        let events = try await client.secretEvents(for: row, in: config, context: "lab")
        XCTAssertEqual(events.map(\.id), ["event-1"])
        XCTAssertEqual(events.first?.values[3], "Fixture event")
        XCTAssertEqual(try arguments, ["--kubeconfig=" + config.path, "--context=lab", "--request-timeout=8s",
                                       "get", "events.events.k8s.io", "--namespace=sandbox", "--field-selector=regarding.uid=secret-uid-1",
                                       "-o", "go-template=" + ResourceKind.events.listTemplate])
    }
}
