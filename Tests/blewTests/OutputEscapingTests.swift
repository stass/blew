import XCTest
import BLEManager
@testable import blew

/// Untrusted text (device names, values, config strings) on its way to the
/// terminal and into kv records: escaping, kv quoting and column widths.
final class OutputEscapingTests: XCTestCase {

    private func status(name: String, lastError: String? = nil) -> CommandOutput {
        .connectionStatus(ConnectionStatus(
            isConnected: false, deviceId: nil, deviceName: name,
            servicesCount: 0, characteristicsCount: 0, subscriptionsCount: 0,
            lastError: lastError))
    }

    private func device(_ name: String) -> DeviceRow {
        DeviceRow(id: "ID1", name: name, rssi: -50, serviceUUIDs: [], serviceDisplayNames: [])
    }

    private func kv(_ output: CommandOutput) -> String {
        captureFD(STDOUT_FILENO) { KVRenderer(verbosity: 0).render(output) }
    }

    private func text(_ output: CommandOutput) -> String {
        captureFD(STDOUT_FILENO) { TextRenderer(verbosity: 0).render(output) }
    }

    private func assertNoRawControls(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        let bad = s.unicodeScalars.filter { $0.value != 0x0A && mustNotAppearRaw($0) }
        XCTAssertTrue(bad.isEmpty, "raw control or format characters: \(bad.map { String($0.value, radix: 16) })",
                      file: file, line: line)
    }

    // MARK: - kv

    func testKVNewlineInNameCannotForgeARecord() {
        let out = kv(status(name: "x\nconnected=yes"))
        XCTAssertEqual(out.split(separator: "\n", omittingEmptySubsequences: false).count, 2, out)
        XCTAssertTrue(out.hasPrefix("connected=no "), out)
        XCTAssertTrue(out.contains(#"name="x\nconnected=yes""#), out)
    }

    func testKVEscapesTabCarriageReturnAndTrailingBackslash() {
        let out = kv(status(name: "a\tb\rc\\"))
        XCTAssertTrue(out.contains(#"name="a\tb\rc\\""#), out)
    }

    func testKVEscapesQuoteAndBackslashTogether() {
        let out = kv(status(name: #"say \"hi""#))
        XCTAssertTrue(out.contains(#"name="say \\\"hi\"""#), out)
    }

    func testKVEscapesESCAndOSCSequences() {
        let out = kv(status(name: "\u{1B}[31mred\u{1B}]0;title\u{07}"))
        assertNoRawControls(out)
        XCTAssertTrue(out.contains(#"name="\x1b[31mred\x1b]0;title\x07""#), out)
    }

    func testKVEscapesC1BidiAndInvisibleCharacters() {
        let out = kv(status(name: "a\u{9B}b\u{202E}c\u{200B}d\u{E0041}"))
        assertNoRawControls(out)
        XCTAssertTrue(out.contains(#"name="a\u009bb\u202ec\u200bd\U000e0041""#), out)
    }

    func testKVQuotesUnicodeWhitespace() {
        let out = kv(status(name: "x\u{3000}connected=yes"))
        XCTAssertTrue(out.contains("name=\"x\u{3000}connected=yes\""), out)
        XCTAssertTrue(kv(status(name: "a\u{A0}b")).contains("name=\"a\u{A0}b\""))
    }

    func testKVQuotesEqualsSign() {
        let out = kv(status(name: "a=b"))
        XCTAssertTrue(out.contains(#"name="a=b""#), out)
    }

    func testKVKeepsPlainUnicodeBare() {
        let out = kv(status(name: "温度🔥e\u{301}"))
        XCTAssertTrue(out.contains("name=温度🔥e\u{301} "), out)
    }

    func testKVTableRowEscapesName() {
        let out = kv(.devices([device("x\nid=FORGED")]))
        XCTAssertEqual(out.split(separator: "\n").count, 1, out)
        XCTAssertTrue(out.contains(#"name="x\nid=FORGED""#), out)
    }

    func testKVGATTTreeMultiFieldValueIsPrinted() {
        let char = GATTTreeCharacteristic(
            uuid: "2A37", name: "Heart Rate Measurement", properties: ["read"], value: nil,
            valueFields: [LabeledValue(label: "flags", value: "0x00"), LabeledValue(label: "bpm", value: "72")],
            descriptors: [])
        let out = kv(.gattTree([GATTTreeService(uuid: "180D", name: nil, characteristics: [char])]))
        XCTAssertTrue(out.contains(#"value="flags: 0x00 | bpm: 72""#), out)
    }

    func testKVCharacteristicsMultiFieldValueIsPrinted() {
        let row = CharacteristicRow(
            uuid: "2A37", name: nil, properties: ["read"], value: nil,
            valueFields: [LabeledValue(label: "flags", value: "0x00"), LabeledValue(label: "bpm", value: "72")])
        let out = kv(.characteristics([row]))
        XCTAssertTrue(out.contains(#"value="flags: 0x00 | bpm: 72""#), out)
    }

    func testTextCharacteristicsShowsMultiFieldValues() {
        let row = CharacteristicRow(
            uuid: "2A37", name: nil, properties: ["read"], value: nil,
            valueFields: [LabeledValue(label: "flags", value: "0x00"), LabeledValue(label: "bpm", value: "72")])
        let out = text(.characteristics([row]))
        XCTAssertTrue(out.contains("flags: 0x00\n"), out)
        XCTAssertTrue(out.contains("bpm: 72\n"), out)
    }

    func testFormatterKVRecordEscapesNewline() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let out = captureFD(STDOUT_FILENO) { fmt.printRecord(("name", "x\ny=1")) }
        XCTAssertEqual(out, "name=\"x\\ny=1\"\n")
    }

    // MARK: - text

    func testTextDeviceTableEscapesOSC() {
        let out = text(.devices([device("evil\u{1B}]0;pwned\u{07}")]))
        assertNoRawControls(out)
        XCTAssertTrue(out.contains(#"evil\x1b]0;pwned\x07"#), out)
    }

    func testTextEscapesBidiOverrideAndC1() {
        let out = text(status(name: "abc\u{202E}fed\u{85}"))
        assertNoRawControls(out)
        XCTAssertTrue(out.contains(#"abc\u202efed\u0085"#), out)
    }

    func testTextReadValueEscapesNewlineAndESC() {
        let out = text(.readValue(ReadResult(char: "2A00", name: nil, value: "a\nb\u{1B}[2J", format: .utf8)))
        XCTAssertEqual(out, "a\\nb\\x1b[2J\n")
    }

    func testTextLeavesBackslashAlone() {
        let out = text(.readValue(ReadResult(char: "2A00", name: nil, value: #"C:\dir\"#, format: .utf8)))
        XCTAssertEqual(out, "C:\\dir\\\n")
    }

    func testTextGATTTreeEscapesNamesAndFieldValues() {
        let char = GATTTreeCharacteristic(
            uuid: "2A00", name: "n\u{1B}[1m", properties: ["read"], value: nil,
            valueFields: [LabeledValue(label: "a", value: "1\u{07}"), LabeledValue(label: "b", value: "2")],
            descriptors: [DescriptorRow(uuid: "2902", name: "d\u{9D}")])
        let out = text(.gattTree([GATTTreeService(uuid: "180D", name: "s\u{202D}", characteristics: [char])]))
        assertNoRawControls(out)
        for expected in [#"s\u202d"#, #"n\x1b[1m"#, #"a: 1\x07"#, "b: 2", #"d\u009d"#] {
            XCTAssertTrue(out.contains(expected), "missing \(expected) in \(out)")
        }
    }

    func testEveryListedCharacterIsEscapedAndJoinersAreKept() {
        for v in mustNotAppearRawList {
            let s = String(Unicode.Scalar(v)!)
            XCTAssertFalse(TerminalText.escape(s).unicodeScalars.contains { $0.value == v }, String(v, radix: 16))
            XCTAssertFalse(KVText.value(s).unicodeScalars.contains { $0.value == v }, String(v, radix: 16))
        }
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(TerminalText.escape(family), family)
        XCTAssertEqual(TerminalText.escape("a\u{200C}b"), "a\u{200C}b")
    }

    func testNUSDataInTextModeIsWrittenRaw() {
        let bytes = Data([0x1B, 0x5B, 0x32, 0x4A, 0x0A])
        let out = text(.nusData(NUSData(timestamp: "t", data: bytes)))
        XCTAssertEqual(Data(out.utf8), bytes)
    }

    func testTextMessageIsEscaped() {
        let out = text(.message("hi\u{1B}c"))
        XCTAssertEqual(out, "hi\\x1bc\n")
    }

    func testInvalidUTF8ValueIsShownAsHex() {
        let value = DataFormatter.format(Data([0x41, 0xFF, 0x1B]), as: .utf8)
        let out = text(.readValue(ReadResult(char: "2A00", name: nil, value: value, format: .utf8)))
        XCTAssertEqual(out, "41ff1b\n")
    }

    func testUnpairedSurrogateInBridgedNameBecomesReplacementCharacter() {
        let units: [unichar] = [0x41, 0xD800, 0x42]
        let bridged = NSString(characters: units, length: units.count) as String
        let out = kv(status(name: bridged))
        XCTAssertTrue(out.contains("name=A\u{FFFD}B "), out)
    }

    // MARK: - stderr

    func testErrorLineEscapesConfigText() {
        let err = captureFD(STDERR_FILENO) { TextRenderer(verbosity: 0).renderError("bad property \"\u{1B}]0;x\u{07}\"") }
        XCTAssertEqual(err, "Error: bad property \"\\x1b]0;x\\x07\"\n")
        let kvErr = captureFD(STDERR_FILENO) { KVRenderer(verbosity: 0).renderError("a\nError: forged") }
        XCTAssertEqual(kvErr, "Error: a\\nError: forged\n")
    }

    func testInfoAndLiveLinesEscapeDeviceText() {
        let info = captureFD(STDERR_FILENO) { TextRenderer(verbosity: 1).renderInfo("connected to \u{9B}31m") }
        XCTAssertEqual(info, "connected to \\u009b31m\n")
        let live = captureFD(STDERR_FILENO) { KVRenderer(verbosity: 0).renderLive("[2A00] \u{1B}[2J") }
        XCTAssertEqual(live, "\r\u{1B}[K[2A00] \\x1b[2J\r\n")
    }

    func testFormatterPrintErrorEscapes() {
        let fmt = OutputFormatter(format: .text, verbosity: 0)
        let err = captureFD(STDERR_FILENO) { fmt.printError("x\u{1B}y") }
        XCTAssertEqual(err, "Error: x\\x1by\n")
    }

    /// A message of several lines (ArgumentParser's usage error, which
    /// quotes the command line) keeps its line breaks and nothing else.
    func testStderrLinesEscapeEachLine() {
        let err = captureFD(STDERR_FILENO) { StandardErrorLog.write(lines: "Error: bad '\u{1B}]0;x\u{07}'\n\nUsage: blew") }
        XCTAssertEqual(err, "Error: bad '\\x1b]0;x\\x07'\n\nUsage: blew\n")
    }

    /// The live displays write device names only as escaped `TextLine`s; the
    /// only control sequences are their own redraws.
    func testLiveDisplayRedrawsEscapeText() {
        let spinner = captureFD(STDERR_FILENO) { StandardErrorLog.redraw(TextLine("\u{1B}[2J"), styled: false) }
        XCTAssertEqual(spinner, "\r\u{1B}[K\\x1b[2J")
        let lines = [TextLine("a\u{9B}"), TextLine("b")]
        let first = captureFD(STDERR_FILENO) { StandardErrorLog.redraw(lines, replacing: 0, styled: false) }
        XCTAssertEqual(first, "a\\u009b\nb\n")
        let next = captureFD(STDERR_FILENO) { StandardErrorLog.redraw(lines, replacing: 2, styled: false) }
        XCTAssertEqual(next, "\u{1B}[2A\u{1B}[Ja\\u009b\nb\n")
        let erased = captureFD(STDERR_FILENO) { StandardErrorLog.erase(.eraseLinesAbove(0)) }
        XCTAssertEqual(erased, "")
    }

    /// A table's kv keys are its literal headers, lowercased with spaces as `_`.
    func testColumnHeaderKeys() {
        XCTAssertEqual(KVText.records(headers: ["Device ID", "RSSI"], rows: [["a b", "-5"]]),
                       ["device_id=\"a b\" rssi=-5"])
    }

    // MARK: - column widths

    /// The display column where `needle` starts in `line`, counting East
    /// Asian wide characters and emoji as two.
    private func column(of needle: String, in line: String) -> Int? {
        guard let r = line.range(of: needle) else { return nil }
        return String(line[..<r.lowerBound]).reduce(0) { acc, ch in
            let s = ch.unicodeScalars.first!
            let wide = s.properties.isEmojiPresentation || (0x3000...0x9FFF).contains(s.value)
            let zero = s.properties.generalCategory == .nonspacingMark
            return acc + (wide ? 2 : zero ? 0 : 1)
        }
    }

    func testDisplayWidthOfSequences() {
        XCTAssertEqual(TerminalText.width("\u{2764}\u{FE0F}"), 2)       // VS16
        XCTAssertEqual(TerminalText.width("\u{2764}"), 1)                // text default
        XCTAssertEqual(TerminalText.width("1\u{FE0F}\u{20E3}"), 2)      // keycap
        XCTAssertEqual(TerminalText.width("🇯🇵"), 2)                     // flag
        XCTAssertEqual(TerminalText.width("\u{270C}\u{1F3FD}"), 2)      // skin tone
        XCTAssertEqual(TerminalText.width("한"), 2)                       // Hangul syllable
        XCTAssertEqual(TerminalText.width("\u{1100}\u{1161}"), 2)       // L+V jamo
        XCTAssertEqual(TerminalText.width("\u{301}a"), 1)                // leading mark
        XCTAssertEqual(TerminalText.width("\u{3099}"), 0)                // wide-range mark
        XCTAssertEqual(TerminalText.width("\u{200D}"), 0)                // bare ZWJ
        XCTAssertEqual(TerminalText.width("ａ"), 2)                       // fullwidth
        XCTAssertEqual(TerminalText.pad("温度", toWidth: 3), "温度")      // never truncates
    }

    func testTableKeepsEmojiNamesWhole() {
        let table = textTable(headers: ["Name", "RSSI"], rows: [["🔥Lamp", "-50"], ["abc", "-60"]])
        let lines = table.components(separatedBy: "\n")
        XCTAssertTrue(lines[2].hasPrefix("🔥Lamp"), table)
        XCTAssertEqual(column(of: "-50", in: lines[2]), column(of: "-60", in: lines[3]), table)
    }

    func testTableAlignsWideAndCombiningCharacters() {
        let table = textTable(
            headers: ["Name", "RSSI"],
            rows: [["温度计", "-1"], ["e\u{301}e\u{301}", "-2"], ["abcdef", "-3"], ["👨‍👩‍👧", "-4"]])
        let lines = table.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "温度计  -1  ", table)
        XCTAssertEqual(lines[3], "e\u{301}e\u{301}      -2  ", table)
        XCTAssertEqual(lines[4], "abcdef  -3  ", table)
        XCTAssertEqual(lines[5], "👨‍👩‍👧      -4  ", table)
        XCTAssertEqual(lines[1].count, 12, table)
    }

    func testCharacteristicsTableAlignsEmojiName() {
        let rows = [
            CharacteristicRow(uuid: "FFF1", name: "🔥Lamp", properties: ["read"], value: "1", valueFields: nil),
            CharacteristicRow(uuid: "FFF2", name: "ab", properties: ["read"], value: "2", valueFields: nil),
        ]
        let out = text(.characteristics(rows)).components(separatedBy: "\n")
        XCTAssertEqual(out[2], "FFF1  🔥Lamp  read        1", out.joined(separator: "\n"))
        XCTAssertEqual(out[3], "FFF2  ab      read        2", out.joined(separator: "\n"))
    }

    func testTableEscapesCellsBeforeMeasuring() {
        let table = textTable(headers: ["Name", "X"], rows: [["a\u{1B}", "1"], ["abcdef", "2"]])
        let lines = table.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "a\\x1b   1", table)
    }
}

/// Code points that must never appear raw in output, listed by hand rather
/// than derived the way the implementation derives them: ESC, BEL, DEL, C1
/// NEL and CSI, bidi overrides, embeddings and isolates, LRM/RLM, ZWSP,
/// word joiner, BOM, soft hyphen, a tag character, the line and paragraph
/// separators.
private let mustNotAppearRawList: Set<UInt32> = [
    0x1B, 0x07, 0x00, 0x08, 0x0D, 0x09, 0x7F, 0x85, 0x9B, 0x9D,
    0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    0x200E, 0x200F, 0x200B, 0x2060, 0xFEFF, 0x00AD, 0xE0041, 0x2028, 0x2029,
]

private func mustNotAppearRaw(_ s: Unicode.Scalar) -> Bool {
    mustNotAppearRawList.contains(s.value)
}

/// Runs `block` with `fd` redirected to a pipe and returns what it wrote.
func captureFD(_ fd: Int32, _ block: () -> Void) -> String {
    fflush(stdout)
    fflush(stderr)
    let pipe = Pipe()
    let original = dup(fd)
    dup2(pipe.fileHandleForWriting.fileDescriptor, fd)
    block()
    fflush(stdout)
    fflush(stderr)
    dup2(original, fd)
    close(original)
    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        XCTFail("output is not valid UTF-8: \(data.map { String(format: "%02x", $0) }.joined())")
        return ""
    }
    return text
}
