import Foundation
import XCTest
@testable import SightportCore

final class ResourceTests: XCTestCase {
    private var directory: URL!
    private var config: URL!
    private var client: KubernetesClient!
    private var argumentFile: URL { directory.appendingPathComponent("args") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = directory.appendingPathComponent("cluster config")
        try Data().write(to: config)
        let executable = directory.appendingPathComponent("kubectl")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$FIXTURE/args"
        if [ -f "$FIXTURE/error" ]; then
          /bin/cat "$FIXTURE/error" >&2
          exit 1
        fi
        /bin/cat "$FIXTURE/output"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        client = KubernetesClient(environment: ["PATH": directory.path, "FIXTURE": directory.path], homeDirectory: directory)
        try Data().write(to: directory.appendingPathComponent("output"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testEveryKindIssuesScopedReadWithMatchingProjectedColumns() async throws {
        for kind in ResourceKind.allCases {
            let rows = try await client.resources(kind, in: config, context: "fixture ctx", namespace: "blue")
            XCTAssertTrue(rows.isEmpty)
            let arguments = try String(contentsOf: argumentFile, encoding: .utf8).components(separatedBy: "\n")
            XCTAssertTrue(arguments.contains("--kubeconfig=" + config.path))
            XCTAssertTrue(arguments.contains("--context=fixture ctx"))
            XCTAssertEqual(arguments[3], "get")
            XCTAssertEqual(arguments[4], kind.resourceName)
            if let selector = kind.argoLabelSelector {
                XCTAssertTrue(arguments.contains("--selector=" + selector))
            }
            XCTAssertEqual(arguments.contains("--namespace=blue"), kind.isNamespaced)
            XCTAssertFalse(arguments.contains("--all-namespaces"))
            XCTAssertEqual(kind.listTemplate.components(separatedBy: #"{{"\t"}}"#).count,
                           4 + kind.columns.count + (kind == .pods ? 1 : 0))
        }
        _ = try await client.resources(.pods, in: config, context: "fixture ctx")
        let allNamespaces = try String(contentsOf: argumentFile, encoding: .utf8)
        XCTAssertTrue(allNamespaces.contains("\n--all-namespaces\n"))
        _ = try await client.resources(.nodes, in: config, context: "fixture ctx")
        let cluster = try String(contentsOf: argumentFile, encoding: .utf8)
        XCTAssertFalse(cluster.contains("--all-namespaces"))
    }

    func testPodUsageScopesAndJoinsSameNamedPodsAcrossNamespaces() async throws {
        let output = directory.appendingPathComponent("output")
        try "blue  worker    12m   54Mi\nred  worker  0m    0Mi\n".write(to: output, atomically: true, encoding: .utf8)
        let usage = try await client.podMetrics(in: config, context: "team alpha", namespace: nil)
        XCTAssertEqual(usage[PodKey(namespace: "blue", name: "worker")], PodUsage(cpuMillicores: 12, memoryBytes: 54 * 1_048_576))
        XCTAssertEqual(usage[PodKey(namespace: "red", name: "worker")], PodUsage(cpuMillicores: 0, memoryBytes: 0))
        XCTAssertNil(usage[PodKey(namespace: "red", name: "job")])
        let allArguments = try String(contentsOf: argumentFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(allArguments, ["--kubeconfig=\(config.path)", "--context=team alpha", "--request-timeout=8s",
                                      "top", "pods", "--all-namespaces", "--no-headers"])

        try "worker    1042m   1025Mi\n".write(to: output, atomically: true, encoding: .utf8)
        let scoped = try await client.podMetrics(in: config, context: "team alpha", namespace: "blue")
        XCTAssertEqual(scoped, [PodKey(namespace: "blue", name: "worker"): PodUsage(cpuMillicores: 1042, memoryBytes: 1025 * 1_048_576)])
        let arguments = try String(contentsOf: argumentFile, encoding: .utf8)
        XCTAssertTrue(arguments.contains("\n--namespace=blue\n"))
        XCTAssertFalse(arguments.contains("--all-namespaces"))
        XCTAssertTrue(try PodUsage.decodeTable(Data(), namespace: nil).isEmpty)
        XCTAssertThrowsError(try PodUsage.decodeTable(Data("worker  1m  9223372036854775807Mi".utf8), namespace: "blue"))
    }

    func testPodLogsTargetOneContainerWithBoundedCurrentOrPreviousOutput() async throws {
        let output = directory.appendingPathComponent("output")
        let log = "starting\nready\n"
        try log.write(to: output, atomically: true, encoding: .utf8)
        for previous in [true, false] {
            let contents = try await client.podLogs(in: config, context: "team alpha", namespace: "blue",
                                                    pod: "worker-0", container: "worker", previous: previous)
            XCTAssertEqual(contents, log)
            let arguments = try String(contentsOf: argumentFile, encoding: .utf8).split(separator: "\n").map(String.init)
            let base = ["--kubeconfig=\(config.path)", "--context=team alpha", "--request-timeout=8s", "logs", "pod/worker-0",
                        "--namespace=blue", "--container=worker", "--tail=200", "--limit-bytes=262144"]
            XCTAssertEqual(arguments, base + (previous ? ["--previous"] : []))
        }
        try Data(repeating: 65, count: 300_000).write(to: output)
        let limited = try await client.podLogs(in: config, context: "team alpha", namespace: "blue",
                                               pod: "worker-0", container: "worker", previous: false)
        XCTAssertEqual(limited.utf8.count, 262_144)
    }

    func testPodSubresourceErrorsAreSpecificAndHideRawStderr() async throws {
        let errorFile = directory.appendingPathComponent("error")
        try "error: Metrics API not available".write(to: errorFile, atomically: true, encoding: .utf8)
        do {
            _ = try await client.podMetrics(in: config, context: "fixture", namespace: nil)
            XCTFail("Expected missing metrics API")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Metrics API"))
        }
        for (message, expected) in [("Forbidden: private detail", "permission"),
                                    ("previous terminated container worker in pod worker-0 not found: private detail", "previous instance")] {
            try message.write(to: errorFile, atomically: true, encoding: .utf8)
            do {
                _ = try await client.podLogs(in: config, context: "fixture", namespace: "blue",
                                             pod: "worker-0", container: "worker", previous: true)
                XCTFail("Expected log error")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected))
                XCTAssertFalse(error.localizedDescription.contains("private detail"))
            }
        }
    }

    func testCountUsesCompactProjectionAndRejectsMalformedCounts() async throws {
        let output = directory.appendingPathComponent("output")
        try Data("12\n".utf8).write(to: output)
        let count = try await client.resourceCount(.jobs, in: config, context: "fixture", namespace: "blue")
        XCTAssertEqual(count, 12)
        let arguments = try String(contentsOf: argumentFile, encoding: .utf8)
        XCTAssertTrue(arguments.contains("go-template={{len .items}}"))
        XCTAssertTrue(arguments.contains("--namespace=blue"))
        try Data("-1".utf8).write(to: output)
        do {
            _ = try await client.resourceCount(.jobs, in: config, context: "fixture")
            XCTFail("Expected invalid count")
        } catch {
            XCTAssertTrue(error is ResourceReadError)
        }
    }

    func testProjectedRowsDecodeEscapesOptionalDataAndIdentity() async throws {
        let output = "abc-1\tcontrol\tblue\t2026-11-25T12%3A34%3A56Z\tunit%2Btwo%09items+here\t42\t\n"
            + "\tcontrol\tred\t2026-11-25T12%3A34%3A56.123Z\t\t\t\n"
        try output.write(to: directory.appendingPathComponent("output"), atomically: true, encoding: .utf8)
        let rows = try await client.resources(.leases, in: config, context: "fixture ctx")
        XCTAssertEqual(rows.map(\.id), ["abc-1", "red/control"])
        XCTAssertEqual(rows.map(\.namespace), ["blue", "red"])
        XCTAssertEqual(rows[0].values, ["unit+two\titems here", "42", ""])
        XCTAssertEqual(rows[1].values, ["", "", ""])
        XCTAssertNotNil(rows[0].createdAt)
        XCTAssertNotNil(rows[1].createdAt)
        XCTAssertThrowsError(try ResourceRow.decodeList(Data("bad\trow\n".utf8), kind: .namespaces))
    }

    func testSecretAndConfigMapProjectionsReturnOnlyTypesAndCounts() {
        XCTAssertTrue(ResourceKind.secrets.listTemplate.contains("{{with .data}}{{len .}}{{else}}0{{end}}"))
        for kind in [ResourceKind.secrets, .configMaps] {
            XCTAssertFalse(kind.listTemplate.contains("{{urlquery .data"))
            XCTAssertFalse(kind.listTemplate.contains(".stringData"))
            XCTAssertFalse(kind.listTemplate.contains(".annotations"))
        }
        XCTAssertEqual(ResourceKind.secrets.columns, ["Type", "Keys"])
        XCTAssertEqual(ResourceKind.configMaps.columns, ["Text keys", "Binary keys"])
    }

    func testResourceErrorsKeepScopeAndOmitPluginOutput() async throws {
        let errorFile = directory.appendingPathComponent("error")
        try "Error from server (Forbidden): sensitive-helper-message".write(to: errorFile, atomically: true, encoding: .utf8)
        do {
            _ = try await client.resources(.pods, in: config, context: "limited", namespace: "blue")
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pods"))
            XCTAssertTrue(error.localizedDescription.contains("blue"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-helper-message"))
        }
        try "error: the server doesn't have a resource type \"leases\"".write(to: errorFile, atomically: true, encoding: .utf8)
        do {
            _ = try await client.resources(.leases, in: config, context: "limited")
            XCTFail("Expected unsupported resource")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This cluster does not serve leases.")
        }
    }
}
