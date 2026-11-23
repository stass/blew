/*
 Copyright (c) 2017, Andy Best <andybest.net at gmail dot com>
 Copyright (c) 2010-2014, Salvatore Sanfilippo <antirez at gmail dot com>
 Copyright (c) 2010-2013, Pieter Noordhuis <pcnoordhuis at gmail dot com>
 
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice,
 this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided with the distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if os(Linux) || os(FreeBSD)
    import Glibc
#else
    import Darwin
#endif
import Foundation

public class LineNoise {
    public enum Mode {
        case unsupportedTTY
        case supportedTTY
        case notATTY
    }

    public let mode: Mode

    /**
     If false (the default) any edits by the user to a line in the history
     will be discarded if the user moves forward or back in the history
     without pressing Enter.  If true, all history edits will be preserved.
     */
    public var preserveHistoryEdits = false

    var history: History = History()
    
    var completionCallback: ((String) -> ([String]))?
    var hintsCallback: ((String) -> (String?, (Int, Int, Int)?))?

    let currentTerm: String

    var tempBuf: String?
    
    let inputFile: Int32
    let outputFile: Int32
    
    // MARK: - Public Interface
    
    /**
     #init
     - parameter inputFile: a POSIX file handle for the input
     - parameter outputFile: a POSIX file handle for the output
     */
    public init(inputFile: Int32 = STDIN_FILENO, outputFile: Int32 = STDOUT_FILENO) {
        self.inputFile = inputFile
        self.outputFile = outputFile

        currentTerm = ProcessInfo.processInfo.environment["TERM"] ?? ""
        if !Terminal.isTTY(inputFile) {
            mode = .notATTY
        }
        else if LineNoise.isUnsupportedTerm(currentTerm) {
            mode = .unsupportedTTY
        }
        else {
            mode = .supportedTTY
        }
    }
    
    /**
     #addHistory
     Adds a string to the history buffer
     - parameter item: Item to add
     */
    public func addHistory(_ item: String) {
        history.add(item)
    }
    
    /**
     #setCompletionCallback
     Adds a callback for tab completion
     - parameter callback: A callback taking the current text and returning an array of Strings containing possible completions
     */
    public func setCompletionCallback(_ callback: @escaping (String) -> ([String]) ) {
        completionCallback = callback
    }
    
    /**
     #setHintsCallback
     Adds a callback for hints as you type
     - parameter callback: A callback taking the current text and optionally returning the hint and a tuple of RGB colours for the hint text
     */
    public func setHintsCallback(_ callback: @escaping (String) -> (String?, (Int, Int, Int)?)) {
        hintsCallback = callback
    }
    
    /**
     #loadHistory
     Loads history from a file and appends it to the current history buffer
     - parameter path: The path of the history file
     - Throws: Can throw an error if the file cannot be found or loaded
     */
    public func loadHistory(fromFile path: String) throws {
        try history.load(fromFile: path)
    }
    
    /**
     #saveHistory
     Saves history to a file
     - parameter path: The path of the history file to save
     - Throws: Can throw an error if the file cannot be written to
     */
    public func saveHistory(toFile path: String) throws {
        try history.save(toFile: path)
    }
    
    /*
     #setHistoryMaxLength
     Sets the maximum amount of items to keep in history. If this limit is reached, the oldest item is discarded when a new item is added.
     - parameter historyMaxLength: The maximum length of history. Setting this to 0 (the default) will keep 'unlimited' items in history
     */
    public func setHistoryMaxLength(_ historyMaxLength: UInt) {
        history.maxLength = historyMaxLength
    }
    
    /**
     #clearScreen
     Clears the screen.
     - Throws: Can throw an error if the terminal cannot be written to.
     */
    public func clearScreen() throws {
        try output(text: AnsiCodes.homeCursor)
        try output(text: AnsiCodes.clearScreen)
    }
    
    /**
     #getLine
     The main function of Linenoise. Gets a line of input from the user.
     - parameter prompt: The prompt to be shown to the user at the beginning of the line.]
     - Returns: The input from the user
     - Throws: Can throw an error if the terminal cannot be written to.
     */
    public func getLine(prompt: String) throws -> String {
        // If there was any temporary history, remove it
        tempBuf = nil

        switch mode {
        case .notATTY:
            return try readUneditedLine()

        case .unsupportedTTY:
            return try getLineUnsupportedTTY(prompt: prompt)

        case .supportedTTY:
            return try getLineRaw(prompt: prompt)
        }
    }
    
    // MARK: - Terminal handling
    
    private static func isUnsupportedTerm(_ term: String) -> Bool {
        #if os(macOS)
        if let xpcServiceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], xpcServiceName.localizedCaseInsensitiveContains("com.apple.dt.xcode") {
            return true
        }
        #endif
        return ["", "dumb", "cons25", "emacs"].contains(term)
    }
    
    // MARK: - Text input
    /// Reads one byte. Returns nil at end of input and throws when the read
    /// fails.
    internal func readCharacter(inputFile: Int32) throws -> UInt8? {
        var input: UInt8 = 0
        while true {
            let count = read(inputFile, &input, 1)
            if count == 1 {
                return input
            }
            if count == 0 {
                return nil
            }
            if errno != EINTR {
                throw LinenoiseError.generalError("Unable to read input: \(String(cString: strerror(errno)))")
            }
        }
    }

    // MARK: - Text output

    private func output(character: ControlCharacters) throws {
        try output(character: character.character)
    }

    internal func output(character: Character) throws {
        try output(text: String(character))
    }

    /// Writes all of `text`'s UTF-8 bytes.
    internal func output(text: String) throws {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(outputFile, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw LinenoiseError.generalError("Unable to write to output")
            }
            bytes = bytes.dropFirst(written)
        }
    }
    
    // MARK: - Cursor movement
    internal func updateCursorPosition(editState: EditState) throws {
        try output(text: "\r" + AnsiCodes.cursorForward(editState.cursorPosition + editState.prompt.count))
    }
    
    internal func moveLeft(editState: EditState) throws {
        // Left
        if editState.moveLeft() {
            try updateCursorPosition(editState: editState)
        } else {
            try output(character: ControlCharacters.Bell.character)
        }
    }
    
    internal func moveRight(editState: EditState) throws {
        // Left
        if editState.moveRight() {
            try updateCursorPosition(editState: editState)
        } else {
            try output(character: ControlCharacters.Bell.character)
        }
    }
    
    internal func moveHome(editState: EditState) throws {
        if editState.moveHome() {
            try updateCursorPosition(editState: editState)
        } else {
            try output(character: ControlCharacters.Bell.character)
        }
    }
    
    internal func moveEnd(editState: EditState) throws {
        if editState.moveEnd() {
            try updateCursorPosition(editState: editState)
        } else {
            try output(character: ControlCharacters.Bell.character)
        }
    }
    
    internal func getCursorXPosition(inputFile: Int32, outputFile: Int32) -> Int? {
        do {
            try output(text: AnsiCodes.cursorLocation)
        } catch {
            return nil
        }
        
        // The reply is ESC [ rows ; cols R.
        var buf = [UInt8]()
        while true {
            guard let c = try? readCharacter(inputFile: inputFile) else {
                return nil
            }
            if c == 82 { // "R"
                break
            }
            buf.append(c)
        }

        // Check the first characters are the escape code
        if !buf.starts(with: [0x1B, 0x5B]) {
            return nil
        }

        let positionText = String(bytes: buf[2...], encoding: .utf8)
        guard let rowCol = positionText?.split(separator: ";") else {
            return nil
        }
        
        if rowCol.count != 2 {
            return nil
        }
        
        return Int(String(rowCol[1]))
    }
    
    internal func getNumCols() -> Int {
        var winSize = winsize()
        
        if ioctl(1, UInt(TIOCGWINSZ), &winSize) == -1 || winSize.ws_col == 0 {
            // Couldn't get number of columns with ioctl
            guard let start = getCursorXPosition(inputFile: inputFile, outputFile: outputFile) else {
                return 80
            }
            
            do {
                try output(text: AnsiCodes.cursorForward(999))
            } catch {
                return 80
            }
            
            guard let cols = getCursorXPosition(inputFile: inputFile, outputFile: outputFile) else {
                return 80
            }
            
            // Restore original cursor position
            do {
                try output(text: "\r" + AnsiCodes.cursorForward(start))
            } catch {
                // Can't recover from this
            }
            
            return cols
        } else {
            return Int(winSize.ws_col)
        }
    }
    
    // MARK: - Buffer manipulation
    internal func refreshLine(editState: EditState) throws {
        var commandBuf = "\r"                // Return to beginning of the line
        commandBuf += editState.prompt
        commandBuf += editState.buffer
        commandBuf += try refreshHints(editState: editState)
        commandBuf += AnsiCodes.eraseRight
        
        // Put the cursor in the original position
        commandBuf += "\r"
        commandBuf += AnsiCodes.cursorForward(editState.cursorPosition + editState.prompt.count)
        
        try output(text: commandBuf)
    }
    
    internal func insertCharacter(_ char: Character, editState: EditState) throws {
        editState.insertCharacter(char)
        try refreshLine(editState: editState)
    }
    
    internal func deleteCharacter(editState: EditState) throws {
        if !editState.deleteCharacter() {
            try output(character: ControlCharacters.Bell.character)
        } else {
            try refreshLine(editState: editState)
        }
    }
    
    // MARK: - Completion
    
    internal func completeLine(editState: EditState) throws -> UInt8? {
        if completionCallback == nil {
            return nil
        }
        
        let completions = completionCallback!(editState.buffer)
        
        if completions.count == 0 {
            try output(character: ControlCharacters.Bell.character)
            return nil
        }
        
        var completionIndex = 0
        
        // Loop to handle inputs
        while true {
            if completionIndex < completions.count {
                try editState.withTemporaryState {
                    editState.replaceText(completions[completionIndex])
                    
                    try refreshLine(editState: editState)
                }
                
            } else {
                try refreshLine(editState: editState)
            }
            
            guard let char = try readCharacter(inputFile: inputFile) else {
                return nil
            }

            switch char {
            case ControlCharacters.Tab.rawValue:
                // Move to next completion
                completionIndex = (completionIndex + 1) % (completions.count + 1)
                if completionIndex == completions.count {
                    try output(character: ControlCharacters.Bell.character)
                }
                
            case ControlCharacters.Esc.rawValue:
                // Show the original buffer
                if completionIndex < completions.count {
                    try refreshLine(editState: editState)
                }
                return char
                
            default:
                // Update the buffer and return
                if completionIndex < completions.count {
                    editState.replaceText(completions[completionIndex])
                }
                
                return char
            }
        }
    }
    
    // MARK: - History
    
    internal func moveHistory(editState: EditState, direction: History.HistoryDirection) throws {
        // If we're at the end of history (editing the current line),
        // push it into a temporary buffer so it can be retreived later.
        if history.currentIndex == history.historyItems.count {
            tempBuf = editState.buffer
        }
        else if preserveHistoryEdits {
            history.replaceCurrent(editState.buffer)
        }
        
        if let historyItem = history.navigateHistory(direction: direction) {
            editState.replaceText(historyItem)
            try refreshLine(editState: editState)
        } else {
            if case .next = direction {
                editState.replaceText(tempBuf ?? "")
                try refreshLine(editState: editState)
            } else {
                try output(character: ControlCharacters.Bell.character)
            }
        }
    }
    
    // MARK: - Hints
    
    internal func refreshHints(editState: EditState) throws -> String {
        if hintsCallback != nil {
            var cmdBuf = ""
            
            let (hintOpt, color) = hintsCallback!(editState.buffer)
            
            guard let hint = hintOpt else {
                return ""
            }
            
            let currentLineLength = editState.prompt.count + editState.characters.count
            
            let numCols = getNumCols()
            
            // Don't display the hint if it won't fit.
            if hint.count + currentLineLength > numCols {
                return ""
            }
            
            let colorSupport = Terminal.termColorSupport(termVar: currentTerm)
            
            var outputColor = 0
            if color == nil {
                outputColor = 37
            } else {
                outputColor = Terminal.closestColor(to: color!,
                                                    withColorSupport: colorSupport)
            }
            
            switch colorSupport {
            case .standard:
                cmdBuf += AnsiCodes.termColor(color: (outputColor & 0xF) + 30, bold: outputColor > 7)
            case .twoFiftySix:
                cmdBuf += AnsiCodes.termColor256(color: outputColor)
            }
            cmdBuf += hint
            cmdBuf += AnsiCodes.origTermColor
            
            return cmdBuf
        }
        
        return ""
    }
    
    // MARK: - Line editing
    
    /// Reads a line without editing it: the bytes up to a newline, without
    /// the newline or a carriage return before it. A last line that has no
    /// newline is returned at end of input, and end of input after that
    /// throws `EOF`. Reads one byte at a time, so nothing after the newline
    /// is consumed. A line that is not valid UTF-8 throws `invalidUTF8`.
    internal func readUneditedLine() throws -> String {
        var bytes: [UInt8] = []
        while true {
            guard let byte = try readCharacter(inputFile: inputFile) else {
                if bytes.isEmpty {
                    throw LinenoiseError.EOF
                }
                break
            }
            if byte == UInt8(ascii: "\n") {
                break
            }
            bytes.append(byte)
        }
        if bytes.last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        guard let line = UTF8Input.decode(bytes) else {
            throw LinenoiseError.invalidUTF8
        }
        return line
    }

    internal func getLineRaw(prompt: String) throws -> String {
        var line: String = ""

        try Terminal.withRawMode(inputFile) {
            line = try editLine(prompt: prompt)
        }
        // Raw mode does not echo the Enter that ended the line. The terminal
        // is back in cooked mode, so this newline also returns the carriage.
        try output(text: "\n")

        return line
    }

    internal func getLineUnsupportedTTY(prompt: String) throws -> String {
        try output(text: prompt)
        return try readUneditedLine()
    }

    /// Reads one byte of an escape sequence; end of input ends the line.
    private func readEscapeByte() throws -> UInt8 {
        guard let byte = try readCharacter(inputFile: inputFile) else {
            throw LinenoiseError.EOF
        }
        return byte
    }

    internal func handleEscapeCode(editState: EditState) throws {
        var seq: [UInt8] = [0, 0, 0]
        seq[0] = try readEscapeByte()
        seq[1] = try readEscapeByte()
        
        var seqStr = seq.map { Character(UnicodeScalar($0)) }
        
        if seqStr[0] == "[" {
            if seqStr[1] >= "0" && seqStr[1] <= "9" {
                // Handle multi-byte sequence ^[[0...
                seq[2] = try readEscapeByte()
                seqStr = seq.map { Character(UnicodeScalar($0)) }
                
                if seqStr[2] == "~" {
                    switch seqStr[1] {
                    case "1", "7":
                        try moveHome(editState: editState)
                    case "3":
                        // Delete
                        try deleteCharacter(editState: editState)
                    case "4":
                        try moveEnd(editState: editState)
                    default:
                        break
                    }
                }
            } else {
                // ^[...
                switch seqStr[1] {
                case "A":
                    try moveHistory(editState: editState, direction: .previous)
                case "B":
                    try moveHistory(editState: editState, direction: .next)
                case "C":
                    try moveRight(editState: editState)
                case "D":
                    try moveLeft(editState: editState)
                case "H":
                    try moveHome(editState: editState)
                case "F":
                    try moveEnd(editState: editState)
                default:
                    break
                }
            }
        } else if seqStr[0] == "O" {
            // ^[O...
            switch seqStr[1] {
            case "H":
                try moveHome(editState: editState)
            case "F":
                try moveEnd(editState: editState)
            default:
                break
            }
        }
    }
    
    internal func handleCharacter(_ char: UInt8, editState: EditState) throws -> String? {
        switch char {
            
        case ControlCharacters.Enter.rawValue:
            return editState.buffer
            
        case ControlCharacters.Ctrl_A.rawValue:
            try moveHome(editState: editState)
            
        case ControlCharacters.Ctrl_E.rawValue:
            try moveEnd(editState: editState)
            
        case ControlCharacters.Ctrl_B.rawValue:
            try moveLeft(editState: editState)
            
        case ControlCharacters.Ctrl_C.rawValue:
            // Throw an error so that CTRL+C can be handled by the caller
            throw LinenoiseError.CTRL_C
            
        case ControlCharacters.Ctrl_D.rawValue:
            // If there is a character at the right of the cursor, remove it
            // If the cursor is at the end of the line, act as EOF
            if !editState.deleteCharacter() {
                if editState.characters.isEmpty {
                    throw LinenoiseError.EOF
                } else {
                    try output(character: .Bell)
                }
            } else {
                try refreshLine(editState: editState)
            }
            
        case ControlCharacters.Ctrl_P.rawValue:
            // Previous history item
            try moveHistory(editState: editState, direction: .previous)
            
        case ControlCharacters.Ctrl_N.rawValue:
            // Next history item
            try moveHistory(editState: editState, direction: .next)
            
        case ControlCharacters.Ctrl_L.rawValue:
            // Clear screen
            try clearScreen()
            try refreshLine(editState: editState)
            
        case ControlCharacters.Ctrl_T.rawValue:
            if !editState.swapCharacterWithPrevious() {
                try output(character: .Bell)
            } else {
                try refreshLine(editState: editState)
            }
            
        case ControlCharacters.Ctrl_U.rawValue:
            // Delete whole line
            editState.replaceText("")
            try refreshLine(editState: editState)
            
        case ControlCharacters.Ctrl_K.rawValue:
            // Delete to the end of the line
            if !editState.deleteToEndOfLine() {
                try output(character: .Bell)
            }
            try refreshLine(editState: editState)
            
        case ControlCharacters.Ctrl_W.rawValue:
            // Delete previous word
            if !editState.deletePreviousWord() {
                try output(character: .Bell)
            } else {
                try refreshLine(editState: editState)
            }
            
        case ControlCharacters.Ctrl_H.rawValue,
             ControlCharacters.Backspace.rawValue:
            if editState.backspace() {
                try refreshLine(editState: editState)
            } else {
                try output(character: .Bell)
            }
            
        case ControlCharacters.Esc.rawValue:
            try handleEscapeCode(editState: editState)
            
        default:
            // Insert character
            try insertCharacter(Character(UnicodeScalar(char)), editState: editState)
        }

        return nil
    }

    /// Edits a line in raw mode. Keys arrive as bytes: an ASCII byte is a
    /// character or a control key for `handleCharacter`, and a byte from
    /// 0x80 up starts a UTF-8 sequence, which is decoded and inserted.
    internal func editLine(prompt: String) throws -> String {
        try output(text: prompt)

        let editState: EditState = EditState(prompt: prompt)
        // A byte that ended an invalid UTF-8 sequence, read but not handled.
        var unhandled: UInt8?

        while true {
            var char: UInt8
            if let pending = unhandled {
                char = pending
                unhandled = nil
            } else {
                guard let read = try readCharacter(inputFile: inputFile) else {
                    throw LinenoiseError.EOF
                }
                char = read
            }

            if char == ControlCharacters.Tab.rawValue && completionCallback != nil {
                if let completionChar = try completeLine(editState: editState) {
                    char = completionChar
                }
            }

            if char >= 0x80 {
                let sequence = try UTF8Input.readSequence(lead: char) {
                    try readCharacter(inputFile: inputFile)
                }
                unhandled = sequence.unconsumed
                if let scalar = sequence.scalar {
                    try insertCharacter(Character(scalar), editState: editState)
                } else {
                    try output(character: .Bell)
                }
                continue
            }

            if let rv = try handleCharacter(char, editState: editState) {
                return rv
            }
        }
    }
}
