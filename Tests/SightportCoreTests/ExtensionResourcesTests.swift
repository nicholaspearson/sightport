import Foundation
import XCTest
@testable import SightportCore

final class ExtensionResourcesTests: XCTestCase {
    private var directory: URL!
    private var config: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = directory.appendingPathComponent("test config")
        try Data().write(to: config)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func client(_ command: String, script: String) throws -> KubernetesClient {
        let executable = directory.appendingPathComponent(command)
        try ("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ARGS_FILE\"\n" + script)
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return KubernetesClient(environment: ["PATH": directory.path, "ARGS_FILE": directory.appendingPathComponent("args").path,
                                               "HELM_KUBEAPISERVER": "https://ignored.invalid", "HELM_NAMESPACE": "ignored"],
                                homeDirectory: directory, sdkExecutable: executable)
    }

    private var arguments: [String] {
        get throws { try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init) }
    }

    private func definition(_ resource: String = "widgets.example.org", scope: String = "Namespaced",
                            versions: String = "v1beta1, v1") -> CustomResourceType? {
        let data = ["Kind": "Widget", "Group": "example.org", "Scope": scope, "Served Versions": versions]
        let row = ResourceRow(id: "crdUID", name: resource, namespace: nil, createdAt: nil,
                              values: ResourceKind.customResourceDefinitions.columns.map { data[$0] ?? "" })
        return CustomResourceType(definition: row)
    }

    func testOnlyValidServedDefinitionsCanOpen() {
        XCTAssertNil(definition("wrong.api.invalid"))
        XCTAssertNil(definition("--raw.example.org"))
        XCTAssertNil(definition("pods/widgets.example.org"))
        XCTAssertNil(definition(scope: ""))
        XCTAssertNil(definition(versions: ""))
        XCTAssertNil(definition(versions: "v1/other"))
        XCTAssertEqual(definition()?.version, "v1beta1")
    }

    func testCatalogGroupsDefinitionsByAPIGroupAndUsesServedStorageVersion() throws {
        func document(_ group: String, _ plural: String, _ kind: String, scope: String = "Namespaced",
                      storageServed: Bool = true) -> [String: Any] {
            ["metadata": ["name": plural + "." + group], "spec": [
                "group": group, "scope": scope, "names": ["kind": kind, "plural": plural],
                "versions": [["name": "v1beta1", "served": true, "storage": false],
                             ["name": "v1", "served": storageServed, "storage": true]]
            ]]
        }
        let rows = try projectResource(.customResourceDefinitions, items: [
            document("z.example", "widgets", "Widget"),
            document("a.example", "widgets", "Widget", storageServed: false),
            document("a.example", "gadgets", "Gadget", scope: "Cluster")
        ])
        let catalog = CustomResourceGroup.catalog(from: rows)
        XCTAssertEqual(catalog.map(\.name), ["a.example", "z.example"])
        XCTAssertEqual(catalog[0].types.map(\.kind), ["Gadget", "Widget"])
        XCTAssertEqual(catalog[0].types.map(\.isNamespaced), [false, true])
        XCTAssertEqual(catalog[0].types.map(\.version), ["v1", "v1beta1"])
        XCTAssertEqual(catalog[1].types.first?.versionedName, "widgets.v1.z.example")
        XCTAssertEqual(CustomResourceGroup.catalog(from: [rows[0]]).map(\.name), ["z.example"])
    }

    func testCatalogSkipsInvalidAndUnestablishedTypesAndPrefersNewestIncarnation() {
        func row(_ id: String, _ name: String, _ kind: String, timestamp: TimeInterval, established: String = "True") -> ResourceRow {
            let fields = ["Kind": kind, "Group": "example.org", "Scope": "Namespaced", "Served Versions": "v1",
                          "Established": established, "Storage Version": "v1"]
            return ResourceRow(id: id, name: name, namespace: nil, createdAt: Date(timeIntervalSince1970: timestamp),
                               values: ResourceKind.customResourceDefinitions.columns.map { fields[$0] ?? "" })
        }
        let old = row("old", "workers.example.org", "OldWorker", timestamp: 100)
        let new = row("new", "workers.example.org", "Worker", timestamp: 200)
        let invalid = row("invalid", "other.example.org", "Malformed\nKind", timestamp: 300)
        let pending = row("pending", "jobs.example.org", "Job", timestamp: 400, established: "False")
        let catalog = CustomResourceGroup.catalog(from: [new, invalid, pending, old])
        XCTAssertEqual(catalog.flatMap(\.types).map(\.kind), ["Worker"])
        XCTAssertTrue(CustomResourceGroup.catalog(from: []).isEmpty)
    }

    func testQueriesSelectedServedVersionAndCorrectScope() async throws {
        let stub = #"printf 'id-1\twidget\tdev\t2026-11-25T10:00:00Z\texample.org%%2Fv1beta1\t3\tRunning\tJob%%2Fcontroller\n'"#
        let client = try client("sightport-kube", script: stub)
        let type = try XCTUnwrap(definition())
        let rows = try await client.customResources(type, in: config, context: "Team Alpha", namespace: "dev")
        XCTAssertEqual(try arguments.prefix(5), ["--kubeconfig=" + config.path, "--context=Team Alpha",
                                                  "--request-timeout=8s", "get", "widgets.v1beta1.example.org"])
        XCTAssertTrue(try arguments.contains("--namespace=dev"))
        XCTAssertTrue(try arguments.contains("--api-version=v1beta1"))
        XCTAssertEqual(rows.first?.values, ["example.org/v1beta1", "3", "Running", "Job/controller"])
        XCTAssertEqual(rows.first?.id, "id-1")
        _ = try await client.customResources(type, in: config, context: "Team Alpha", namespace: nil)
        XCTAssertTrue(try arguments.contains("--all-namespaces"))
        let cluster = try XCTUnwrap(definition(scope: "Cluster"))
        _ = try await client.customResources(cluster, in: config, context: "Team Alpha", namespace: "ignored")
        XCTAssertFalse(try arguments.contains { $0.hasPrefix("--namespace") || $0 == "--all-namespaces" })
    }

    func testHelmReleaseIdentityAndScope() async throws {
        let sample = #"[{"name":"app","namespace":"dev","status":"pending-install","chart":"web-1.0","revision":"8","app_version":"a","updated":"today"},{"name":"app","namespace":"test","status":"failed","chart":"web-1.1","revision":"1","app_version":"b","updated":"yesterday"}]"#
        let stub = "test -z \"$HELM_KUBEAPISERVER$HELM_NAMESPACE\" || exit 1\nprintf '%s' '" + sample + "'"
        let cli = try client("helm", script: stub)
        let rows = try await cli.helmReleases(in: config, context: "East", namespace: nil)
        XCTAssertEqual(rows.map(\.id), ["dev/app", "test/app"])
        XCTAssertEqual(rows.first?.values, ["pending-install", "web-1.0", "a", "8", "today"])
        XCTAssertTrue(try arguments.contains("--all-namespaces"))
        XCTAssertTrue(try arguments.contains("--kube-context=East"))
        XCTAssertTrue(try arguments.contains("--kubeconfig=" + config.path))
        XCTAssertTrue(try arguments.contains("--max=\(Int32.max)"))
        _ = try await cli.helmReleases(in: config, context: "West", namespace: "dev")
        XCTAssertTrue(try arguments.contains("--namespace=dev"))
        XCTAssertTrue(try arguments.contains("--kube-context=West"))
        XCTAssertFalse(try arguments.contains("--all-namespaces"))
    }

    func testHelmAndCustomResourcePermissionErrorsHideRawOutput() async throws {
        let script = "echo 'Forbidden private-marker' >&2\nexit 1"
        let helm = try client("helm", script: script)
        do {
            _ = try await helm.helmReleases(in: config, context: "example", namespace: nil)
            XCTFail("Expected a Helm permission error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Helm releases"))
            XCTAssertFalse(error.localizedDescription.contains("private-marker"))
        }
        let kube = try client("sightport-kube", script: script)
        let type = try XCTUnwrap(definition())
        do {
            _ = try await kube.customResources(type, in: config, context: "example", namespace: nil)
            XCTFail("Expected a custom resource permission error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(type.resourceName))
            XCTAssertFalse(error.localizedDescription.contains("private-marker"))
        }
    }

    func testOversizeReleaseOutputReportsLimitWithoutReturningPartialData() async throws {
        let helm = try client("helm", script: "exec /bin/dd if=/dev/zero bs=65536 count=65 2>/dev/null")
        do {
            _ = try await helm.helmReleases(in: config, context: "example", namespace: nil)
            XCTFail("Expected an output limit error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("4 MiB"))
        }
    }
}
