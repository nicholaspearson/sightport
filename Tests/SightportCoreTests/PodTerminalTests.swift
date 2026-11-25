import Darwin
import Foundation
import XCTest
@testable import SightportCore

final class PodTerminalTests: XCTestCase {
    private var folder: URL!
    private var config: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        config = folder.appendingPathComponent("kubeconfig with spaces")
        try Data().write(to: config)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testExecScopesUsesControllingTTYInputResizeAndEOF() throws {
        let client = try fixture("""
        printf '%s\\n' "$@" > "$FIXTURE_DIR/argv"
        test -t 0 && test -t 1 && test -t 2 && tty < /dev/tty > /dev/null || exit 3
        stty -echo
        printf 'started %s %s\\n' "$TERM" "$(stty size)"
        while IFS= read -r line; do
            printf 'received=%s size=%s\\n' "$line" "$(stty size)"
        done
        printf 'remote EOF\\n'
        exit 7
        """)
        let stream = Transcript()
        let session = try client.openPodTerminal(in: config, context: "team alpha;literal", namespace: "blue",
                                                 pod: "api-1", container: "service", shell: "/bin/bash",
                                                 columns: 90, rows: 28, onOutput: { stream.append($0) },
                                                 onExit: { stream.exit($0) })
        defer { session.close() }
        XCTAssertTrue(stream.waitFor("started xterm-256color 28 90"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("argv"), encoding: .utf8)
            .split(separator: "\n").map(String.init), [
                "--kubeconfig=" + config.path, "--context=team alpha;literal", "--namespace=blue",
                "exec", "--stdin", "--tty", "--container=service", "pod/api-1", "--", "/bin/bash"
            ])
        session.resize(columns: 115, rows: 36)
        XCTAssertTrue(session.send(Data("first line\n".utf8)))
        XCTAssertTrue(stream.waitFor("received=first line size=36 115"))
        XCTAssertTrue(session.send(Data([4])))
        XCTAssertEqual(stream.waitForExit(), 7)
        XCTAssertTrue(stream.waitFor("remote EOF"))
        XCTAssertFalse(session.send(Data([13])))
        session.close()
        XCTAssertEqual(stream.exitCount, 1)
    }

    func testRawKeyboardBytesArePreserved() throws {
        let client = try fixture("""
        stty raw -echo
        printf 'ready'
        od -An -tx1 -N5 | tr -d '[:space:]'
        """)
        let stream = Transcript()
        let session = try client.openPodTerminal(in: config, context: "local", namespace: "default", pod: "api",
                                                 container: "web", onOutput: { stream.append($0) }, onExit: { stream.exit($0) })
        defer { session.close() }
        XCTAssertTrue(stream.waitFor("ready"))
        XCTAssertFalse(session.send(Data(repeating: 0x61, count: 1_048_577)))
        XCTAssertTrue(session.send(Data([3, 27, 91, 65, 4])))
        XCTAssertEqual(stream.waitForExit(), 0)
        XCTAssertTrue(stream.waitFor("031b5b4104"))
    }

    func testDroppingSessionStopsLocalProcessAndItsGroup() throws {
        let client = try fixture("""
        trap '' HUP TERM
        /bin/sleep 60 &
        printf '%s %s\\n' "$$" "$!" > "$FIXTURE_DIR/pids"
        printf 'waiting'
        wait
        """)
        let stream = Transcript()
        var session: PodTerminalSession? = try client.openPodTerminal(in: config, context: "local", namespace: "blue",
                                                                     pod: "api", container: "app",
                                                                     onOutput: { stream.append($0) }, onExit: { stream.exit($0) })
        XCTAssertTrue(stream.waitFor("waiting"))
        let pids = try String(contentsOf: folder.appendingPathComponent("pids"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        XCTAssertNotNil(session)
        session = nil
        XCTAssertEqual(stream.waitForExit(), 128 + SIGKILL)
        let deadline = Date().addingTimeInterval(3)
        while pids.contains(where: { Darwin.kill($0, 0) == 0 }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.015)
        }
        for pid in pids { XCTAssertEqual(Darwin.kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH) }
    }

    func testFastFailureReportsDiagnosticBeforeExitAndRejectsInvalidTarget() throws {
        let client = try fixture("printf 'Error from server (Forbidden)' >&2\nexit 1")
        let stream = Transcript()
        let session = try client.openPodTerminal(in: config, context: "test", namespace: "blue", pod: "api",
                                                 container: "worker", onOutput: { stream.append($0) }, onExit: { stream.exit($0) })
        defer { session.close() }
        XCTAssertEqual(stream.waitForExit(), 1)
        XCTAssertTrue(stream.waitFor("Forbidden"))
        XCTAssertThrowsError(try client.openPodTerminal(in: config, context: "test", namespace: "", pod: "api",
                                                       container: "worker", onOutput: { _ in }, onExit: { _ in }))
    }

    private func fixture(_ script: String) throws -> KubernetesClient {
        let executable = folder.appendingPathComponent("kubectl")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return KubernetesClient(environment: ["PATH": folder.path, "FIXTURE_DIR": folder.path], homeDirectory: folder)
    }
}

private final class Transcript: @unchecked Sendable {
    private let condition = NSCondition()
    private var data = Data()
    private var exits: [Int32] = []

    func append(_ bytes: Data) {
        condition.lock()
        defer { condition.unlock() }
        data.append(bytes)
        condition.broadcast()
    }

    func exit(_ status: Int32) {
        condition.lock()
        defer { condition.unlock() }
        exits.append(status)
        condition.broadcast()
    }

    var exitCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return exits.count
    }

    func waitFor(_ text: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let end = Date().addingTimeInterval(4)
        while !String(decoding: data, as: UTF8.self).contains(text) {
            if !exits.isEmpty || !condition.wait(until: end) { return false }
        }
        return true
    }

    func waitForExit() -> Int32? {
        condition.lock()
        defer { condition.unlock() }
        let end = Date().addingTimeInterval(4)
        while exits.isEmpty {
            if !condition.wait(until: end) { break }
        }
        return exits.first
    }
}
