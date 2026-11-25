import Foundation
import XCTest
@testable import SightportCore

// Kubeconfig extensions can hold arbitrary JSON. Rendering a projection against this
// local document exercises kubectl's actual Go-template engine without a cluster.
func projectResource(_ kind: ResourceKind, items: [[String: Any]]) throws -> [ResourceRow] {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    guard let executable = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("kubectl") })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw XCTSkip("kubectl is required to render the Kubernetes projection.")
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let config: [String: Any] = ["apiVersion": "v1", "kind": "Config",
                                 "extensions": [["name": "resources", "extension": ["items": items]]]]
    try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]).write(to: file)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--kubeconfig=" + file.path, "config", "view", "-o",
                         "go-template={{range .extensions}}{{with .extension}}" + kind.listTemplate + "{{end}}{{end}}"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let result = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ResourceReadError.invalidList }
    return try ResourceRow.decodeList(result, kind: kind)
}
