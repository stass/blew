import XCTest
@testable import blew

final class TokenizerTests: XCTestCase {

    private var router: CommandRouter {
        CommandRouter(globals: makeGlobals())
    }

    // MARK: - Script splitting

    /// `;` splits commands only outside quotes, by the tokenizer's quoting.
    func testSplitScriptKeepsQuotedSemicolons() throws {
        XCTAssertEqual(try router.splitScript(#"write fff1 'a;b'; write "c;d" "e'f";help;;"#),
                       ["write fff1 'a;b'", #"write "c;d" "e'f""#, "help"])
    }

    /// An unclosed quote is an error, not the rest of the script as one value.
    func testUnclosedQuoteIsAnError() throws {
        XCTAssertThrowsError(try router.splitScript("write -f utf8 fff1 don't; read 2A19"))
        XCTAssertThrowsError(try router.tokenize("write fff1 \"abc"))
        let result = router.dispatch("write -f utf8 fff1 'abc")
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(result.errors, ["unclosed ' quote"])
        XCTAssertEqual(router.executeScript("write -f utf8 fff1 don't; read 2A19", dryRun: true),
                       BlewExitCode.invalidArguments.code)
        XCTAssertEqual(try router.tokenize(try router.splitScript("write -f utf8 fff1 'a;b'; help")[0]),
                       ["write", "-f", "utf8", "fff1", "a;b"])
    }

    // MARK: - Basic tokenization

    func testEmptyStringReturnsEmptyArray() throws {
        XCTAssertEqual(try router.tokenize(""), [])
    }

    func testWhitespaceOnlyReturnsEmpty() throws {
        XCTAssertEqual(try router.tokenize("   "), [])
        XCTAssertEqual(try router.tokenize("\t\t"), [])
    }

    func testSingleToken() throws {
        XCTAssertEqual(try router.tokenize("help"), ["help"])
    }

    func testMultipleTokens() throws {
        XCTAssertEqual(try router.tokenize("read -f hex 2A19"), ["read", "-f", "hex", "2A19"])
    }

    func testMultipleSpacesBetweenTokens() throws {
        XCTAssertEqual(try router.tokenize("connect   -n   Thingy"), ["connect", "-n", "Thingy"])
    }

    func testTabSeparation() throws {
        XCTAssertEqual(try router.tokenize("read\t-f\thex"), ["read", "-f", "hex"])
    }

    func testLeadingAndTrailingWhitespace() throws {
        XCTAssertEqual(try router.tokenize("  help  "), ["help"])
    }

    // MARK: - Double-quoted strings

    func testDoubleQuotedString() throws {
        XCTAssertEqual(try router.tokenize("connect -n \"My Device\""), ["connect", "-n", "My Device"])
    }

    func testDoubleQuotedStringWithMultipleWords() throws {
        XCTAssertEqual(try router.tokenize("write fff1 \"hello world\""), ["write", "fff1", "hello world"])
    }

    func testDoubleQuotedEmptyStringDropped() throws {
        // The tokenizer drops empty-string tokens from quoted strings
        XCTAssertEqual(try router.tokenize("periph adv -n \"\""), ["periph", "adv", "-n"])
    }

    func testDoubleQuotedStringAdjacentToToken() throws {
        // Quotes start immediately after another token separator
        XCTAssertEqual(try router.tokenize("-f \"uint8\""), ["-f", "uint8"])
    }

    // MARK: - Single-quoted strings

    func testSingleQuotedString() throws {
        XCTAssertEqual(try router.tokenize("connect -n 'My Device'"), ["connect", "-n", "My Device"])
    }

    func testSingleQuotedStringWithMultipleWords() throws {
        XCTAssertEqual(try router.tokenize("exec 'gatt tree; read 2A19'"), ["exec", "gatt tree; read 2A19"])
    }

    func testSingleQuotedEmptyStringDropped() throws {
        // The tokenizer drops empty-string tokens from quoted strings
        XCTAssertEqual(try router.tokenize("-n ''"), ["-n"])
    }

    // MARK: - Mixed quotes

    func testMixedDoubleAndSingleQuotes() throws {
        // Double-quoted token, then single-quoted token
        let tokens = try router.tokenize("write -f \"uint8\" fff1 'hello'")
        XCTAssertEqual(tokens, ["write", "-f", "uint8", "fff1", "hello"])
    }

    func testSingleQuoteInsideDoubleQuotedString() throws {
        // Single quote is NOT special inside double-quoted string
        XCTAssertEqual(try router.tokenize("connect -n \"O'Brien\""), ["connect", "-n", "O'Brien"])
    }

    func testDoubleQuoteInsideSingleQuotedString() throws {
        // Double quote is NOT special inside single-quoted string
        XCTAssertEqual(try router.tokenize("write fff1 'say \"hi\"'"), ["write", "fff1", "say \"hi\""])
    }

    // MARK: - UUID-like tokens

    func testUUIDToken() throws {
        let uuid = "F3C2A1B0-1234-5678-ABCD-000000000001"
        XCTAssertEqual(try router.tokenize("connect \(uuid)"), ["connect", uuid])
    }

    // MARK: - Flag tokens

    func testFlagTokens() throws {
        XCTAssertEqual(try router.tokenize("scan -w -R -65"), ["scan", "-w", "-R", "-65"])
    }

    func testLongFlagTokens() throws {
        XCTAssertEqual(try router.tokenize("scan --watch --rssi-min -65"), ["scan", "--watch", "--rssi-min", "-65"])
    }
}

// MARK: - Helpers

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}
