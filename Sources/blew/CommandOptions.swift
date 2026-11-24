// The one reader of command-line arguments for the REPL, `exec` scripts and
// the CommandRouter entry points the ArgumentParser commands and the MCP
// server call. Each command declares its options and positionals once, as a
// `CommandSyntax`; `CommandSyntax.parse` walks the arguments once and is the
// only code that decides which token is an option, a value or a positional,
// and whether the command has the positionals it takes.

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
    static let save = OptionSpec(nil, "--save", .single)
    static let send = OptionSpec("s", "--send", .repeated)
    static let file = OptionSpec(nil, "--file", .single)
    static let expect = OptionSpec("e", "--expect", .single)
    static let pty = OptionSpec(nil, "--pty", .flag)
    static let listen = OptionSpec("l", "--listen", .single)
    static let bind = OptionSpec(nil, "--bind", .single)
    static let reconnect = OptionSpec(nil, "--reconnect", .flag)
}

/// One positional of a command, in the order the command takes them.
enum PositionalSpec: Hashable, Sendable {
    /// A subcommand word that is a positional of its command, so options
    /// may come before it (`gatt -n foo tree`); the token must be this word.
    case word(String)
    /// An operand the command needs, by the name its usage shows (`char`).
    case required(String)
    /// An operand the command may go without.
    case optional(String)

    /// How the command's usage shows it: `tree`, `<char>`, `[<id>]`.
    var usage: String {
        switch self {
        case .word(let word): word
        case .required(let name): "<\(name)>"
        case .optional(let name): "[<\(name)>]"
        }
    }

    var isWord: Bool {
        if case .word = self { true } else { false }
    }

    /// Whether the command fails without it: a word or a required operand.
    var isRequired: Bool {
        if case .optional = self { false } else { true }
    }

    /// The place of its kind in a command's list: words, then required
    /// operands, then optional ones.
    fileprivate var rank: Int {
        switch self {
        case .word: 0
        case .required: 1
        case .optional: 2
        }
    }
}

/// The options and positionals one command accepts. `parse` reads them by
/// these rules:
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
/// - Fewer positionals than the words and required ones, more than all the
///   declared ones, and a token in place of a word that is not that word are
///   errors that name the command's usage.
struct CommandSyntax: Sendable {
    /// The command as its usage names it (`write`, `sub stop`, `gatt`).
    let command: String
    let options: [OptionSpec]
    let positionals: [PositionalSpec]

    init(_ command: String, _ options: [OptionSpec] = [], positionals: [PositionalSpec] = []) {
        precondition(Set(options.map(\.long)).count == options.count, "an option is declared twice")
        let shorts = options.compactMap(\.short)
        precondition(Set(shorts).count == shorts.count, "a short option is declared twice")
        precondition(positionals.map(\.rank) == positionals.map(\.rank).sorted(),
                     "positionals are declared as words, then required ones, then optional ones")
        self.command = command
        self.options = options
        self.positionals = positionals
    }

    /// `write [options] <char> <data>`, `gatt tree [options]`, `disconnect`.
    var usage: String {
        let words = positionals.filter(\.isWord)
        let operands = positionals.filter { !$0.isWord }
        return ([command] + words.map(\.usage) + (options.isEmpty ? [] : ["[options]"]) + operands.map(\.usage))
            .joined(separator: " ")
    }

    private func usageError(_ message: String) -> InvalidArgument {
        InvalidArgument("\(message) -- usage: \(usage)")
    }

    /// Checks the positionals `parse` read against the declared ones.
    private func checkPositionals(_ tokens: [String]) throws {
        for (spec, token) in zip(positionals, tokens) {
            if case .word(let word) = spec, token != word {
                throw usageError("unexpected argument '\(token)'")
            }
        }
        if tokens.count > positionals.count {
            throw usageError("unexpected argument '\(tokens[positionals.count])'")
        }
        if let missing = positionals.dropFirst(tokens.count).first(where: \.isRequired) {
            throw usageError("missing \(missing.usage)")
        }
    }

    /// The first positional of `args`, read with these options but without
    /// checking the positionals: how a command whose subcommand may follow
    /// options (`gatt -n foo tree`) finds which subcommand's syntax to
    /// `parse` the arguments with. Nil when there is none.
    func subcommand(in args: [String]) throws -> String? {
        try readTokens(args).positionals.first
    }

    func parse(_ args: [String]) throws -> ParsedArguments {
        let parsed = try readTokens(args)
        try checkPositionals(parsed.positionals)
        return parsed
    }

    static func isOption(_ token: String) -> Bool {
        token.count > 1 && token.hasPrefix("-") && Double(token) == nil
    }

    static let endOfOptions = "--"

    /// Reads options and positionals by the rules above, the positionals
    /// unchecked.
    private func readTokens(_ args: [String]) throws -> ParsedArguments {
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
    /// The tokens that are not options or their values, in order: at least
    /// the syntax's words and required positionals, at most all it declares.
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

/// The options and positionals of every command the router runs, in one
/// place. The ArgumentParser commands and the MCP server build command lines
/// for these syntaxes, so a change here is a change to every front end.
extension CommandSyntax {
    /// The device-targeting options alone: blew's global options
    /// (`DeviceTarget`) and the targeting fields of an MCP `ble_nus` call.
    static let targeting = CommandSyntax("blew", OptionSpec.targeting)

    static let scan = CommandSyntax("scan", OptionSpec.targeting + [.timeout, .watch])
    static let connect = CommandSyntax("connect", OptionSpec.targeting, positionals: [.optional("id")])
    static let disconnect = CommandSyntax("disconnect")
    static let status = CommandSyntax("status")
    static let sleep = CommandSyntax("sleep", positionals: [.required("seconds")])

    static let read = CommandSyntax("read", OptionSpec.targeting + [.format], positionals: [.required("char")])
    static let write = CommandSyntax("write", OptionSpec.targeting + [.format, .withResponse, .withoutResponse],
                                     positionals: [.required("char"), .required("data")])
    /// `sub` from the REPL, a script or the command line.
    static let sub = CommandSyntax("sub", OptionSpec.targeting + [.format, .duration, .count, .background],
                                   positionals: [.required("char")])
    /// `sub` from the MCP server: no `-b`, so no argument can start a
    /// background subscription that outlives the call.
    static let subForeground = CommandSyntax("sub", OptionSpec.targeting + [.format, .duration, .count],
                                             positionals: [.required("char")])
    static let subStop = CommandSyntax("sub stop", positionals: [.optional("char")])
    static let subStatus = CommandSyntax("sub status")

    /// `gatt`: the options of all its subcommands, read only to find the
    /// subcommand (`subcommand(in:)`); `gattSubcommands` then reads the
    /// arguments again with that subcommand's own options and positionals.
    static let gatt = CommandSyntax("gatt", OptionSpec.targeting + [.descriptors, .readValues])
    static let gattSubcommands: [String: CommandSyntax] = [
        "svcs": CommandSyntax("gatt", OptionSpec.targeting, positionals: [.word("svcs")]),
        "tree": CommandSyntax("gatt", OptionSpec.targeting + [.descriptors, .readValues],
                              positionals: [.word("tree")]),
        "chars": CommandSyntax("gatt", OptionSpec.targeting + [.readValues],
                               positionals: [.word("chars"), .required("service")]),
        "desc": CommandSyntax("gatt", OptionSpec.targeting, positionals: [.word("desc"), .required("char")]),
        "info": CommandSyntax("gatt", positionals: [.word("info"), .required("char")]),
    ]

    static let periphAdv = CommandSyntax("periph adv", [.config, .name, .service, .timeout])
    static let periphClone = CommandSyntax("periph clone", OptionSpec.targeting + [.save])
    static let periphStop = CommandSyntax("periph stop")
    static let periphStatus = CommandSyntax("periph status")
    /// `periph set` and `periph notify`, which take the same arguments.
    static func periphValue(_ subcommand: PeriphValueSubcommand) -> CommandSyntax {
        CommandSyntax("periph \(subcommand.rawValue)", [.format], positionals: [.required("char"), .required("value")])
    }

    enum PeriphValueSubcommand: String, Sendable {
        case set, notify
    }

    static let nus = CommandSyntax("nus", OptionSpec.targeting + [
        .send, .file, .expect, .duration, .pty, .listen, .bind, .reconnect, .withResponse, .withoutResponse,
    ])
}
