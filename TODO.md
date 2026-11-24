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

### Commands

- [ ] **C8. Option values can become `sub -b`.** `CommandRouter.swift`
  (`runSub`, `backgroundFlags`) tests every argument for `-b` and `--bg`,
  option values and arguments after `--` included, so in the REPL
  `sub -n -b 2A19` starts a background subscription. MCP calls are immune
  (`foregroundOnly`), but the other MCP builders still pass free text
  through a command line; build them from typed fields, as `ble_nus` does.
- [ ] **C9. Option values have two strict readers and a lenient one.**
  `DeviceSelection.swift:59` (`DeviceTarget.parse`, its local `value` and
  `values`) repeats `CommandRouter.optionValue`/`optionValues`, messages
  included; a change to one (say `--long=value`) leaves targeting and
  command options disagreeing. `parseAllStringOptions` still drops a
  missing value: `periph adv -n foo -S` (`CommandRouter.swift:1555`)
  advertises with no service instead of exiting 6. `parseStringOption`,
  `parseIntOption` and `parseDoubleOption` have no production caller.
  Fix: one static reader that `DeviceTarget.parse` calls, `periph adv -S`
  on `optionValues`, and delete the lenient helpers and their tests.
- [ ] **C10. Two ways to fail a command before it starts.**
  `CommandRouter.invalidArguments("\(error)")` (for example in `runRead`
  and `runSub`) sets exit 6 whatever the error and formats it with
  `"\(error)"`; `CommandResult(failing:)` (`ExitCodes.swift`) maps the
  error by type. Every caught error there is an `InvalidArgument` today,
  so the codes agree, but a new error type thrown there exits 6 when its
  type says otherwise. Fix: catch blocks use `CommandResult(failing:)`;
  `invalidArguments` keeps only literal messages.

### Peripheral mode

- [ ] **P5. A callback CoreBluetooth never sends for an undone request
  desynchronises the callback FIFO.** `PendingCallbacks.swift` (`complete`),
  `BLEPeripheralDelegate.swift` (`peripheralManagerDidStartAdvertising`,
  `didAdd`). A request cancelled after it was issued stays queued as
  abandoned, on the assumption that CoreBluetooth still answers it once
  after `stopAdvertising` / `removeAllServices` *(plausible)*. If it does
  not, the next request's callback is taken for the abandoned one: in the
  REPL, after one `periph adv` times out, every later `periph adv` times
  out too until Bluetooth is power-cycled. Confirm the behaviour on a
  radio; if confirmed, give abandoned entries a deadline.

## P2: release hygiene (0.3.0)

- [ ] **R1. The version string is out of date.** `Sources/blew/Blew.swift:16`
  says `0.2.0`; the latest tag is `v0.2.2`. Set it to `0.3.0` for the
  release.

## P3: later (after 0.3.0)

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
