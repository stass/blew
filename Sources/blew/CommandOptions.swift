// The one reader of command-line options for the REPL, `exec` scripts and
// the CommandRouter entry points the ArgumentParser commands and the MCP
// server call. Each command declares its options once, as a
// `CommandSyntax`; `CommandSyntax.parse` walks the arguments once and is the
// only code that decides which token is an option, a value or a positional.

/// One option of a command: its names and whether it takes a value.
struct OptionSpec: Hashable, Sendable {
    enum Arity: Hashable, Sendable {
        /// Takes no value; giving it twice is the same as once.
        case flag
        /// Takes one value; giving it twice is an error.
        case single
        /// Takes one value each time it is given (`-S 180F -S 180A`).
        case repeated
    }

    /// The letter of the short form (`-n`), nil when there is none.
    let short: Character?
    /// The long form with its dashes (`--name`).
    let long: String
    let arity: Arity

    init(_ short: Character?, _ long: String, _ arity: Arity) {
        self.short = short
        self.long = long
        self.arity = arity
    }

    static let id = OptionSpec("i", "--id", .single)
    static let name = OptionSpec("n", "--name", .single)
    static let service = OptionSpec("S", "--service", .repeated)
    static let manufacturer = OptionSpec("m", "--manufacturer", .single)
    static let rssiMin = OptionSpec("R", "--rssi-min", .single)
    static let pick = OptionSpec("p", "--pick", .single)
    /// The device-targeting group (`DeviceTarget`).
    static let targeting: [OptionSpec] = [id, name, service, manufacturer, rssiMin, pick]

    static let format = OptionSpec("f", "--format", .single)
    static let withResponse = OptionSpec("r", "--with-response", .flag)
    static let withoutResponse = OptionSpec("w", "--without-response", .flag)
    static let duration = OptionSpec("d", "--duration", .single)

    static let timeout = OptionSpec("t", "--timeout", .single)
    static let watch = OptionSpec("w", "--watch", .flag)
    static let descriptors = OptionSpec("d", "--descriptors", .flag)
    static let readValues = OptionSpec("r", "--read", .flag)
    static let count = OptionSpec("c", "--count", .single)
    static let background = OptionSpec("b", "--bg", .flag)
    static let config = OptionSpec("c", "--config", .single)
    static let save = OptionSpec("o", "--save", .single)
    static let send = OptionSpec("s", "--send", .repeated)
    static let file = OptionSpec(nil, "--file", .single)
    static let expect = OptionSpec("e", "--expect", .single)
    static let pty = OptionSpec(nil, "--pty", .flag)
    static let listen = OptionSpec("l", "--listen", .single)
    static let bind = OptionSpec(nil, "--bind", .single)
    static let reconnect = OptionSpec(nil, "--reconnect", .flag)
}

/// The options one command accepts. `parse` reads them by these rules:
/// - `--` ends the options; every token after it is positional.
/// - A token that starts with `-`, is longer than `-` and is not a number
///   (`-1.5`) is an option; a bare `-` and a number are positionals. An
///   option the command does not declare is an error, so its value cannot
///   be mistaken for a positional.
/// - An option that takes a value takes the next token, whatever it looks
///   like: in `sub -n -b 2A19` the name is `-b`, and nothing starts in the
///   background. `--long=value` carries its value in the same token.
/// - Short flags combine (`-dr`); an option that takes a value may end the
///   group (`-wR -70`) and takes the next token.
/// - A missing value, a value given to a flag, and a second value of an
///   option that takes one are errors.
struct CommandSyntax: Sendable {
    let options: [OptionSpec]

    init(_ options: [OptionSpec]) {
        precondition(Set(options.map(\.long)).count == options.count, "an option is declared twice")
        let shorts = options.compactMap(\.short)
        precondition(Set(shorts).count == shorts.count, "a short option is declared twice")
        self.options = options
    }

    /// A command without options.
    static let none = CommandSyntax([])

    static func isOption(_ token: String) -> Bool {
        token.count > 1 && token.hasPrefix("-") && Double(token) == nil
    }

    static let endOfOptions = "--"

    func parse(_ args: [String]) throws -> ParsedArguments {
        var parsed = ParsedArguments(syntax: self)
        var tokens = args[...]
        func takeValue(_ option: OptionSpec, as spelled: String) throws -> String {
            guard let value = tokens.popFirst() else { throw InvalidArgument("\(spelled) needs a value") }
            return value
        }
        while let token = tokens.popFirst() {
            if token == Self.endOfOptions {
                parsed.positionals += tokens
                break
            }
            guard Self.isOption(token) else {
                parsed.positionals.append(token)
                continue
            }
            if token.hasPrefix("--") {
                let equals = token.firstIndex(of: "=")
                let spelled = String(token[..<(equals ?? token.endIndex)])
                guard let option = options.first(where: { $0.long == spelled }) else {
                    throw InvalidArgument("unknown option '\(spelled)'")
                }
                if let equals {
                    guard option.arity != .flag else { throw InvalidArgument("\(spelled) takes no value") }
                    try parsed.record(option, String(token[token.index(after: equals)...]))
                } else if option.arity == .flag {
                    parsed.flags.insert(option.long)
                } else {
                    try parsed.record(option, takeValue(option, as: spelled))
                }
                continue
            }
            let letters = Array(token.dropFirst())
            for (index, letter) in letters.enumerated() {
                guard let option = options.first(where: { $0.short == letter }) else {
                    throw InvalidArgument("unknown option '-\(letter)'")
                }
                if option.arity == .flag {
                    parsed.flags.insert(option.long)
                    continue
                }
                guard index == letters.count - 1 else {
                    throw InvalidArgument("-\(letter) takes a value, so it must end '\(token)'")
                }
                try parsed.record(option, takeValue(option, as: "-\(letter)"))
            }
        }
        return parsed
    }
}

/// The options and positionals `CommandSyntax.parse` read from a command's
/// arguments. Asking for an option the syntax does not declare, or for its
/// value in the wrong arity, is a programming error and traps.
struct ParsedArguments {
    let syntax: CommandSyntax
    /// The tokens that are not options or their values, in order.
    fileprivate(set) var positionals: [String] = []
    fileprivate var values: [String: [String]] = [:]
    fileprivate var flags: Set<String> = []

    fileprivate init(syntax: CommandSyntax) { self.syntax = syntax }

    fileprivate mutating func record(_ option: OptionSpec, _ value: String) throws {
        if option.arity == .single, values[option.long] != nil {
            throw InvalidArgument("\(option.long) is given more than once")
        }
        values[option.long, default: []].append(value)
    }

    private func check(_ option: OptionSpec, _ arities: Set<OptionSpec.Arity>) {
        precondition(syntax.options.contains(option), "\(option.long) is not an option of this command")
        precondition(arities.contains(option.arity), "\(option.long) is read with the wrong arity")
    }

    /// The value of an option that takes one; nil when it is absent.
    func value(_ option: OptionSpec) -> String? {
        check(option, [.single])
        return values[option.long]?.first
    }

    /// Every value of a repeatable option, in order.
    func values(_ option: OptionSpec) -> [String] {
        check(option, [.repeated])
        return values[option.long] ?? []
    }

    /// Whether a flag is given.
    func flag(_ option: OptionSpec) -> Bool {
        check(option, [.flag])
        return flags.contains(option.long)
    }
}

// MARK: - The commands' syntaxes

/// The options of every command the router runs, in one place. The
/// ArgumentParser commands and the MCP server build command lines for these
/// syntaxes, so a change here is a change to every front end.
extension CommandSyntax {
    /// The device-targeting options alone (`DeviceTarget`).
    static let targeting = CommandSyntax(OptionSpec.targeting)

    static let scan = CommandSyntax(OptionSpec.targeting + [.timeout, .watch])
    /// `connect [<device>]`.
    static let connect = targeting
    static let read = CommandSyntax(OptionSpec.targeting + [.format])
    static let write = CommandSyntax(OptionSpec.targeting + [.format, .withResponse, .withoutResponse])
    /// `sub` from the REPL, a script or the command line.
    static let sub = CommandSyntax(OptionSpec.targeting + [.format, .duration, .count, .background])
    /// `sub` from the MCP server: no `-b`, so no argument can start a
    /// background subscription that outlives the call.
    static let subForeground = CommandSyntax(OptionSpec.targeting + [.format, .duration, .count])

    /// `gatt`: the options of all its subcommands, read only to find the
    /// subcommand (the first positional); `gattSubcommands` then reads the
    /// arguments again with that subcommand's own options.
    static let gatt = CommandSyntax(OptionSpec.targeting + [.descriptors, .readValues])
    static let gattSubcommands: [String: CommandSyntax] = [
        "svcs": targeting,
        "tree": gatt,
        "chars": CommandSyntax(OptionSpec.targeting + [.readValues]),
        "desc": targeting,
        "info": none,
    ]

    static let periphAdv = CommandSyntax([.config, .name, .service])
    static let periphClone = CommandSyntax(OptionSpec.targeting + [.save])
    /// `periph set` and `periph notify`.
    static let periphValue = CommandSyntax([.format])

    static let nus = CommandSyntax(OptionSpec.targeting + [
        .send, .file, .expect, .duration, .pty, .listen, .bind, .reconnect, .withResponse, .withoutResponse,
    ])
}
