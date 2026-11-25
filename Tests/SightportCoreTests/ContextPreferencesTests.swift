import Foundation
import XCTest
@testable import SightportCore

final class ContextPreferencesTests: XCTestCase {
    private var directory: URL!
    private var repository: ContextPreferencesRepository!
    private var legacyURL: URL { directory.appendingPathComponent("profiles.json") }
    private var preferencesURL: URL { directory.appendingPathComponent("context-preferences.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = ContextPreferencesRepository(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testContextIdentityUsesStandardizedFileAndExactName() throws {
        let file = directory.appendingPathComponent("config")
        let sameFile = directory.appendingPathComponent("child/../config")
        let id = ContextID(file: file, name: " staging ")
        XCTAssertEqual(id, ContextID(file: sameFile, name: " staging "))
        XCTAssertNotEqual(id, ContextID(file: file, name: "staging"))
        XCTAssertNotEqual(id, ContextID(file: directory.appendingPathComponent("other"), name: " staging "))
        let storedWithUnnormalizedFile = try JSONEncoder().encode(["file": sameFile.absoluteString, "name": " staging "])
        XCTAssertEqual(try JSONDecoder().decode(ContextID.self, from: storedWithUnnormalizedFile), id)
    }

    func testFavoritesAndActiveSelectionSurviveRelaunchIndependently() throws {
        XCTAssertEqual(try repository.load(), ContextPreferences())
        let first = ContextID(file: directory.appendingPathComponent("a"), name: "cluster")
        let second = ContextID(file: directory.appendingPathComponent("b"), name: "cluster")
        let preferences = ContextPreferences(favorites: [first], activeContext: second)
        try repository.save(preferences)
        let reopened = ContextPreferencesRepository(directory: directory)
        XCTAssertEqual(try reopened.load(), preferences)
        try reopened.save(ContextPreferences(favorites: [], activeContext: second))
        XCTAssertEqual(try repository.load(), ContextPreferences(favorites: [], activeContext: second))
    }

    func testLegacyFavoritesAndActiveSelectionMigrateOnce() throws {
        let first = ContextID(file: directory.appendingPathComponent("a"), name: "cluster")
        let second = ContextID(file: directory.appendingPathComponent("b"), name: "cluster")
        let active = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            legacyRow(first, favorite: true), legacyRow(first, favorite: true),
            legacyRow(second, id: active, favorite: false)
        ])
        try data.write(to: legacyURL)
        var imported: [URL] = []
        let migrated = try repository.load(legacyActiveID: active) { imported = $0 }
        XCTAssertEqual(migrated, ContextPreferences(favorites: [first], activeContext: second))
        XCTAssertEqual(imported, [first.file, second.file])
        XCTAssertEqual(try Data(contentsOf: legacyURL), data)
        try repository.save(ContextPreferences())
        let reopened = try repository.load(legacyActiveID: active) { _ in XCTFail("Already imported sources") }
        XCTAssertEqual(reopened, ContextPreferences())
        XCTAssertEqual(try Data(contentsOf: legacyURL), data)
    }

    func testCorruptPreferencesRaiseErrorWithoutReimportingLegacyData() throws {
        let corrupt = Data("invalid".utf8)
        try Data("[]".utf8).write(to: legacyURL)
        try corrupt.write(to: preferencesURL)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: preferencesURL), corrupt)
    }

    func testMigrationCanRetryAfterMalformedLegacyFileIsRepaired() throws {
        let broken = Data("[{}]".utf8)
        try broken.write(to: legacyURL)
        XCTAssertThrowsError(try repository.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferencesURL.path))
        XCTAssertEqual(try Data(contentsOf: legacyURL), broken)
        try Data("[]".utf8).write(to: legacyURL)
        XCTAssertEqual(try repository.load(legacyActiveID: UUID()), ContextPreferences())
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferencesURL.path))
    }

    func testUncommittedMigrationRetriesSourceHandoff() throws {
        let context = ContextID(file: directory.appendingPathComponent("custom-config"), name: "dev")
        try JSONSerialization.data(withJSONObject: [legacyRow(context, favorite: false)]).write(to: legacyURL)
        var attempts: [[URL]] = []
        XCTAssertThrowsError(try repository.load { files in
            attempts.append(files)
            // Obstruct the destination after reading the legacy file to simulate a failed commit.
            do {
                try FileManager.default.createDirectory(at: preferencesURL, withIntermediateDirectories: false)
                try Data("obstruction".utf8).write(to: preferencesURL.appendingPathComponent("block"))
            } catch { XCTFail(error.localizedDescription) }
        })
        try FileManager.default.removeItem(at: preferencesURL)
        XCTAssertEqual(try repository.load { attempts.append($0) }, ContextPreferences())
        XCTAssertEqual(try repository.load { attempts.append($0) }, ContextPreferences())
        XCTAssertEqual(attempts, [[context.file], [context.file]])
    }

    private func legacyRow(_ context: ContextID, id: UUID = UUID(), favorite: Bool) -> [String: Any] {
        [
            "id": id.uuidString,
            "name": "Old display name",
            "namespace": "old-override",
            "kubeconfigPath": context.file.path,
            "context": context.name,
            "isFavorite": favorite
        ]
    }
}
