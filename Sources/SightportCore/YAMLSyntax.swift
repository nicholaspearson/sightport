import Foundation

/// Presentation tokens. Ranges use TextKit's UTF-16 offsets into the original source.
public struct YAMLSyntaxToken: Equatable, Sendable {
    public enum Kind: Hashable, Sendable { case key, string, number, literal, comment, indicator }
    public let kind: Kind
    public let range: NSRange

    public static func tokens(in source: String) -> [Self] {
        var scanner = YAMLScanner(units: Array(source.utf16))
        return scanner.run()
    }
}

private struct YAMLScanner {
    let units: [UInt16]
    var tokens: [YAMLSyntaxToken] = []
    var blockParent: Int?
    var blockIndent: Int?
    var openQuote: UInt16?
    var flowDepth = 0

    mutating func run() -> [YAMLSyntaxToken] {
        var start = 0
        while start < units.count {
            if Task.isCancelled { return [] }
            var end = start
            while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
            scanLine(start: start, end: end)
            start = end + 1
            if end < units.count, units[end] == 13, start < units.count, units[start] == 10 { start += 1 }
        }
        return tokens
    }

    mutating func emit(_ kind: YAMLSyntaxToken.Kind, _ start: Int, _ end: Int) {
        if end > start {
            tokens.append(.init(kind: kind, range: NSRange(location: start, length: end - start)))
        }
    }

    func space(_ index: Int) -> Bool { units[index] == 32 || units[index] == 9 }

    func skipSpaces(_ start: Int, _ end: Int) -> Int {
        var i = start
        while i < end && space(i) { i += 1 }
        return i
    }

    mutating func scanLine(start: Int, end: Int) {
        var i = skipSpaces(start, end)
        guard i < end else { return }
        let indent = i - start
        if let parent = blockParent {
            if indent >= (blockIndent ?? parent + 1) {
                if blockIndent == nil { blockIndent = indent }
                emit(.string, i, end)
                return
            }
            blockParent = nil
            blockIndent = nil
        }

        var parentColumn = indent
        while i < end {
            let ch = units[i]
            if let quote = openQuote {
                i = scanQuoted(quote, start: i, contentStart: i, end: end)
            } else if ch == 35 { // A comment starts at a token boundary.
                emit(.comment, i, end)
                return
            } else if ch == 34 || ch == 39 {
                let quoteStart = i
                i = scanQuoted(ch, start: i, contentStart: i + 1, end: end)
                if flowDepth == 0 && openQuote == nil && units[i - 1] == 58 {
                    parentColumn = quoteStart - start
                }
            } else if ch == 91 || ch == 123 {
                flowDepth += 1
                emit(.indicator, i, i + 1)
                i += 1
            } else if flowDepth > 0 && (ch == 93 || ch == 125 || ch == 44) {
                if ch != 44 { flowDepth -= 1 }
                emit(.indicator, i, i + 1)
                i += 1
            } else if (ch == 45 || ch == 63) && (i + 1 == end || space(i + 1)) {
                emit(.indicator, i, i + 1)
                i += 1
            } else if ch == 38 || ch == 42 || ch == 33 { // Anchor, alias or tag.
                var next = i + 1
                while next < end && !space(next) && !flowDelimiter(next) { next += 1 }
                emit(.indicator, i, next)
                i = next
            } else {
                let tokenStart = i
                while i < end && !separator(i, end) && !flowDelimiter(i) {
                    if units[i] == 35 && i > tokenStart && space(i - 1) { break }
                    i += 1
                }
                var tokenEnd = i
                while tokenEnd > tokenStart && space(tokenEnd - 1) { tokenEnd -= 1 }
                if i < end, separator(i, end) {
                    emit(.key, tokenStart, tokenEnd)
                    emit(.indicator, i, i + 1)
                    if flowDepth == 0 { parentColumn = tokenStart - start }
                    i += 1
                } else if tokenEnd > tokenStart {
                    let kind = scalarKind(tokenStart, tokenEnd, parentColumn: parentColumn)
                    emit(kind, tokenStart, tokenEnd)
                }
            }
            i = skipSpaces(i, end)
        }
    }

    func flowDelimiter(_ i: Int) -> Bool {
        guard flowDepth > 0 else { return false }
        switch units[i] {
        case 44, 91, 93, 123, 125: return true
        default: return false
        }
    }

    func separator(_ i: Int, _ end: Int) -> Bool {
        units[i] == 58 && (i + 1 == end || space(i + 1) || flowDelimiter(i + 1))
    }

    mutating func scanQuoted(_ quote: UInt16, start: Int, contentStart: Int, end: Int) -> Int {
        var i = contentStart
        while i < end {
            if quote == 34 && units[i] == 92 { i = min(end, i + 2); continue }
            if units[i] == quote {
                if quote == 39 && i + 1 < end && units[i + 1] == quote { i += 2; continue }
                openQuote = nil
                let next = skipSpaces(i + 1, end)
                if next < end && units[next] == 58 {
                    emit(.key, start, i + 1)
                    emit(.indicator, next, next + 1)
                    return next + 1
                }
                emit(.string, start, i + 1)
                return i + 1
            }
            i += 1
        }
        openQuote = quote
        emit(.string, start, end)
        return end
    }

    private static let number = try! NSRegularExpression(
        pattern: #"^[+-]?(?:0x[0-9a-f]+|0o[0-7]+|0b[01]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:e[+-]?[0-9]+)?|\.inf|\.nan)$"#,
        options: .caseInsensitive
    )

    mutating func scalarKind(_ start: Int, _ end: Int, parentColumn: Int) -> YAMLSyntaxToken.Kind {
        let first = units[start]
        if (first == 124 || first == 62) && flowDepth == 0 && end - start <= 3 {
            let modifiers = units[(start + 1)..<end]
            if modifiers.allSatisfy({ $0 == 43 || $0 == 45 || (49...57).contains($0) }) {
                blockParent = parentColumn
                blockIndent = modifiers.first(where: { (49...57).contains($0) }).map { parentColumn + Int($0) - 48 }
                return .indicator
            }
        }
        let range = start..<end
        if range.count <= 5 {
            switch String(decoding: units[range], as: UTF16.self).lowercased() {
            case "true", "false", "null", "~", "yes", "no", "on", "off": return .literal
            case "---", "...": return .indicator
            default: break
            }
        }
        if (48...57).contains(first) || first == 45 || first == 43 || first == 46 {
            let value = String(decoding: units[range], as: UTF16.self)
            if Self.number.firstMatch(in: value, range: NSRange(location: 0, length: range.count)) != nil { return .number }
        }
        return .string
    }
}
