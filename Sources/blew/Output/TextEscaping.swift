import Foundation

// The escaping and measuring of untrusted text on its way out of blew.
//
// Names, values and GATT layout from devices, and strings from config files,
// MCP clients and arguments, are untrusted. Each output format has one
// function that every such string passes through before it is written:
//
// - `TerminalText.escape` for text output and for every line on stderr;
// - `KVText.value` for the values of kv records (README, "Key-value output").
//
// Both write the characters listed in `TextEscaping.isEscaped` as escape
// sequences of one syntax, a subset of Go's and Python's string literals:
// `\n`, `\r`, `\t`, `\xHH` below U+0080, `\uHHHH` in the Basic Multilingual
// Plane and `\UHHHHHHHH` above it. Swift strings hold only valid Unicode:
// invalid UTF-8 from a device never becomes one (`DataFormatter` prints
// such a value as hex), and CoreBluetooth names bridged from `NSString`
// carry U+FFFD in place of an unpaired surrogate.

enum TextEscaping {
    /// Whether `scalar` is written as an escape sequence in every format:
    /// C0 controls and DEL, C1 controls, the line and paragraph separators,
    /// and the invisible format characters (general category Cf: the
    /// bidirectional overrides, embeddings and isolates, zero-width space,
    /// soft hyphen, byte order mark, tag characters). Zero-width joiner and
    /// non-joiner stay: emoji sequences and several scripts need them, and
    /// they neither reorder text nor hide it.
    static func isEscaped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
            return true
        case 0x200C, 0x200D:
            return false
        default:
            return scalar.properties.generalCategory == .format
        }
    }

    /// The escape sequence for `scalar`.
    static func sequence(for scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        case "\\": return "\\\\"
        case "\"": return "\\\""
        default: break
        }
        let v = scalar.value
        if v < 0x80 { return "\\x" + hex(v, digits: 2) }
        if v <= 0xFFFF { return "\\u" + hex(v, digits: 4) }
        return "\\U" + hex(v, digits: 8)
    }

    /// `text` with each scalar for which `escape` holds replaced by its
    /// escape sequence.
    static func escaping(_ text: String, where escape: (Unicode.Scalar) -> Bool) -> String {
        guard text.unicodeScalars.contains(where: escape) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if escape(scalar) {
                out.append(contentsOf: sequence(for: scalar).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func hex(_ value: UInt32, digits: Int) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }
}

// MARK: - Terminal text

enum TerminalText {
    /// `text` safe to write to a terminal: every character of
    /// `TextEscaping.isEscaped` becomes an escape sequence. Backslash is
    /// left alone, so a device name `a\b` reads as written.
    static func escape(_ text: String) -> String {
        TextEscaping.escaping(text, where: TextEscaping.isEscaped)
    }

    /// The number of terminal columns `text` takes: two for an East Asian
    /// wide or fullwidth character and for an emoji shown as an emoji, none
    /// for a lone combining mark or format character, one otherwise.
    /// `text` is expected to be escaped already; a control character counts
    /// as zero columns.
    static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    /// `text` followed by spaces up to `columns` terminal columns. Text that
    /// is already as wide or wider is returned whole, never truncated.
    static func pad(_ text: String, toWidth columns: Int) -> String {
        let missing = columns - width(text)
        return missing > 0 ? text + String(repeating: " ", count: missing) : text
    }

    private static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        let props = first.properties
        switch props.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control:
            return 0
        default:
            break
        }
        if props.isEmojiPresentation { return 2 }
        // A text-default emoji shown as an emoji: followed by VARIATION
        // SELECTOR-16 (U+2764 U+FE0F, keycaps), by a skin-tone modifier
        // (U+270C U+1F3FD) or joined into a ZWJ sequence.
        if props.isEmoji && scalars.dropFirst().contains(where: {
            $0 == "\u{FE0F}" || $0 == "\u{200D}" || $0.properties.isEmojiModifier
        }) { return 2 }
        if isWideOrFullwidth(first.value) { return 2 }
        return 1
    }

    /// East Asian Width W and F code points that are not emoji (UAX #11,
    /// EastAsianWidth.txt of Unicode 15.1), merged into blocks: Hangul Jamo initials, CJK
    /// radicals, symbols and punctuation, kana, CJK ideographs and their
    /// extensions, Yi, Hangul syllables, compatibility ideographs, vertical
    /// and small form variants, fullwidth forms, Tangut, Khitan and kana
    /// supplements, and the enclosed ideographic supplement.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
        0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x16FF0...0x16FF1,
        0x17000...0x18CFF, 0x18D00...0x18D08, 0x1AFF0...0x1AFFE, 0x1B000...0x1B2FF,
        0x1F200...0x1F2FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    private static func isWideOrFullwidth(_ value: UInt32) -> Bool {
        wideRanges.contains { $0.contains(value) }
    }
}

// MARK: - kv records

enum KVText {
    /// One kv value as README's "Key-value output" defines it: bare when it
    /// is non-empty and holds no whitespace, `=`, `"`, `\` or escaped
    /// character (any Unicode whitespace quotes, so a parser that splits on
    /// it, such as Python's `str.split()`, still sees one field);
    /// otherwise in double quotes, with `\` and `"` and every character of
    /// `TextEscaping.isEscaped` written as an escape sequence.
    static func value(_ text: String) -> String {
        let needsQuotes = text.isEmpty || text.unicodeScalars.contains { scalar in
            scalar.properties.isWhitespace || scalar == "=" || scalar == "\"" || scalar == "\\"
                || TextEscaping.isEscaped(scalar)
        }
        guard needsQuotes else { return text }
        let body = TextEscaping.escaping(text) { scalar in
            scalar == "\"" || scalar == "\\" || TextEscaping.isEscaped(scalar)
        }
        return "\"" + body + "\""
    }

    /// One kv record: `key=value` pairs separated by one space. Keys are
    /// blew's own names (lowercase letters, digits, `_`) and are not escaped.
    static func record(_ pairs: [(String, String)]) -> String {
        pairs.map { key, value in "\(key)=\(Self.value(value))" }.joined(separator: " ")
    }

    /// A table as kv records, one per row, keyed by the column headers
    /// lowercased with spaces as `_`.
    static func records(headers: [String], rows: [[String]]) -> [String] {
        let keys = headers.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
        return rows.map { record(Array(zip(keys, $0))) }
    }
}
