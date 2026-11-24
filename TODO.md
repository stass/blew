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

### Subscriptions and continuations

- [ ] **S13. Notification streams buffer without bound.**
  `BLEManager.swift` (`subscribe`, `AsyncThrowingStream.makeStream()` with the
  default unbounded policy). A device that notifies faster than a subscriber
  reads (a terminal paused with Ctrl-S, `sub` piped to a slow reader) grows
  blew's memory without limit, once per subscriber of the characteristic.
  Fix: bound each stream (`.bufferingNewest(k)`) and report the drops, as
  the NUS bridge does for its input.
- [ ] **S5. A scan's timeout task outlives the scan.**
  `BLEManager.swift:97-108`. Interrupt a scan, start another, and the old
  timer stops the new one early. Starting a scan during `watch` replaces the
  stream without finishing it (`:67-79`).
- [ ] **S8. When the event queue is full, the newest event is dropped
  silently** *(plausible)*. `Sources/BLEManager/BLEEventQueue.swift:42-45`.
  A dropped `didConnect` or `didWriteValue` under an `allowDuplicates` scan
  flood hangs its wait. `droppedCount` is never reported.
- [ ] **S9. `BLECentral.connect` ignores its `timeout` parameter.**
  `Sources/BLEManager/BLEManager.swift:118`. The deadline is enforced only by
  the caller cancelling the task (`CommandRouter.runConnect`,
  `waitInterruptible`), so a caller that relies on the parameter waits
  forever for a device that never appears. Enforce it in `connect` (throwing
  `BLEError.timeout`) or remove the parameter.
- [ ] **S10. Connect attempts are matched by peripheral, not by attempt, and
  `BLECentral` assumes one caller at a time.** `BLEEventProcessor.swift:119`
  (`beginConnect`, `cancelConnect`, `isConnecting`), `BLEManager.swift:149-180`
  and `updateConnection`. Nothing enforces one caller; `waitInterruptible`
  returns after 2 s while the old task may still run. Scenarios: a second
  `connect` reaches `beginConnect` between another's `closeConnection` and
  `beginConnect`, and the replaced device stays connected at the OS level;
  one task's cancel ends another task's connect; a stale `didConnect` of a
  cancelled attempt completes a quick retry to the same device, whose catch
  then disconnects it and its own `didConnect` is dropped. Fix: serialise
  connect and disconnect in `BLECentral`, or give each attempt a token that
  `cancelConnect`, `isConnecting` and `updateConnection` require.
  A connect whose service discovery fails ends the link at once
  (`endConnection`) and queues `cancelPeripheralConnection`; a REPL or MCP
  retry of the same device faster than that disconnect round-trip has its
  connect failed by the old connection's late `didDisconnect` (exit 5).
  `beginDisconnect` (`BLEEventProcessor.swift`) holds one disconnect wait:
  a second concurrent `disconnect` replaces the first, which never resumes,
  and `cancelDisconnectContinuation` cancels whichever wait is held.
- [ ] **S11. A registration made after Bluetooth left poweredOn is never
  failed.** `BLEManager.swift:110-153`, `BLEEventProcessor.swift` (the
  `centralStateChanged` case). The processor fails what is registered when
  the state changes, but nothing refuses a later registration: a power-off
  during `closeConnection` lets `beginConnect` install a wait that CoreBluetooth
  never answers, so `connect` exits 4 (timeout) instead of 3. Fix: the
  processor owns the central state under its lock (`BLECentral.cbState`
  reads it) and `beginConnect`, `beginDisconnect` and `submit` fail at
  once with `BLEError.unavailable(state)` when it is not poweredOn (a GATT
  request whose link already ended fails with `notConnected`, exit 5).
### Exit codes and README contract

- [ ] **E2. A scan that Bluetooth turning off ends exits 0.**
  `BLEEventProcessor` finishes the scan stream without an error, so
  `scan`, `scan -w` and the auto-connect scan (`CommandRouter.swift:273`,
  `:336`, `:380`) end as if their time ran out: `scan -w` prints its table
  and exits 0 instead of 3. Make the scan stream an `AsyncThrowingStream`
  finished with `bluetoothUnavailable`, as the notification stream is, and
  iterate it with `for try await`; the catch blocks already record the
  error with `CommandResult.fail`. `ensurePoweredOn` (`BLEManager.swift:45`)
  is unused; delete it.

### Output

- [ ] **O6. Stream writes outside `Sources/blew/Output` escape per call site.**
  `CommandRouter.swift` prints the `exec --dry-run` listing (script text)
  with `print` and a per-line `TerminalText.escape`, the help listing from
  `OutputFormatter.bold` strings, and the scan spinner and watch display
  straight to stderr; `Blew.swift` writes ArgumentParser's message to
  stderr unescaped. A new `print` there that interpolates device text has
  no guard. kv keys are unescaped `String`s (`KVText.record`), safe only
  while every key is a literal. Fix: route these through `TextLine` and
  `StandardOutput`/`StandardErrorLog`, give kv keys a literal-only type,
  and widen `OutputSourceTests` to `Sources/blew` with an allowlist for the
  REPL's terminal control.

### Commands

- [ ] **C8. Option values can become `sub -b`.** `CommandRouter.swift`
  (`runSub`, `backgroundFlags`) tests every argument for `-b` and `--bg`,
  option values and arguments after `--` included, so in the REPL
  `sub -n -b 2A19` starts a background subscription. MCP calls are immune
  (`foregroundOnly`), but the other MCP builders still pass free text
  through a command line; build them from typed fields, as `ble_nus` does.
- [ ] **C5. An advertised name can capture `-i` and MCP `device_id`.**
  `CommandRouter.swift:1249` (`resolveDevice`), called for `-i` at `:1083`.
  Resolution tries an exact identifier, then a name substring, then an
  identifier fragment, all over `lastScanResults`. Scenario: `read -i
  1234ABCD 2a19` meant as an identifier fragment; a nearby device named
  `1234ABCD` resolves first, and blew connects to it and reads from it. A
  full identifier missing from the last scan can be captured by a device
  whose cached GAP name contains it. Fix: for `-i`, never match names;
  match identifier fragments only, and an input that parses as a UUID only
  exactly.
- [ ] **C6. `-i` does not resolve against the connected device.**
  `CommandRouter.swift:1081-1087`. A name or fragment given to `-i` is
  resolved only against `lastScanResults`. Scenario: `connect -n Thingy`,
  `scan` (the connected Thingy no longer advertises, so it is missing from
  the results), `read -i Thing 2a19`: the fragment does not resolve, fails as
  not found, although the connected device is the one meant; if another
  "Thingy 2" was in the scan, blew switches to it. Fix: move resolution into
  `DeviceSelection.swift` and include the connected device as a candidate.
- [ ] **C7. A device switch by auto-connect is reported only at `-v`.**
  `CommandRouter.swift:1120` uses `renderInfo`; MCP renders nothing, and
  callers drop the `ensureConnected` result on success. Scenario: an MCP
  agent or an `exec` script loses its connection and background
  subscriptions on the old device with no sign in its output. Fix: carry the
  notice in the command's result (MCP `content`) and show it without `-v`.
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

- [ ] Codegen backslash escaping is a no-op (`gsub("\\", "\\\\")`).
  `generate-ble-characteristics.rb:164`, `generate-ble-names.rb:31`. "CO2
  Concentration" renders a TAB.
- [ ] `GATTDecoder` ignores the GSS scale of a value (M, d, b in the
  characteristic's "Represented values"): 2A6E prints `2340` for 23.40 degrees
  C, 2A6F `5812` for 58.12 %, 2A6D `1013250` for 101325.0 Pa
  (`temperature.yaml:46`, `humidity.yaml:46`, `pressure.yaml:46`). Pinned raw
  in `ExampleConfigTests`.
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
