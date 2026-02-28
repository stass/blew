import XCTest
@testable import blew

final class TokenizerTests: XCTestCase {

    private var router: CommandRouter {
        CommandRouter(globals: makeGlobals())
    }

    // MARK: - Basic tokenization

    func testEmptyStringReturnsEmptyArray() {
        XCTAssertEqual(router.tokenize(""), [])
    }

    func testWhitespaceOnlyReturnsEmpty() {
        XCTAssertEqual(router.tokenize("   "), [])
        XCTAssertEqual(router.tokenize("\t\t"), [])
    }

    func testSingleToken() {
        XCTAssertEqual(router.tokenize("help"), ["help"])
    }

    func testMultipleTokens() {
        XCTAssertEqual(router.tokenize("read -f hex 2A19"), ["read", "-f", "hex", "2A19"])
    }

    func testMultipleSpacesBetweenTokens() {
        XCTAssertEqual(router.tokenize("connect   -n   Thingy"), ["connect", "-n", "Thingy"])
    }

    func testTabSeparation() {
        XCTAssertEqual(router.tokenize("read\t-f\thex"), ["read", "-f", "hex"])
    }

    func testLeadingAndTrailingWhitespace() {
        XCTAssertEqual(router.tokenize("  help  "), ["help"])
    }

    // MARK: - Double-quoted strings

    func testDoubleQuotedString() {
        XCTAssertEqual(router.tokenize("connect -n \"My Device\""), ["connect", "-n", "My Device"])
    }

    func testDoubleQuotedStringWithMultipleWords() {
        XCTAssertEqual(router.tokenize("write fff1 \"hello world\""), ["write", "fff1", "hello world"])
    }

    func testDoubleQuotedEmptyStringDropped() {
        // The tokenizer drops empty-string tokens from quoted strings
        XCTAssertEqual(router.tokenize("periph adv -n \"\""), ["periph", "adv", "-n"])
    }

    func testDoubleQuotedStringAdjacentToToken() {
        // Quotes start immediately after another token separator
        XCTAssertEqual(router.tokenize("-f \"uint8\""), ["-f", "uint8"])
    }

    // MARK: - Single-quoted strings

    func testSingleQuotedString() {
        XCTAssertEqual(router.tokenize("connect -n 'My Device'"), ["connect", "-n", "My Device"])
    }

    func testSingleQuotedStringWithMultipleWords() {
        XCTAssertEqual(router.tokenize("exec 'gatt tree; read 2A19'"), ["exec", "gatt tree; read 2A19"])
    }

    func testSingleQuotedEmptyStringDropped() {
        // The tokenizer drops empty-string tokens from quoted strings
        XCTAssertEqual(router.tokenize("-n ''"), ["-n"])
    }

    // MARK: - Mixed quotes

    func testMixedDoubleAndSingleQuotes() {
        // Double-quoted token, then single-quoted token
        let tokens = router.tokenize("write -f \"uint8\" fff1 'hello'")
        XCTAssertEqual(tokens, ["write", "-f", "uint8", "fff1", "hello"])
    }

    func testSingleQuoteInsideDoubleQuotedString() {
        // Single quote is NOT special inside double-quoted string
        XCTAssertEqual(router.tokenize("connect -n \"O'Brien\""), ["connect", "-n", "O'Brien"])
    }

    func testDoubleQuoteInsideSingleQuotedString() {
        // Double quote is NOT special inside single-quoted string
        XCTAssertEqual(router.tokenize("write fff1 'say \"hi\"'"), ["write", "fff1", "say \"hi\""])
    }

    // MARK: - UUID-like tokens

    func testUUIDToken() {
        let uuid = "F3C2A1B0-1234-5678-ABCD-000000000001"
        XCTAssertEqual(router.tokenize("connect \(uuid)"), ["connect", uuid])
    }

    // MARK: - Flag tokens

    func testFlagTokens() {
        XCTAssertEqual(router.tokenize("scan -w -R -65"), ["scan", "-w", "-R", "-65"])
    }

    func testLongFlagTokens() {
        XCTAssertEqual(router.tokenize("scan --watch --rssi-min -65"), ["scan", "--watch", "--rssi-min", "-65"])
    }
}

// MARK: - Helpers

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}
