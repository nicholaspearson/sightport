import Darwin
import Foundation
import XCTest
@testable import SightportCore

final class ResourceWatchTests: XCTestCase {
    func testSecretWatchUsesTheListProjectionAndNeverPrintsValues() throws {
        let template = ResourceWatchTarget.resource(.secrets).watchTemplate
        let object: [String: Any] = [
            "type": "Opaque", "data": ["key": "private-value"],
            "metadata": ["name": "app", "namespace": "test", "uid": "a", "resourceVersion": "21"]
        ]
        let added = try renderProjection(template, object: ["type": "ADDED", "object": object])
        let fields = ["ADDED", "a", "app", "test", "", "Opaque", "1", "21"]
        XCTAssertEqual(String(decoding: added, as: UTF8.self), fields.joined(separator: "\u{1f}") + "\n")
        let deleted = try renderProjection(template, object: ["type": "DELETED", "object": object])
        XCTAssertEqual(String(decoding: deleted, as: UTF8.self), "DELETED\u{1f}a\n")
        XCTAssertTrue(try renderProjection(template, object: ["type": "BOOKMARK", "object": object]).isEmpty)
    }

    func testWatchPublishesCompleteSnapshotsAndCoalescesObjectUpdates() async throws {
        let fixture = try WatchFixture(script: #"""
            case " $* " in
            *" --watch "*)
                printf 'ADDED\037a\037app\037blue\037\0371\0370\0371\n'
                printf 'SYNC\n'
                /bin/sleep 0.03
                printf 'ADDED\037b\037app\037green\037\0371\0370\0372\n'
                printf 'MODIFIED\037a\037app\037blue\037\0372\0370\0373\n'
                /bin/sleep 0.45
                printf 'DELETED\037a\n'
                ;;
            *) printf 'a\tapp\tblue\t\t1\t0\t1\n';;
            esac
            """#)
        defer { fixture.remove() }
        let log = WatchSnapshots()
        try await fixture.client.watchResources(.resource(.configMaps), in: fixture.config, context: "my context") {
            await log.add($0)
        }
        let frames = await log.frames
        XCTAssertEqual(frames.map { $0.map(\.id) }, [["a"], ["a", "b"], ["b"]])
        let updated = try XCTUnwrap(frames.first { $0.count == 2 })
        XCTAssertEqual(updated.map(\.resourceVersion), ["3", "2"])
        XCTAssertEqual(updated.map(\.namespace), ["blue", "green"])
    }

    func testInitialListAndSubsequentDeletionShareOneStreamAndCancellationReapsClient() async throws {
        let fixture = try WatchFixture(script: #"""
            case " $* " in
            *" --watch "*)
                printf '%s' "$$" > "$TEST_DIR/watch.pid"
                printf 'ADDED\037a\037app\037blue\037\0371\0370\0371\nSYNC\n'
                /bin/sleep 0.2
                printf 'DELETED\037a\n'
                exec /bin/sleep 30
                ;;
            *) exit 1;;
            esac
            """#)
        defer { fixture.remove() }
        let first = expectation(description: "complete initial list")
        let deleted = expectation(description: "deleted row removed")
        let watch = Task {
            try await fixture.client.watchResources(.resource(.configMaps), in: fixture.config, context: "selected", namespace: "blue") { rows in
                if rows.isEmpty { deleted.fulfill() } else { first.fulfill() }
            }
        }
        await fulfillment(of: [first, deleted], timeout: 7, enforceOrder: true)
        watch.cancel()
        do { try await watch.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let pidFile = fixture.config.deletingLastPathComponent().appendingPathComponent("watch.pid")
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testEmptyInitialListAndWatchOnlyPermissionFailure() async throws {
        let fixture = try WatchFixture(script: #"""
            case " $* " in
            *" --watch "*) printf 'SYNC\n'; printf 'Forbidden private-fixture-detail\n' >&2; exit 1;;
            esac
            """#)
        defer { fixture.remove() }
        let log = WatchSnapshots()
        do {
            try await fixture.client.watchResources(.resource(.pods), in: fixture.config, context: "selected") {
                await log.add($0)
            }
            XCTFail("Expected the watch error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private-fixture-detail"))
        }
        let frames = await log.frames
        XCTAssertEqual(frames, [[]])
    }
}

private actor WatchSnapshots {
    private(set) var frames: [[ResourceRow]] = []
    func add(_ rows: [ResourceRow]) { frames.append(rows) }
}

private struct WatchFixture: Sendable {
    let config: URL
    let client: KubernetesClient

    init(script: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = dir.appendingPathComponent("fixture config")
        try Data().write(to: config)
        let executable = dir.appendingPathComponent("sightport-kube")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        client = KubernetesClient(environment: ["PATH": dir.path, "TEST_DIR": dir.path], homeDirectory: dir, sdkExecutable: executable)
    }

    func remove() { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
}
