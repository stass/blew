import Foundation

/// UTF-8 decoding of input, which the editor reads one byte at a time.
internal enum UTF8Input {

    /// The result of reading one UTF-8 sequence from the input.
    struct Decoded: Equatable {
        /// The decoded scalar, or nil when the bytes are not valid UTF-8.
        let scalar: Unicode.Scalar?
        /// A byte that ended the sequence early because it is not a
        /// continuation byte. It has been read but not decoded, so the caller
        /// handles it as the next input byte (it may be Enter or Esc).
        let unconsumed: UInt8?
    }

    /// Reads the sequence that `lead` starts, taking continuation bytes from
    /// `next`, which returns nil at end of input. Reads only the bytes the
    /// lead byte announces and stops at the first one that is not a
    /// continuation byte, handing it back; it waits for those bytes, so a lone
    /// lead byte is resolved by the next key. A lead byte that cannot start a
    /// sequence, a missing continuation byte, and an overlong, surrogate or
    /// out-of-range encoding all give a nil scalar.
    static func readSequence(lead: UInt8, next: () throws -> UInt8?) rethrows -> Decoded {
        guard let length = sequenceLength(lead: lead) else {
            return Decoded(scalar: nil, unconsumed: nil)
        }
        var bytes = [lead]
        while bytes.count < length {
            guard let byte = try next() else {
                return Decoded(scalar: nil, unconsumed: nil)
            }
            guard byte & 0xC0 == 0x80 else {
                return Decoded(scalar: nil, unconsumed: byte)
            }
            bytes.append(byte)
        }
        return Decoded(scalar: decode(bytes)?.unicodeScalars.first, unconsumed: nil)
    }

    /// `bytes` as a string, or nil when they are not valid UTF-8.
    static func decode(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        // Decoding replaces each invalid sequence with U+FFFD, so the bytes
        // are valid exactly when they survive the round trip.
        return text.utf8.elementsEqual(bytes) ? text : nil
    }

    /// The length of the sequence a lead byte starts, or nil for a byte that
    /// cannot start one (a continuation byte, or 0xC0, 0xC1, 0xF5-0xFF, which
    /// appear in no valid encoding).
    private static func sequenceLength(lead: UInt8) -> Int? {
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }
}
