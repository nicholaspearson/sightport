import Foundation

public struct PodKey: Hashable, Sendable {
    public let namespace: String
    public let name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }
}

public struct PodUsage: Equatable, Sendable {
    public let cpuMillicores: Int
    public let memoryBytes: Int64

    public init(cpuMillicores: Int, memoryBytes: Int64) {
        self.cpuMillicores = cpuMillicores
        self.memoryBytes = memoryBytes
    }

    // kubectl top sums container usage and prints integer millicores and mebibytes.
    static func decodeTable(_ data: Data, namespace: String?) throws -> [PodKey: PodUsage] {
        guard let table = String(data: data, encoding: .utf8) else { throw PodReadError.invalidMetrics }
        var usage: [PodKey: PodUsage] = [:]
        for line in table.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == (namespace == nil ? 4 : 3) else { throw PodReadError.invalidMetrics }
            let nameIndex = namespace == nil ? 1 : 0
            let key = PodKey(namespace: namespace ?? String(fields[0]), name: String(fields[nameIndex]))
            let cpu = fields[nameIndex + 1]
            let memory = fields[nameIndex + 2]
            guard cpu.hasSuffix("m"), let millicores = Int(cpu.dropLast()), millicores >= 0,
                  memory.hasSuffix("Mi"), let mebibytes = Int64(memory.dropLast(2)), mebibytes >= 0,
                  mebibytes <= Int64.max / 1_048_576 else { throw PodReadError.invalidMetrics }
            usage[key] = PodUsage(cpuMillicores: millicores, memoryBytes: mebibytes * 1_048_576)
        }
        return usage
    }
}

enum PodReadError: LocalizedError {
    case invalidMetrics, missingLogTarget

    var errorDescription: String? {
        switch self {
        case .invalidMetrics: return "kubectl returned unreadable pod usage measurements."
        case .missingLogTarget: return "Select a pod and container to read logs."
        }
    }
}
