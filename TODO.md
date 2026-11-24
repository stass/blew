# TODO

Issues found by the pre-release review of 2026-11-23 (four Claude
reviewers by area and one Codex review, findings merged). Each entry
gives the location, the defect, and a failure scenario. Entries marked
*(plausible)* depend on CoreBluetooth or macOS runtime behaviour that
was not exercised; confirm them before fixing.

Every bug fix lands with a regression test (see CLAUDE.md).

**Release 0.3.0 targets every item in P0, P1 and P2.** P3 is deferred to a
later release. Delete an item in the commit that fixes it, citing its ID
(e.g. `B4`) in the commit message.

## P0: release blockers (0.3.0)

None open.

## P1: important (0.3.0)

None open.

## P2: release hygiene (0.3.0)

None open.

## P3: later (after 0.3.0)

- [ ] **F1. `read -f`, `sub -f` and `periph set|notify` show a value that does not fit the format as if it did.** `Sources/blew/DataFormatter.swift:50` (`format(_:as:)`) returns `(empty)` or `(insufficient data)` as the value for too few bytes, reads a number from the first bytes of a longer value, and gives hex for invalid UTF-8 under `utf8`. Scenario: `blew -o kv read -f uint16le <char>` on a 5-byte value prints a `value=` from 2 of its bytes and exits 0; on a 1-byte value it prints `value="(insufficient data)"`. `gatt chars|tree -r -f` uses `formatExactly(_:as:)`, which fails such a value; moving these commands to it needs an exit code (or a per-notification marker for `sub`) decided for the mismatch.
- [ ] **P6. `periph adv` without GATT services keeps the previous
  command's services published.** `Sources/blew/CommandRouter.swift:1522`
  calls `configure` only when some service has characteristics, and
  `configure` is what removes the earlier services. Scenario: in the REPL,
  `periph adv -c Examples/health-thermometer.json`, `periph stop`, then
  `periph adv -n Sensor -S 180F`: the Mac advertises only 180F, but a
  central that connects still finds the Health Thermometer service and its
  characteristics, and `periph status` counts them. Unverified on a radio.
  Fix: remove the services whenever `periph adv` starts, or state in
  README.md that they stay until the next configuration.

- [ ] **SG1. A SIGINT's 130 on an MCP call whose budget ran out is
  reported as a timeout.** `Sources/blew/MCP/MCPServer.swift` (`execute`,
  `.budgetExhausted`) rewrites any nonzero code to 4 with "did not finish
  within its budget", and cannot tell a SIGINT's 130 from the budget's own
  stop. Scenario: a call outruns its budget, its last operation still
  succeeds, and a `kill -INT` lands while its span is open:
  `CommandRouter.run(stoppingOn:)` makes the success 130, and the client
  gets 4 and "did not finish" for a call that finished. Related: the stop
  rule counts the `StopRequest`'s reason in `runScriptCommand`
  (`CommandRouter.swift`, `stopRequest?.reason`) but not in
  `run(stoppingOn:)`; no MCP tool runs a script, so the term is unused, but
  a script-running tool would turn a success past its budget into 4 the
  same way. Fix: carry the signal's stop to `execute` beside the result,
  and state the request's stop once (in `MCPServer.execute`).

- [ ] **S15. Every distinct device identifier is kept, without bound.**
  `Sources/BLEManager/BLEDelegate.swift:30` keeps a CBPeripheral for every
  identifier discovered, for the life of the process (never cleared);
  `Sources/blew/DeviceSelection.swift:263` (`ScanResults`), and with it
  `lastScanResults`, keeps a record for every device of one scan; and
  `Sources/BLEManager/ScanStream.swift:100` (`ScanSink.yield`) one per
  unread device. Each is bounded by the number of nearby devices, except
  under an advertisement flood that changes its random address on every
  advertisement (BLE spam tools do this): CoreBluetooth then reports a new
  identifier each time, and a `blew mcp` or REPL session left running next
  to it, or an hours-long `scan -w`, keeps an entry for every one; the
  watch display also falls behind, since a real device's update waits
  behind every newcomer first seen before it. Fix: cap the distinct
  identifiers per scan and evict the delegate's peripherals no connect
  needs, drop and count the newcomers past the cap, and report the count
  as `sub` reports its drops. Whether CoreBluetooth gives each
  non-resolvable random address its own identifier is unverified; settle
  it with a manual check first.
- [ ] **C12. The REPL `help` table is a second copy of the commands'
  syntaxes.** `Sources/blew/CommandRouter.swift` (`printHelp`, the
  `command(..., arguments:)` strings) spells out each command's options by
  hand, beside `CommandSyntax` in `Sources/blew/CommandOptions.swift`. An
  option added to a syntax and not to the string is accepted but missing
  from `help`. Fix: derive the option list from `CommandSyntax.options`.
- [ ] **C11. MCP tools still reach the router through a command line.**
  `MCPServer.swift` (`buildTargetingArgs`, `buildReadArgs`, `buildSubArgs`,
  `buildGATTArgs`, `buildPeriphAdvArgs`, ...) serialize typed tool fields
  into tokens that `CommandSyntax.parse` reads back. The strict reader and
  `--` before free text keep every value where its field says, but each
  builder and the syntax it targets must agree by hand: a builder that
  emits an option the command's syntax lacks fails every call of that tool
  with exit 6. Build typed options per command (as `ble_nus` builds
  `NUSOptions`) and drop the round trip. Until then no test parses every
  builder's line with the syntax its `run*` uses (`MCPTests.swift`,
  `MCPCommandLineTests` parses gatt lines with the union `CommandSyntax.gatt`).
- [ ] **C13. `gatt` subcommands are strings kept in step by hand.**
  `CommandOptions.swift` (`gatt`, `gattSubcommands`), `CommandRouter.swift`
  (`runGATT` switch and usage, `printHelp`). The union syntax must cover
  every subcommand's options, the operand is recovered after connecting with
  a `preconditionFailure`, and `PositionalSpec.word` repeats the dictionary
  key. `sub` and `periph` take their subcommand only as the first token
  (`sub -n foo stop` subscribes to `stop`), unlike `gatt`. Fix: an enum of
  subcommands with its syntax and operand, the union computed from it, one
  subcommand model for `gatt`, `sub` and `periph`.
- [ ] **C14. REPL completion and help keep their own option and operand
  lists.** `REPL/REPL.swift` (`completionPositionalUUID`, `optionsWithValue`),
  `CommandRouter.swift` (`printHelp`). `read -n foo <TAB>` takes `foo` as
  the characteristic and offers nothing; help omits `scan -t`, and its
  operand names (`<char>`, `<data>`) repeat the `PositionalSpec`s. Fix:
  derive both from `CommandSyntax` (its `usage` already renders the
  positionals).
- [ ] **O1. Progress messages appear only when the command ends.**
  `Sources/blew/CommandRouter.swift:531` (and `:1524`, `:1606`, `:1707`)
  appends "connecting to X...", "configuring N service(s)..." and
  "snapshotting GATT tree..." to `result.infos`, which is rendered once the
  command returns. Scenario: `blew -v connect -n <slow device>` shows
  nothing for the seconds the connect takes, then the progress line and the
  result together. Fix: emit progress through the `emit` callback the
  streaming commands already take, as it happens.
- [ ] **O2. Auto-connect discards the connect's messages.** `read`,
  `write`, `sub`, `gatt` and `periph clone` call `ensureConnected` and
  drop its `CommandResult` when it succeeds
  (`Sources/blew/CommandRouter.swift:680`, `:848`, `:910`, `:985`,
  `:1603`). Scenario: `blew -v read -n <device> 2A19` never shows
  "connecting to / connected to", which `blew -v connect` does. Fix: carry
  the successful connect's infos into the command's result (one helper for
  every auto-connecting command).
- [ ] Codegen backslash escaping is a no-op (`gsub("\\", "\\\\")`).
  `generate-ble-characteristics.rb:164`, `generate-ble-names.rb:31`. "CO2
  Concentration" renders a TAB.
- [ ] Many GSS fields name a unit identifier that is not in
  `assigned_numbers/uuids/units.yaml`, so they decode with no unit:
  `length.meter` (2A6C Elevation prints `5.00`, not `5.00 metre`),
  `density.kilogram_per_cubic_meter`, `kelvin_per_second`, `hertz`,
  `standard_acceleration_due_to_gravity`, and others; some name the wrong
  dimension (Luminous Energy: `lumen_per_hour` for lumen hours). A reviewed
  table mapping each to an assigned unit, failing on any new one, would
  restore them. `generate-ble-characteristics.rb:281` (`scale_and_unit`).
- [ ] Three GSS fields contradict their own text, so the generator lists
  them in `CONTRADICTED_SCALES` and they decode raw: High Voltage (b = 6, "a
  resolution of 1/64V"), Activity Goal Distance (d = 1, "a resolution of 1
  m") and Recipe Parameters Temperature Gradient (uint8 with "Minimum:
  -12.8"). Report them to the Bluetooth SIG.
  `generate-ble-characteristics.rb:200` (`CONTRADICTED_SCALES`).
- [ ] Special values the GSS states in other forms ("0 = Year is not known",
  "255: DST offset unknown") are not recognised, so those fields print the
  raw number. The generator parses only the "A value of 0x8000 represents
  ..." sentence form (`generate-ble-characteristics.rb`).
- [ ] A value longer than its structure is decoded without a word about the
  extra bytes (`GATTDecoder.swift:145-175`).
- [ ] Truncated GATT fields are skipped silently. `GATTDecoder.swift:85-98`.
- [ ] An E2E-CRC after a variable-length field is never decoded.
  `GATTDecoder.swift:87-95`. In 2AAC CGM Specific Ops Control Point
  (Operand) and 2B36 Blood Pressure Record (Recorded Characteristic) the
  variable field takes all remaining bytes, so the CRC shows inside its hex
  while `gatt info` lists E2E-CRC as a field of its own.
- [ ] A single field containing " | " is split as several fields.
  `CommandRouter.swift:601-603`, `GATTDecoder.swift:23`.
- [ ] `parseHex` accepts signed tokens ("+f", "-0"). `DataFormatter.swift:71`.
- [ ] Config loading: `fileNotFound` hides permission errors, and
  `Data(contentsOf:)` has no size or file-type check, so an MCP
  `config_file` of `/dev/zero` exhausts memory and a FIFO blocks before any
  deadline. `PeripheralConfig.swift` (`load`). With MCP calls serialized, a
  call blocked there (or on a `save_file` FIFO) stalls every later call, and
  its budget cannot end it: the budget acts only through `waitInterruptible`.
  A cancelled call still waiting its turn also stays suspended until it
  reaches the front of the queue.
- [ ] `periph clone` of a device with the same characteristic UUID in two
  services (two Battery services) collides in the GATT server's tables,
  which are keyed by UUID alone. Config files reject such duplicates.
  `CommandRouter.swift` (`runPeriphClone`), `BLEPeripheral.swift:66-69`.
- [ ] Peripheral configs cannot define descriptors. Decoding rejects every
  `descriptors` entry (`PeripheralTypes.swift`, `CharacteristicDefinition`),
  because 2901 (User Description) and 2904 (Presentation Format) need a
  value and the format has none. Supporting them means a descriptor object
  with a value (a string for 2901, 7 bytes for 2904) in the config.
- [ ] RSSI 127 (unavailable) is treated as the strongest signal and passes
  `-R`. `TextRenderer.swift:327-331`, `CommandRouter.swift:196`.
- [ ] Characteristics are matched by UUID alone, so same-UUID
  characteristics in different services collide. `BLEManager.swift:338-342`,
  `BLEEventProcessor.swift:19-23`.
- [ ] CoreBluetooth objects are read off the `blew.cb` queue.
  `BLEManager.swift:253,288,385,517,532`.
- [ ] Unknown `gatt` subcommands connect first, then fail.
  `CommandRouter.swift:568`, `:703`.
- [ ] `scan -w -t 10` ignores the local `-t` in the REPL and exec.
  `CommandRouter.swift:265`, `:349`.
- [ ] `quit` and `exit` are not recognized in exec.
  `CommandRouter.swift:80-85`.
- [ ] LineNoise key handling:
  - A bare Esc swallows the next two keys (`linenoise.swift:555`).
  - `ESC[1;5C` inserts "5C".
  - Cursor columns count graphemes, not display width (`:234`, `:349`).
    blew's display width is `TerminalText.width`
    (`Sources/blew/Output/TextEscaping.swift`); LineNoise is its own
    target, so the fix moves that function to a target both depend on
    rather than writing a second one, with the terminal size query
    (`linenoise.swift:316` and `StandardErrorLog.terminalColumns`).
- [ ] A `scan -w` frame drawn before the window is made narrower can leave
  stale rows. `Sources/blew/Output/StandardStreams.swift` (`frame`) clips
  each frame to the width at its own redraw, and the next redraw moves up
  one row per line; a terminal that rewraps its screen on resize
  (Terminal.app, iTerm2) gives the old lines more rows than that.
  Scenario: `blew scan -w` at 160 columns, then shrink the window to 80:
  the old frame's extra rows stay on the screen above the table. No more
  pile up once frames are drawn at the new width.
- [ ] A `scan -w` table taller than the terminal piles up partial frames
  in scrollback. `Sources/blew/Output/StandardStreams.swift` (`frame`)
  writes every device row (`CommandRouter.swift` `deviceRows` has no cap);
  once the frame scrolls, the next cursor-up stops at the top row and
  `ESC[J` cannot erase what scrolled off. Scenario: `blew scan -w` with 60
  devices in range in a 40-row window: every 250 ms another partial table
  goes into scrollback. Fix: read `ws_row` with the width and cap the frame
  at `ws_row - 1` lines, the last one saying how many rows are not shown.
- [ ] A `scan -w` row can still wrap where the terminal and
  `TerminalText.width` disagree on a character's width.
  `Sources/blew/Output/TextEscaping.swift` (`width`) counts East Asian
  Ambiguous characters (the `…` that ends a cut row, the `─` rule, the
  spinner's `·`) as one column and ZWJ emoji sequences as two; Terminal.app
  and iTerm2 can show ambiguous characters as two columns, and a terminal
  that measures code points one by one shows ZWJ sequences wider.
  Scenario: `blew scan -w` with "ambiguous characters are wide" set: every
  cut row is one column too wide, wraps, and stale rows pile up. Fix:
  switch autowrap off for the frame (`ESC[?7l` ... `ESC[?7h` in the same
  write), so a row the terminal measures wider is cut by the terminal
  instead of wrapping; that needs autowrap restored on every exit path.
- [ ] LineNoise input hygiene (`linenoise.swift`):
  - Typed or pasted C0 and C1 controls and bidi overrides are inserted and
    echoed raw by `refreshLine` (`:340`); pasting `C2 9B` (8-bit CSI) can
    drive the terminal. Reject them or show them as `^X`.
  - `readUneditedLine` (`:504`) has no line length limit: `blew </dev/zero`
    grows memory until killed.
- [ ] REPL history: `try?` load at `REPL.swift:27`; invalid UTF-8 history
  is overwritten on save.
- [ ] NUS TCP and pty details (`NUSPort.swift`):
  - `isLoopback` matches by name prefix (`:188`).
  - Only the first `getaddrinfo` result is bound (`:203`).
  - `listen(fd, 1)` queues a second client.
  - pty output is buffered while no reader is attached; `ptsname` NULL is
    unchecked (`:117`).
  - Possible fd reuse after close (`:127`, `:181`).
- [ ] The NUS listener is unauthenticated when bound beyond loopback (only a
  warning). `CommandRouter+NUS.swift:214`. The default 127.0.0.1 bind is
  safe.
- [ ] Dead `device_id` positional branch. `MCPServer.swift:284-286`.
