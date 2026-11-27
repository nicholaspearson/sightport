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

    func testDiscoversIndividualKubeconfigsAndSkipsOtherFiles() async throws {
        let kube = folder.appendingPathComponent(".kube", isDirectory: true)
        try FileManager.default.createDirectory(at: kube, withIntermediateDirectories: true)
        let yaml = """
        apiVersion: v1
        kind: Config
        contexts:
        - name: example
          context: {cluster: local}
        """
        for name in ["config.dev", "config.prod", "staging.yaml", "config.old", "config.key", "credentials.json", ".hidden.yaml"] {
            try yaml.write(to: kube.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let cache = kube.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try yaml.write(to: cache.appendingPathComponent("ignored.yaml"), atomically: true, encoding: .utf8)
        try "apiVersion: v1\nkind: Service\n".write(to: kube.appendingPathComponent("service.yaml"),
                                                    atomically: true, encoding: .utf8)
        let manual = folder.appendingPathComponent("imported config")
        try FileManager.default.createSymbolicLink(at: manual, withDestinationURL: kube.appendingPathComponent("staging.yaml"))
        let client = KubernetesClient(environment: [:], homeDirectory: folder, sdkExecutable: try TestSDK.executable.get())
        let candidates = client.sourceCandidates(imported: [manual])
        XCTAssertEqual(candidates.map(\.file.lastPathComponent), ["imported config", "config.dev", "config.prod", "service.yaml"])
        var sources: [URL] = []
        for candidate in candidates {
            if let contexts = try await client.readContexts(from: candidate) {
                XCTAssertEqual(contexts.map(\.name), ["example"])
                sources.append(candidate.file)
            }
        }
        XCTAssertEqual(sources.map(\.lastPathComponent), ["imported config", "config.dev", "config.prod"])

        let override = KubernetesClient(environment: ["KUBECONFIG": manual.path], homeDirectory: folder)
        XCTAssertEqual(override.sourceCandidates(imported: []).map(\.file), [manual.standardizedFileURL])
    }

    func testReadsRealKubeconfigLocallyIncludingCurrentContextAndNamespace() async throws {
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
        let sdk = try TestSDK.executable.get()
        let client = KubernetesClient(environment: [:], homeDirectory: folder, sdkExecutable: sdk)
        let contexts = try await client.contexts(in: config)
        XCTAssertEqual(Set(contexts.map(\.name)), ["team alpha", "personal"])
        let current = try XCTUnwrap(contexts.first(where: \.isCurrent))
        XCTAssertEqual(current.name, "team alpha")
        XCTAssertEqual(current.namespace, "staging")
        XCTAssertEqual(current.cluster, "cluster-one")
        XCTAssertNil(contexts.first { $0.name == "personal" }?.namespace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), file)
    }

    func testMissingBundledSDKDoesNotFallBackToProgramsOnPATH() async throws {
        let config = folder.appendingPathComponent("config.yaml")
        try Data().write(to: config)
        let marker = folder.appendingPathComponent("invoked")
        for name in ["kubectl", "sightport-kube"] {
            let stub = folder.appendingPathComponent(name)
            try "#!/bin/sh\n/usr/bin/touch \"$MARKER\"\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        }
        let client = KubernetesClient(environment: ["PATH": folder.path, "MARKER": marker.path],
                                      homeDirectory: folder, sdkExecutable: folder.appendingPathComponent("missing"))
        do {
            _ = try await client.contexts(in: config)
            XCTFail("Expected missing SDK")
        } catch KubernetesError.missingSDK {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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

    func testNamedNamespaceLookupDistinguishesMissingFromRestrictedAccess() async throws {
        let config = folder.appendingPathComponent("fixture config")
        try Data().write(to: config)
        let client = try fakeClient("""
        case "$5" in
          namespaces/empty-but-present) printf '%s' empty-but-present ;;
          namespaces/missing-namespace) echo 'namespaces not found' >&2; exit 1 ;;
          namespaces/restricted) echo Forbidden >&2; exit 1 ;;
          namespaces/offline) echo timeout >&2; exit 1 ;;
          *) exit 2 ;;
        esac
        """)
        let present = try await client.namespaceExists("empty-but-present", in: config, context: "fixture")
        let missing = try await client.namespaceExists("missing-namespace", in: config, context: "fixture")
        let restricted = try await client.namespaceExists("restricted", in: config, context: "fixture")
        XCTAssertEqual(present, true)
        XCTAssertEqual(missing, false)
        XCTAssertNil(restricted)
        do {
            _ = try await client.namespaceExists("offline", in: config, context: "fixture")
            XCTFail("Connection errors must remain distinct from missing namespaces")
        } catch KubernetesError.timeout {}
    }

    private func fakeClient(_ script: String, environment: [String: String] = [:],
                            timeout: TimeInterval = 5) throws -> KubernetesClient {
        let executable = folder.appendingPathComponent("sightport-kube")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var environment = environment
        environment["PATH"] = folder.path
        return KubernetesClient(environment: environment, homeDirectory: folder, timeout: timeout, sdkExecutable: executable)
    }
}
