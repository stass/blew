#if MCP_ENABLED
import Foundation
import MCP

/// A tool call's arguments do not match the tool's input schema.
struct ToolArgumentError: Error, Equatable {
    let message: String
}

/// Checks a tool call's arguments against the tool's input schema, the one
/// description of what each tool accepts. Every argument must be a property
/// the schema declares, of the declared JSON type, inside its `enum`,
/// `minimum` and `maximum`; every `required` property must be present.
/// Anything else is an error, never ignored, so the argument builders that
/// run afterwards see only values of the declared types.
enum ToolArguments {
    static func validate(_ args: [String: Value], against schema: Value) throws {
        let schema = schema.objectValue ?? [:]
        let properties = schema["properties"]?.objectValue ?? [:]
        for key in args.keys.sorted() {
            guard let property = properties[key]?.objectValue else {
                throw ToolArgumentError(message: "unknown argument \(key.debugDescription)")
            }
            try check(args[key]!, against: property, name: key)
        }
        for case .string(let key) in schema["required"]?.arrayValue ?? [] where args[key] == nil {
            throw ToolArgumentError(message: "missing required argument '\(key)'")
        }
    }

    private static func check(_ value: Value, against property: [String: Value], name: String) throws {
        let type = property["type"]?.stringValue ?? ""
        switch (type, value) {
        case ("string", .string):
            if let allowed = property["enum"]?.arrayValue, !allowed.contains(value) {
                let names = allowed.compactMap(\.stringValue).joined(separator: ", ")
                throw ToolArgumentError(message: "'\(name)' must be one of: \(names)")
            }
        case ("boolean", .bool):
            break
        case ("integer", .int(let number)):
            try checkRange(Double(number), against: property, name: name)
        case ("number", .int(let number)):
            try checkRange(Double(number), against: property, name: name)
        case ("number", .double(let number)) where number.isFinite:
            try checkRange(number, against: property, name: name)
        case ("array", .array(let items)):
            guard let itemSchema = property["items"]?.objectValue else { break }
            for (index, item) in items.enumerated() {
                try check(item, against: itemSchema, name: "\(name)[\(index)]")
            }
        case ("string", .data):
            // The swift-sdk decodes a JSON string of the form `data:...,...`
            // as a data URL, and the original text is not kept.
            throw ToolArgumentError(message: "'\(name)' must be a string that does not start with a data URL ('data:...,')")
        default:
            throw ToolArgumentError(message: "'\(name)' must be \(describe(type))")
        }
    }

    private static func checkRange(_ number: Double, against property: [String: Value], name: String) throws {
        let minimum = property["minimum"].flatMap(numberValue)
        let maximum = property["maximum"].flatMap(numberValue)
        if let minimum, number < minimum {
            throw ToolArgumentError(message: "'\(name)' must be at least \(format(minimum))")
        }
        if let maximum, number > maximum {
            throw ToolArgumentError(message: "'\(name)' must be at most \(format(maximum))")
        }
    }

    private static func numberValue(_ value: Value) -> Double? {
        switch value {
        case .int(let n): return Double(n)
        case .double(let d): return d
        default: return nil
        }
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    private static func describe(_ type: String) -> String {
        switch type {
        case "integer": return "an integer"
        case "array": return "an array"
        case "": return "a value of the declared type"
        default: return "a \(type)"
        }
    }
}
#endif
