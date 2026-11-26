import Foundation
import XCTest
@testable import SightportCore

enum TestSDK {
    // Exercise the same client and projections as the application, including when
    // running the standalone Swift package tests outside an Xcode app bundle.
    static let executable = Result<URL, Error> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/test-tools")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("sightport-kube")
        let build = Process()
        build.currentDirectoryURL = root.appendingPathComponent("Tools/kube-client")
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["go", "build", "-mod=readonly", "-trimpath", "-o", binary.path, "."]
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { throw KubernetesError.missingSDK }
        return binary
    }
}

func projectResource(_ kind: ResourceKind, items: [[String: Any]]) throws -> [ResourceRow] {
    let result = try renderProjection(kind.listTemplate, object: ["items": items])
    return try ResourceRow.decodeList(result, kind: kind)
}

func renderProjection(_ template: String, object: [String: Any]) throws -> Data {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]).write(to: file)
    let process = Process()
    process.executableURL = try TestSDK.executable.get()
    process.arguments = ["render", "-o", "go-template=" + template]
    let pipe = Pipe()
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    process.standardInput = input
    process.standardOutput = pipe
    try process.run()
    let result = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ResourceReadError.invalidList }
    return result
}
