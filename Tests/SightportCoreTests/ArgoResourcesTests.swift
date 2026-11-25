import XCTest
@testable import SightportCore

final class ArgoResourcesTests: XCTestCase {
    private func decoded(_ kind: ResourceKind, values: [String]) throws -> ResourceRow {
        let record = (["fixture-uid", "record", "control-plane", ""] + values).joined(separator: "\t") + "\n"
        return try XCTUnwrap(ResourceRow.decodeList(Data(record.utf8), kind: kind).first)
    }

    private func encoded(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
    }

    func testRegistrationIdentityIsDecodedAndURLCredentialsAreRemoved() throws {
        for (input, expected) in [
            ("https://user:private@code.example:8443/team/app.git?token=secret#user", "https://code.example:8443/team/app.git"),
            ("ssh://git@code.example/team/app.git", "ssh://code.example/team/app.git"),
            ("git@code.example:team/app.git?token=secret#branch", "code.example:team/app.git"),
            ("oci://registry.example/charts", "oci://registry.example/charts"),
            ("registry.example:5000/charts", "registry.example:5000/charts"),
            ("file:///tmp/local", ""), ("local", "")
        ] {
            let row = try decoded(.argoRepositories, values: [encoded(input), encoded("git"), encoded("team")])
            XCTAssertEqual(row.values, [expected, "git", "team"])
        }
        let cluster = try decoded(.argoClusters, values: [encoded("east"), encoded("https://u:p@[::1]:6443?token=secret"),
                                                            encoded("team"), "No"])
        XCTAssertEqual(cluster.values, ["east", "https://[::1]:6443", "team", "No"])
        let malformed = try decoded(.argoRepositories, values: ["*not-base64*", "", ""])
        XCTAssertEqual(malformed.values, ["", "", ""])
    }

    func testRegistrationQueriesUseNarrowProjectionsAndDistinctSelectors() throws {
        XCTAssertEqual(ResourceKind.argoRepositories.argoLabelSelector, "argocd.argoproj.io/secret-type=repository")
        XCTAssertEqual(ResourceKind.argoClusters.argoLabelSelector, "argocd.argoproj.io/secret-type=cluster")
        XCTAssertNil(ResourceKind.secrets.argoLabelSelector)
        for kind in ResourceKind.argoResources + ResourceKind.argoSettings { XCTAssertTrue(kind.isNamespaced) }
        for (kind, fields) in [(ResourceKind.argoRepositories, Set([".data.url", ".data.type", ".data.project"])),
                               (.argoClusters, Set([".data.name", ".data.server", ".data.project"]))] {
            XCTAssertEqual(kind.resourceName, "secrets")
            let expression = try NSRegularExpression(pattern: #"\.data(?:\.[A-Za-z0-9_]+)?"#)
            let source = kind.listTemplate as NSString
            let selected = expression.matches(in: source as String, range: NSRange(location: 0, length: source.length))
            XCTAssertEqual(Set(selected.map { source.substring(with: $0.range) }), fields)
            XCTAssertFalse(kind.listTemplate.contains(".stringData"))
        }
    }

    func testApplicationHealthAndSyncAssessmentsAndExactCRDNames() throws {
        XCTAssertEqual(ResourceKind.argoResources.map(\.resourceName),
                       ["applications.argoproj.io", "applicationsets.argoproj.io", "appprojects.argoproj.io"])
        XCTAssertEqual(Array(ResourceKind.argoApplications.columns.prefix(2)), ["Sync", "Health"])
        for (sync, health, issue) in [("Synced", "Healthy", false), ("Synced", "Progressing", false),
                                      ("OutOfSync", "Healthy", true), ("Synced", "Degraded", true),
                                      ("Synced", "Missing", true), ("", "", true)] {
            let app = try decoded(.argoApplications, values: [sync, health, "", "", "", ""])
            let state = ArgoApplicationStatus(row: app)
            XCTAssertEqual(state.sync, sync.isEmpty ? "Unknown" : sync)
            XCTAssertEqual(state.health, health.isEmpty ? "Unknown" : health)
            XCTAssertEqual(state.needsAttention, issue)
        }
    }
}
