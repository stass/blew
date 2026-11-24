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

### Peripheral mode

- [ ] **P5. An add CoreBluetooth never answers desynchronises the
  service-callback FIFO.** `Sources/BLEManager/PendingCallbacks.swift`
  (`complete`), `Sources/BLEManager/BLEPeripheralDelegate.swift`
  (`peripheralManager(_:didAdd:error:)`), `BLEPeripheral.configure`. A
  request cancelled after it was issued stays queued as abandoned, on the
  assumption that CoreBluetooth still answers it. On a radio (macOS 27,
  the TESTS.md check "Cancelled peripheral requests"), that holds for
  `startAdvertising` followed at once by `stopAdvertising`: 18 of 18 such
  requests got their `didStartAdvertising`. It does not hold for `add`
  followed at once by `removeAllServices`: 0 of 16 got a `didAdd`. The
  next `periph adv -c` then has its `didAdd` taken by the abandoned
  entry, times out after 15 s (exit 4, "advertising failed to start (timed
  out)") and leaves its own entry abandoned, so in the REPL or `blew mcp`
  every later `periph adv -c` with the same service UUID times out until the process restarts. The cancel lands before the
  answer when `configure` times out or is interrupted while CoreBluetooth
  is slow to answer (on an idle Mac `didAdd` comes back within 1 ms, so
  `-t` alone does not reach the window). Fix direction: since
  `removeAllServices` is the undo of every add, have it drop the abandoned
  `addService` entries instead of leaving them to wait for a callback.

## P2: release hygiene (0.3.0)

None open.

## P3: later (after 0.3.0)

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
