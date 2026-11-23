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

import Foundation

/// The line being edited and the cursor in it.
///
/// The text is held as grapheme clusters (`Character`s), the unit a user sees
/// and edits, and the cursor as an offset into them: 0 is before the first
/// character and `characters.count` after the last. Every edit goes through
/// `setText(head:tail:)`, which rebuilds the text from the part before the
/// cursor and the part after it. Characters that join across that boundary,
/// such as a combining mark typed after its base letter, become one character,
/// so the cursor always sits between two whole characters.
internal class EditState {
    private(set) var characters: [Character] = []
    private(set) var cursorPosition = 0
    let prompt: String

    init(prompt: String) {
        self.prompt = prompt
    }

    /// The text of the line.
    var buffer: String {
        return String(characters)
    }

    var isCursorAtEnd: Bool {
        return cursorPosition == characters.count
    }

    /// Replaces the line with `text` and puts the cursor at its end.
    func replaceText(_ text: String) {
        setText(head: text, tail: "")
    }

    func insertCharacter(_ char: Character) {
        setText(head: text(before: cursorPosition) + String(char), tail: text(from: cursorPosition))
    }

    /// Deletes the character before the cursor.
    func backspace() -> Bool {
        if cursorPosition == 0 {
            return false
        }
        setText(head: text(before: cursorPosition - 1), tail: text(from: cursorPosition))
        return true
    }

    /// Deletes the character under the cursor.
    func deleteCharacter() -> Bool {
        if isCursorAtEnd {
            return false
        }
        setText(head: text(before: cursorPosition), tail: text(from: cursorPosition + 1))
        return true
    }

    func moveLeft() -> Bool {
        if cursorPosition == 0 {
            return false
        }
        cursorPosition -= 1
        return true
    }

    func moveRight() -> Bool {
        if isCursorAtEnd {
            return false
        }
        cursorPosition += 1
        return true
    }

    func moveHome() -> Bool {
        if cursorPosition == 0 {
            return false
        }
        cursorPosition = 0
        return true
    }

    func moveEnd() -> Bool {
        if isCursorAtEnd {
            return false
        }
        cursorPosition = characters.count
        return true
    }

    /// Deletes the spaces before the cursor and the word before them.
    func deletePreviousWord() -> Bool {
        var start = cursorPosition
        while start > 0 && characters[start - 1] == " " {
            start -= 1
        }
        while start > 0 && characters[start - 1] != " " {
            start -= 1
        }
        if start == cursorPosition {
            return false
        }
        setText(head: text(before: start), tail: text(from: cursorPosition))
        return true
    }

    func deleteToEndOfLine() -> Bool {
        if isCursorAtEnd {
            return false
        }
        setText(head: text(before: cursorPosition), tail: "")
        return true
    }

    /// Ctrl-T, as zsh does it: swaps the character before the cursor with the
    /// one under it and moves the cursor right. At the end of the line it
    /// swaps the last two characters; at the start, the first two, leaving the
    /// cursor after them.
    func swapCharacterWithPrevious() -> Bool {
        if characters.count < 2 {
            return false
        }
        let second = min(max(cursorPosition, 1), characters.count - 1)
        var swapped = characters
        swapped.swapAt(second - 1, second)
        setText(head: String(swapped[...second]), tail: String(swapped[(second + 1)...]))
        return true
    }

    func withTemporaryState(_ body: () throws -> () ) throws {
        let originalCharacters = characters
        let originalCursor = cursorPosition

        try body()

        characters = originalCharacters
        cursorPosition = originalCursor
    }

    private func text(before offset: Int) -> String {
        return String(characters[..<offset])
    }

    private func text(from offset: Int) -> String {
        return String(characters[offset...])
    }

    private func setText(head: String, tail: String) {
        characters = Array(head + tail)
        cursorPosition = min(head.count, characters.count)
    }
}
