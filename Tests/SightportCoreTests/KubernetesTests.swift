import Foundation
import XCTest
@testable import SightportCore

final class KubernetesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testDiscoversDefaultAndExplicitKubeconfigs() throws {
        let kubeFolder = folder.appendingPathComponent(".kube")
        try FileManager.default.createDirectory(at: kubeFolder, withIntermediateDirectories: true)
        let config = kubeFolder.appendingPathComponent("config")
        let other = folder.appendingPathComponent("other config")
        try Data().write(to: config)
        try Data().write(to: other)
        let link = folder.appendingPathComponent("linked config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)

        XCTAssertEqual(KubernetesClient(environment: [:], homeDirectory: folder).defaultSources(), [config])
        let paths = [other.path, "~/missing", config.path, link.path, folder.path].joined(separator: ":")
        XCTAssertEqual(KubernetesClient(environment: ["KUBECONFIG": paths], homeDirectory: folder).defaultSources(),
                       [other, config])
    }

    func testReadsRealKubeconfigLocallyIncludingCurrentContextAndNamespace() async throws {
        let available = ["/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/kubectl" }
        try XCTSkipUnless(available.contains(where: FileManager.default.isExecutableFile(atPath:)), "kubectl is unavailable")
        let marker = folder.appendingPathComponent("helper-ran")
        let config = folder.appendingPathComponent("fixture.yaml")
        let file = """
        apiVersion: v1
        kind: Config
        current-context: team alpha
        clusters:
        - name: cluster-one
          cluster:
            server: https://127.0.0.1:1
        contexts:
        - name: team alpha
          context:
            cluster: cluster-one
            user: developer
            namespace: staging
        - name: personal
          context:
            cluster: cluster-one
            user: developer
        users:
        - name: developer
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1
              command: /usr/bin/touch
              args: ['\(marker.path)']
              interactiveMode: Never
        """
        try file.write(to: config, atomically: true, encoding: .utf8)
        let contexts = try await KubernetesClient().contexts(in: config)
        XCTAssertEqual(Set(contexts.map(\.name)), ["team alpha", "personal"])
        let current = try XCTUnwrap(contexts.first(where: \.isCurrent))
        XCTAssertEqual(current.name, "team alpha")
        XCTAssertEqual(current.namespace, "staging")
        XCTAssertEqual(current.cluster, "cluster-one")
        XCTAssertNil(contexts.first { $0.name == "personal" }?.namespace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), file)
    }

    func testProbeUsesExplicitFileContextAndVersionEndpoint() async throws {
        let args = folder.appendingPathComponent("arguments")
        let config = folder.appendingPathComponent("config with spaces")
        try Data().write(to: config)
        let client = try fakeClient("""
        printf '%s\\n' "$@" > "$TEST_ARGS_FILE"
        printf '{"gitVersion":"v1.30.0"}'
        """, environment: ["TEST_ARGS_FILE": args.path])
        try await client.testConnection(in: config, context: "team alpha")
        XCTAssertEqual(try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init),
                       ["--kubeconfig=\(config.path)", "--context=team alpha", "--request-timeout=8s", "get", "--raw=/version"])
    }

    func testProbeRejectsLoginPageAndHidesRawCredentialHelperOutput() async throws {
        let config = folder.appendingPathComponent("config")
        try Data().write(to: config)
        let redirected = try fakeClient("printf '<html>Sign in</html>'")
        do {
            try await redirected.testConnection(in: config, context: "alpha")
            XCTFail("An HTML page cannot confirm a cluster connection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Kubernetes version"))
        }

        let denied = try fakeClient("echo 'Unauthorized: private-token' >&2\nexit 1")
        do {
            try await denied.testConnection(in: config, context: "alpha")
            XCTFail("Expected an authentication error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credentials"))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }

    func testHangingCredentialCheckTimesOut() async throws {
        let config = folder.appendingPathComponent("config")
        try Data().write(to: config)
        let client = try fakeClient("exec /bin/sleep 8", timeout: 0.2)
        let start = Date()
        do {
            try await client.testConnection(in: config, context: "alpha")
            XCTFail("Expected the check to time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    private func fakeClient(_ script: String, environment: [String: String] = [:],
                            timeout: TimeInterval = 5) throws -> KubernetesClient {
        let executable = folder.appendingPathComponent("kubectl")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var environment = environment
        environment["PATH"] = folder.path
        return KubernetesClient(environment: environment, homeDirectory: folder, timeout: timeout)
    }
}
