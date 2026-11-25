import Foundation

public struct ContextID: Codable, Hashable, Sendable {
    public let file: URL
    public let name: String

    public init(file: URL, name: String) {
        self.file = file.standardizedFileURL
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let file = try values.decode(URL.self, forKey: .file)
        guard file.isFileURL else {
            throw DecodingError.dataCorruptedError(forKey: .file, in: values,
                                                   debugDescription: "Expected a local kubeconfig file.")
        }
        self.init(file: file, name: try values.decode(String.self, forKey: .name))
    }
}

public struct ContextPreferences: Codable, Equatable, Sendable {
    public var favorites: Set<ContextID>
    public var activeContext: ContextID?

    public init(favorites: Set<ContextID> = [], activeContext: ContextID? = nil) {
        self.favorites = favorites
        self.activeContext = activeContext
    }
}

public struct ContextPreferencesRepository: Sendable {
    private let directory: URL
    private var preferencesURL: URL { directory.appendingPathComponent("context-preferences.json") }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask)[0]
            .appendingPathComponent("Sightport", isDirectory: true)
    }

    public func load(
        legacyActiveID: UUID? = nil,
        onLegacySources: ([URL]) -> Void = { _ in }
    ) throws -> ContextPreferences {
        let decoder = JSONDecoder()
        if let data = try readIfPresent(preferencesURL) {
            return try decoder.decode(ContextPreferences.self, from: data)
        }

        let legacyURL = directory.appendingPathComponent("profiles.json")
        guard let data = try readIfPresent(legacyURL) else { return ContextPreferences() }
        let profiles = try decoder.decode([LegacyProfile].self, from: data)
        var preferences = ContextPreferences()
        var importedFiles = Set<URL>()
        var sources: [URL] = []
        for profile in profiles {
            let context = ContextID(file: URL(fileURLWithPath: profile.kubeconfigPath), name: profile.context)
            if importedFiles.insert(context.file).inserted { sources.append(context.file) }
            if profile.isFavorite { preferences.favorites.insert(context) }
            if profile.id == legacyActiveID { preferences.activeContext = context }
        }

        onLegacySources(sources)

        // An empty migrated store is meaningful: removing the last favorite must survive relaunch.
        try save(preferences)
        return preferences
    }

    public func save(_ preferences: ContextPreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(preferences)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: preferencesURL, options: .atomic)
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private struct LegacyProfile: Decodable {
        let id: UUID
        let kubeconfigPath: String
        let context: String
        let isFavorite: Bool
    }
}
