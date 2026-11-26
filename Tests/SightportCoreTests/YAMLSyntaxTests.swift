import XCTest
@testable import SightportCore

final class YAMLSyntaxTests: XCTestCase {
    func testManifestAndFlowScalarsUseUTF16SourceRanges() {
        let source = """
        apiVersion: v1
        metadata:
          "🧊.name": 'it''s blue #1' # second value
          f:example.com/role: registry.test:5000/path#fragment
          limits: {cpu: 250m, values: [42, -2.5e+3, true, ~, "false"]}
        """
        let tokens = YAMLSyntaxToken.tokens(in: source)
        let input = source as NSString
        func values(_ kind: YAMLSyntaxToken.Kind) -> [String] {
            tokens.filter { $0.kind == kind }.map { input.substring(with: $0.range) }
        }
        XCTAssertEqual(values(.key), ["apiVersion", "metadata", "\"🧊.name\"", "f:example.com/role", "limits", "cpu", "values"])
        XCTAssertEqual(values(.string), ["v1", "'it''s blue #1'", "registry.test:5000/path#fragment", "250m", "\"false\""])
        XCTAssertEqual(values(.number), ["42", "-2.5e+3"])
        XCTAssertEqual(values(.literal), ["true", "~"])
        XCTAssertEqual(values(.comment), ["# second value"])
        XCTAssertTrue(zip(tokens, tokens.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location })
    }

    func testMultilineScalarsKeepEmbeddedSyntaxLiteral() {
        let source = "- \"notes\": |2- # folded payload\r\n    nested: true\r\n\r\n    # text\r\n  other: \"a\r\n   value: still quoted\"\r\nfinal: 7"
        let tokens = YAMLSyntaxToken.tokens(in: source)
        let input = source as NSString
        let text = tokens.filter { $0.kind == .string }.map { input.substring(with: $0.range) }
        XCTAssertEqual(text, ["nested: true", "# text", "\"a", "value: still quoted\""])
        XCTAssertEqual(tokens.filter { $0.kind == .key }.map { input.substring(with: $0.range) }, ["\"notes\"", "other", "final"])
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.count, 1)
    }

    func testPunctuationInKubernetesManagedFieldKeysAndImages() {
        let source = """
        k:{"name":"init"}: {}
        - image: registry.local:5050/app:v2
          command: ["/bin/sh", "-c", "echo a:b # c"]
        """
        let tokens = YAMLSyntaxToken.tokens(in: source)
        let input = source as NSString
        XCTAssertEqual(tokens.filter { $0.kind == .key }.map { input.substring(with: $0.range) },
                       [#"k:{"name":"init"}"#, "image", "command"])
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.count, 0)
    }
}
