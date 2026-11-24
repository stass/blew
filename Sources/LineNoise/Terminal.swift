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

internal struct Terminal {
    
    static func isTTY(_ fileHandle: Int32) -> Bool {
        let rv = isatty(fileHandle)
        return rv == 1
    }
    
    // MARK: Raw Mode

    /// The terminal raw mode was last entered on, and the settings raw
    /// mode replaced while it is on. Every change of terminal mode happens
    /// under `lock`, so a restore from another thread (`restoreForExit`)
    /// cannot interleave with entering or leaving raw mode. Nothing done
    /// under the lock waits on the terminal (see `apply`), so
    /// `restoreForExit` never waits behind output that nobody reads.
    private final class RawModeState: @unchecked Sendable {
        let lock = NSLock()
        /// Kept after raw mode ends: `restoreForExit` discards its unread
        /// input even when a signal comes while a command runs.
        var terminal: Int32?
        var savedSettings: termios?
    }
    private static let rawMode = RawModeState()

    static func withRawMode(_ fileHandle: Int32, body: () throws -> ()) throws {
        if !isTTY(fileHandle) {
            throw LinenoiseError.notATTY
        }

        try enterRawMode(fileHandle)
        defer { leaveRawMode() }

        // Run the body
        try body()
    }

    private static func enterRawMode(_ fileHandle: Int32) throws {
        rawMode.lock.lock()
        defer { rawMode.lock.unlock() }

        var originalTermios: termios = termios()
        if tcgetattr(fileHandle, &originalTermios) == -1 {
            throw LinenoiseError.generalError("Could not get term attributes")
        }

        var raw = originalTermios

        #if os(Linux) || os(FreeBSD)
            raw.c_iflag &= ~UInt32(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
            raw.c_oflag &= ~UInt32(OPOST)
            raw.c_cflag |= UInt32(CS8)
            raw.c_lflag &= ~UInt32(ECHO | ICANON | IEXTEN | ISIG)
        #else
            raw.c_iflag &= ~UInt(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
            raw.c_oflag &= ~UInt(OPOST)
            raw.c_cflag |= UInt(CS8)
            raw.c_lflag &= ~UInt(ECHO | ICANON | IEXTEN | ISIG)
        #endif

        // VMIN = 16
        raw.c_cc.16 = 1

        if !apply(raw, to: fileHandle) {
            // A failed tcsetattr may have applied part of the change.
            _ = apply(originalTermios, to: fileHandle)
            throw LinenoiseError.generalError("Could not set raw mode")
        }
        rawMode.terminal = fileHandle
        rawMode.savedSettings = originalTermios
    }

    private static func leaveRawMode() {
        rawMode.lock.lock()
        defer { rawMode.lock.unlock() }
        restoreSaved()
    }

    /// Put back the settings raw mode replaced. The caller holds `lock`.
    private static func restoreSaved() {
        guard let terminal = rawMode.terminal, let settings = rawMode.savedSettings else { return }
        rawMode.savedSettings = nil
        _ = apply(settings, to: terminal)
    }

    /// Switch the terminal to `settings` at once, keeping unread input:
    /// keys typed while a command runs, or the rest of a pasted block, are
    /// the next prompt's input. `TCSANOW` rather than `TCSADRAIN` or
    /// `TCSAFLUSH`, which first wait for queued output to drain, which
    /// never ends when the terminal's reader has stopped reading. Output
    /// already queued was processed when it was written, so the new
    /// settings do not change it.
    private static func apply(_ settings: termios, to fileHandle: Int32) -> Bool {
        var settings = settings
        return tcsetattr(fileHandle, TCSANOW, &settings) == 0
    }

    /// Restore the terminal for a process that is about to exit, from any
    /// thread, and discard its unread input: keys typed for blew before the
    /// exit must not reach the next reader, the shell. `tcflush` does not wait on the
    /// terminal either. The lock stays held, so no thread enters raw mode
    /// again before the process ends: one that tries blocks until the exit.
    static func restoreForExit() {
        rawMode.lock.lock()
        restoreSaved()
        if let terminal = rawMode.terminal {
            _ = tcflush(terminal, TCIFLUSH)
        }
    }
    
    // MARK: - Colors
    
    enum ColorSupport {
        case standard
        case twoFiftySix
    }
    
    // Colour tables from https://jonasjacek.github.io/colors/
    // Format: (r, g, b)
    
    static let colors: [(Int, Int, Int)] = [
        // Standard
        (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0), (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
        // High intensity
        (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        // 256 color extended
        (0, 0, 0), (0, 0, 95), (0, 0, 135), (0, 0, 175), (0, 0, 215), (0, 0, 255), (0, 95, 0), (0, 95, 95),
        (0, 95, 135), (0, 95, 175), (0, 95, 215), (0, 95, 255), (0, 135, 0), (0, 135, 95), (0, 135, 135),
        (0, 135, 175), (0, 135, 215), (0, 135, 255), (0, 175, 0), (0, 175, 95), (0, 175, 135), (0, 175, 175),
        (0, 175, 215), (0, 175, 255), (0, 215, 0), (0, 215, 95), (0, 215, 135), (0, 215, 175), (0, 215, 215),
        (0, 215, 255), (0, 255, 0), (0, 255, 95), (0, 255, 135), (0, 255, 175), (0, 255, 215), (0, 255, 255),
        (95, 0, 0), (95, 0, 95), (95, 0, 135), (95, 0, 175), (95, 0, 215), (95, 0, 255), (95, 95, 0), (95, 95, 95),
        (95, 95, 135), (95, 95, 175), (95, 95, 215), (95, 95, 255), (95, 135, 0), (95, 135, 95), (95, 135, 135),
        (95, 135, 175), (95, 135, 215), (95, 135, 255), (95, 175, 0), (95, 175, 95), (95, 175, 135), (95, 175, 175),
        (95, 175, 215), (95, 175, 255), (95, 215, 0), (95, 215, 95), (95, 215, 135), (95, 215, 175), (95, 215, 215),
        (95, 215, 255), (95, 255, 0), (95, 255, 95), (95, 255, 135), (95, 255, 175), (95, 255, 215), (95, 255, 255),
        (135, 0, 0), (135, 0, 95), (135, 0, 135), (135, 0, 175), (135, 0, 215), (135, 0, 255), (135, 95, 0), (135, 95, 95),
        (135, 95, 135), (135, 95, 175), (135, 95, 215), (135, 95, 255), (135, 135, 0), (135, 135, 95), (135, 135, 135),
        (135, 135, 175), (135, 135, 215), (135, 135, 255), (135, 175, 0), (135, 175, 95), (135, 175, 135),
        (135, 175, 175), (135, 175, 215), (135, 175, 255), (135, 215, 0), (135, 215, 95), (135, 215, 135),
        (135, 215, 175), (135, 215, 215), (135, 215, 255), (135, 255, 0), (135, 255, 95), (135, 255, 135),
        (135, 255, 175), (135, 255, 215), (135, 255, 255), (175, 0, 0), (175, 0, 95), (175, 0, 135), (175, 0, 175),
        (175, 0, 215), (175, 0, 255), (175, 95, 0), (175, 95, 95), (175, 95, 135), (175, 95, 175), (175, 95, 215),
        (175, 95, 255), (175, 135, 0), (175, 135, 95), (175, 135, 135), (175, 135, 175), (175, 135, 215),
        (175, 135, 255), (175, 175, 0), (175, 175, 95), (175, 175, 135), (175, 175, 175), (175, 175, 215),
        (175, 175, 255), (175, 215, 0), (175, 215, 95), (175, 215, 135), (175, 215, 175), (175, 215, 215),
        (175, 215, 255), (175, 255, 0), (175, 255, 95), (175, 255, 135), (175, 255, 175), (175, 255, 215),
        (175, 255, 255), (215, 0, 0), (215, 0, 95), (215, 0, 135), (215, 0, 175), (215, 0, 215), (215, 0, 255),
        (215, 95, 0), (215, 95, 95), (215, 95, 135), (215, 95, 175), (215, 95, 215), (215, 95, 255), (215, 135, 0),
        (215, 135, 95), (215, 135, 135), (215, 135, 175), (215, 135, 215), (215, 135, 255), (215, 175, 0),
        (215, 175, 95), (215, 175, 135), (215, 175, 175), (215, 175, 215), (215, 175, 255), (215, 215, 0),
        (215, 215, 95), (215, 215, 135), (215, 215, 175), (215, 215, 215), (215, 215, 255), (215, 255, 0),
        (215, 255, 95), (215, 255, 135), (215, 255, 175), (215, 255, 215), (215, 255, 255), (255, 0, 0),
        (255, 0, 95), (255, 0, 135), (255, 0, 175), (255, 0, 215), (255, 0, 255), (255, 95, 0), (255, 95, 95),
        (255, 95, 135), (255, 95, 175), (255, 95, 215), (255, 95, 255), (255, 135, 0), (255, 135, 95),
        (255, 135, 135), (255, 135, 175), (255, 135, 215), (255, 135, 255), (255, 175, 0), (255, 175, 95),
        (255, 175, 135), (255, 175, 175), (255, 175, 215), (255, 175, 255), (255, 215, 0), (255, 215, 95),
        (255, 215, 135), (255, 215, 175), (255, 215, 215), (255, 215, 255), (255, 255, 0), (255, 255, 95),
        (255, 255, 135), (255, 255, 175), (255, 255, 215), (255, 255, 255), (8, 8, 8), (18, 18, 18),
        (28, 28, 28), (38, 38, 38), (48, 48, 48), (58, 58, 58), (68, 68, 68), (78, 78, 78), (88, 88, 88),
        (98, 98, 98), (108, 108, 108), (118, 118, 118), (128, 128, 128), (138, 138, 138), (148, 148, 148),
        (158, 158, 158), (168, 168, 168), (178, 178, 178), (188, 188, 188), (198, 198, 198), (208, 208, 208),
        (218, 218, 218), (228, 228, 228), (238, 238, 238)
    ]
    
    static func termColorSupport(termVar: String) -> ColorSupport {
        // A rather dumb way of detecting colour support
        
        if termVar.contains("256") {
            return .twoFiftySix
        }
        
        return .standard
    }
    
    static func closestColor(to targetColor: (Int, Int, Int), withColorSupport colorSupport: ColorSupport) -> Int {
        let colorTable: [(Int, Int, Int)]
        
        switch colorSupport {
        case .standard:
            colorTable = Array(colors[0..<8])
        case .twoFiftySix:
            colorTable = colors
        }
        
        let distances = colorTable.map {
            sqrt(pow(Double($0.0 - targetColor.0), 2) +
                pow(Double($0.1 - targetColor.1), 2) +
                pow(Double($0.2 - targetColor.2), 2))
        }
        
        var closest = Double.greatestFiniteMagnitude
        var closestIdx = 0
        
        for i in 0..<distances.count {
            if distances[i] < closest  {
                closest = distances[i]
                closestIdx = i
            }
        }
        
        return closestIdx
    }
}
