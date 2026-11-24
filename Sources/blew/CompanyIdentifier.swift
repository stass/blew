import Foundation

/// A Bluetooth SIG company identifier (Assigned Numbers, section 7.1): the
/// 16-bit number that starts a device's manufacturer data and that `-m`
/// filters by. Names come from CompanyNames.generated.swift, which the
/// GenerateBLENames plugin builds from the SIG's company_identifiers.yaml.
struct CompanyIdentifier: Equatable, ExpressibleByIntegerLiteral {
    let value: UInt16

    init(_ value: UInt16) {
        self.value = value
    }

    init(integerLiteral value: UInt16) {
        self.value = value
    }

    /// The identifier `text` spells: decimal digits ("76") or `0x` and one
    /// to four hex digits ("0x004C"; prefix and digits in either case),
    /// 0 to 65535. Nil for anything else, including signs and spaces.
    init?(parsing text: String) {
        let hexDigits = Set("0123456789abcdefABCDEF")
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            let digits = text.dropFirst(2)
            guard (1...4).contains(digits.count), digits.allSatisfy(hexDigits.contains),
                  let value = UInt16(digits, radix: 16) else { return nil }
            self.value = value
        } else {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt16(text) else { return nil }
            self.value = value
        }
    }

    /// The company the SIG assigned this identifier to; nil when the list
    /// blew was built with has no entry for it.
    var name: String? { CompanyNameData.names[value] }

    /// The identifier as four hex digits: "0x004C".
    var hex: String { String(format: "0x%04X", value) }
}

/// What a device's advertised manufacturer data says about its maker. A
/// device that advertises no manufacturer data has none (`init` gives nil).
enum AdvertisedManufacturer: Equatable {
    /// The company identifier in the first two bytes, little-endian.
    case company(CompanyIdentifier)
    /// Manufacturer data shorter than the two bytes an identifier takes.
    case tooShort(byteCount: Int)

    init?(_ data: Data?) {
        guard let data else { return nil }
        guard data.count >= 2 else {
            self = .tooShort(byteCount: data.count)
            return
        }
        self = .company(CompanyIdentifier(UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8))
    }

    var company: CompanyIdentifier? {
        if case .company(let company) = self { return company }
        return nil
    }
}
