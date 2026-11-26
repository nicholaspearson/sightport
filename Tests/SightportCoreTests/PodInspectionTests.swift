import Foundation
import XCTest
@testable import SightportCore

final class PodInspectionTests: XCTestCase {
    private let row = ResourceRow(id: "stable-uid", name: "worker", namespace: "blue", createdAt: nil, values: [])
    private let document = #"""
    {
      "metadata":{"uid":"stable-uid","namespace":"blue","name":"worker","resourceVersion":"57","labels":{"tier":"jobs"}},
      "spec":{
        "containers":[{"name":"worker","image":"registry.test/app:build-9","command":["/app/worker"],"args":["--watch"],
          "ports":[{"name":"health","containerPort":8080}],"resources":{"requests":{"cpu":"250m"}},
          "env":[{"name":"MULTI","value":"line one\nline two"},{"name":"EMPTY"},
                 {"name":"TOKEN","valueFrom":{"secretKeyRef":{"name":"auth","key":"api","optional":true}}},
                 {"name":"CONFIG","valueFrom":{"configMapKeyRef":{"name":"settings","key":"color"}}},
                 {"name":"POD","valueFrom":{"fieldRef":{"fieldPath":"metadata.name"}}},
                 {"name":"CPU","valueFrom":{"resourceFieldRef":{"containerName":"worker","resource":"limits.cpu","divisor":"1m"}}}],
          "envFrom":[{"configMapRef":{"name":"common"}},{"prefix":"AUTH_","secretRef":{"name":"credentials","optional":true}}]}],
        "initContainers":[{"name":"setup","image":"registry.test/setup@sha256:abc"}],
        "ephemeralContainers":[{"name":"debug","image":"registry.test/tools:canary"}]
      },
      "status":{
        "containerStatuses":[{"name":"worker","image":"registry.test/app:build-9","imageID":"registry.test/app@sha256:abcdef",
          "containerID":"containerd://12345","state":{"waiting":{"reason":"CrashLoopBackOff","message":"fixture waiting message"}},
          "lastState":{"terminated":{"reason":"OOMKilled","exitCode":137,"signal":9,"finishedAt":"2026-01-01T00:00:00Z"}}}],
        "ephemeralContainerStatuses":[{"name":"debug","containerID":"containerd://debug","state":{"running":{"startedAt":"2026-01-02T12:00:00Z"}}}]
      }
    }
    """#

    func testSelectedContainerImagesRuntimeAndEnvironment() throws {
        let inspected = try PodInspection(data: Data(document.utf8), row: row)
        let app = try XCTUnwrap(inspected.containers["worker"])
        let fields = Dictionary(uniqueKeysWithValues: app.properties.map { ($0.name, $0.value) })
        XCTAssertEqual(fields["Image"], "registry.test/app:build-9")
        XCTAssertEqual(fields["Image tag"], "build-9")
        XCTAssertEqual(fields["Image ID"], "registry.test/app@sha256:abcdef")
        XCTAssertEqual(fields["Container ID"], "containerd://12345")
        XCTAssertEqual(fields["Ports"], "health 8080/TCP")
        XCTAssertEqual(fields["Requests"], "cpu 250m")
        XCTAssertEqual(fields["Arguments"], "--watch")
        XCTAssertEqual(fields["Waiting message"], "fixture waiting message")
        XCTAssertEqual(fields["Last termination"], "OOMKilled · exit 137 · signal 9 · 2026-01-01T00:00:00Z")
        XCTAssertEqual(app.environment.map(\.value), [
            "line one\nline two", "", "Secret auth · key api (optional)", "ConfigMap settings · key color",
            "Pod field metadata.name", "Container resource limits.cpu · worker · divisor 1m"
        ])
        XCTAssertEqual(app.environmentFrom, ["ConfigMap common", "Secret credentials (optional) · prefix AUTH_"])
        XCTAssertEqual(inspected.containers["setup"]?.properties.first?.value, "registry.test/setup@sha256:abc")
        XCTAssertEqual(inspected.containers["debug"]?.properties.last?.value, "2026-01-02T12:00:00Z")
    }

    func testImageTagAndDigestAreIndependentOfTheRegistryPort() {
        let digest = "sha256:" + String(repeating: "1", count: 64)
        let images: [(String, String?, String?)] = [
            ("busybox", "latest (implicit)", nil),
            ("registry.test:5100/team/app", "latest (implicit)", nil),
            ("registry.test:5100/team/app:v1", "v1", nil),
            ("registry.test:5100/team/app:v1@" + digest, "v1", digest),
            ("registry.test:5100/team/app@" + digest, nil, digest),
            (digest, nil, digest)
        ]
        for (image, tag, digest) in images {
            let parsed = PodContainerInspection.imageVersion(image)
            XCTAssertEqual(parsed.tag, tag, image)
            XCTAssertEqual(parsed.digest, digest, image)
        }
    }

    func testListAndWatchOnlyCarryPodRevisionAndSummary() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any])
        let list = try renderProjection(ResourceKind.pods.listTemplate, object: ["items": [object]])
        let event = try renderProjection(ResourceWatchTarget.resource(.pods).watchTemplate, object: ["type": "MODIFIED", "object": object])
        let row = try XCTUnwrap(ResourceRow.decodeList(list, kind: .pods).first)
        XCTAssertEqual(row.resourceVersion, "57")
        XCTAssertEqual(row.pod?.labels, ["tier": "jobs"])
        XCTAssertEqual(row.pod?.containers.map(\.role), [.app, .initContainer, .ephemeral])
        for output in [list, event] {
            let text = String(decoding: output, as: UTF8.self)
            for detail in ["MULTI", "line one", "TOKEN", "credentials", "registry.test", "12345", "OOMKilled"] {
                XCTAssertFalse(text.contains(detail), detail)
            }
        }
    }

    func testNamedReadChecksContextNamespaceNameAndUID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selected.yaml")
        try Data().write(to: file)
        let body = directory.appendingPathComponent("pod.json")
        try document.write(to: body, atomically: true, encoding: .utf8)
        let helper = directory.appendingPathComponent("sightport-kube")
        try #"""
        #!/bin/sh
        printf '%s\n' "$@" >> "$FIXTURE/args"
        /bin/cat "$FIXTURE/pod.json"
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let client = KubernetesClient(environment: ["FIXTURE": directory.path], homeDirectory: directory, sdkExecutable: helper)
        _ = try await client.inspectPod(for: row, in: file, context: "cluster A")
        let calls = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n").map(String.init), [
            "--kubeconfig=" + file.path, "--context=cluster A", "--request-timeout=8s", "get", "--raw=/api/v1/namespaces/blue/pods/worker"
        ])
        for old in ["stable-uid", "blue", "worker"] {
            let other = document.replacingOccurrences(of: old, with: "other")
            XCTAssertThrowsError(try PodInspection(data: Data(other.utf8), row: row)) { error in
                guard case KubernetesError.logTargetMissing = error else { return XCTFail("Unexpected identity error") }
            }
        }
    }
}
