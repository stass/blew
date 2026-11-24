import XCTest
@testable import blew

/// `TextLine`: every run's text is escaped; styles are the only ANSI codes.
final class TextLineTests: XCTestCase {

    func testEveryRunIsEscapedStyledOrNot() {
        var line = TextLine("a\u{1B}[2J", .bold)
        line.append("\u{9B}31m")
        line.append("x\u{202E}y", .dim)
        var inner = TextLine("\u{07}")
        inner.append("\n", .bold)
        line.append(inner)
        XCTAssertEqual(line.rendered(styled: false), #"a\x1b[2J\u009b31mx\u202ey\x07\n"#)
        XCTAssertEqual(line.rendered(styled: true),
                       "\u{1B}[1m" + #"a\x1b[2J"# + "\u{1B}[0m" + #"\u009b31m"#
                       + "\u{1B}[2m" + #"x\u202ey"# + "\u{1B}[0m" + #"\x07"#
                       + "\u{1B}[1m" + #"\n"# + "\u{1B}[0m")
    }

    func testRenderedLineHoldsNoControlsButItsStyles() {
        let styles: [TextLine.Style] = [.plain, .bold, .dim]
        var line = TextLine()
        for scalar in (0...0x9F).compactMap(Unicode.Scalar.init) + ["\u{2028}", "\u{202D}", "\u{FEFF}"] {
            line.append(String(scalar), styles[Int(scalar.value) % 3])
        }
        let withoutStyles = line.rendered(styled: true)
            .replacingOccurrences(of: "\u{1B}[1m", with: "")
            .replacingOccurrences(of: "\u{1B}[2m", with: "")
            .replacingOccurrences(of: "\u{1B}[0m", with: "")
        XCTAssertEqual(withoutStyles, line.rendered(styled: false))
        XCTAssertFalse(withoutStyles.unicodeScalars.contains(where: TextEscaping.isEscaped))
    }

    func testPaddingMeasuresEscapedTextAndJoinsTheLastRun() {
        let line = TextLine("🔥\u{1B}", .bold).padded(to: 8)
        XCTAssertEqual(line.width, 8)
        XCTAssertEqual(line.rendered(styled: true), "\u{1B}[1m🔥\\x1b  \u{1B}[0m")
        XCTAssertEqual(TextLine("abcdef").padded(to: 3).rendered(styled: false), "abcdef")
    }

    func testIndentJoinsTheFirstRun() {
        var line = TextLine("k: ", .dim)
        line.append("v")
        XCTAssertEqual(line.indented(by: 2).rendered(styled: true), "\u{1B}[2m  k: \u{1B}[0mv")
        XCTAssertEqual(TextLine().indented(by: 2).rendered(styled: false), "  ")
    }

    func testTableTrailingTextAndContinuationLines() {
        let rows = [
            TextTable.Row(cells: ["a", "bb"], trailing: TextLine("t\u{1B}")),
            TextTable.Row(cells: ["ccc", "d"], continuation: [TextLine("k: ", .dim)]),
        ]
        let lines = TextTable.lines(headers: ["H", "I"], trailingHeader: "Value", rows: rows)
            .map { $0.rendered(styled: false) }
        XCTAssertEqual(lines, ["H    I   Value", "──────────────", #"a    bb  t\x1b"#, "ccc  d ", "         k: "])
        let bare = TextTable.lines(headers: nil, indent: 2, rows: [TextTable.Row(cells: ["x", "y"])])
        XCTAssertEqual(bare.map { $0.rendered(styled: false) }, ["  x  y"])
        XCTAssertEqual(TextTable.lines(headers: ["H"], rows: []).count, 0)
    }
}
