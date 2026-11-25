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
                                homeDirectory: directory)
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

    func testQueriesSelectedServedVersionAndCorrectScope() async throws {
        let stub = #"printf 'id-1\twidget\tdev\t2026-11-25T10:00:00Z\texample.org%%2Fv1beta1\t3\tRunning\tJob%%2Fcontroller\n'"#
        let client = try client("kubectl", script: stub)
        let type = try XCTUnwrap(definition())
        let rows = try await client.customResources(type, in: config, context: "Team Alpha", namespace: "dev")
        XCTAssertEqual(try arguments.prefix(5), ["--kubeconfig=" + config.path, "--context=Team Alpha",
                                                  "--request-timeout=8s", "get", "widgets.v1beta1.example.org"])
        XCTAssertTrue(try arguments.contains("--namespace=dev"))
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
        let kube = try client("kubectl", script: script)
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
