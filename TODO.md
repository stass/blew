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

- [ ] **S1. Running `sub -b X` again orphans a subscription.**
  `CommandRouter.swift:920-936`, `BLEManager.swift:466-475`,
  `BLEEventProcessor.swift:139-143`. The old task's cleanup removes the new
  task's `backgroundSubTasks` entry, off the main thread. Its
  `onTermination` can nil the new stream and send `setNotifyValue(false)`.
  Afterwards `sub stop` cannot find the subscription, or notifications go
  quiet. A foreground `sub X` during `sub -b X` collides the same way.
- [ ] **S2. Continuation slots are overwritten without resuming the old
  waiter.** `BLEEventProcessor.swift:78-130`. A cancel handler then cancels
  the wrong request. Cancel and register are not atomic
  (`BLEManager.swift:349` and the similar connect, discover, write and
  subscribe paths), so a waiter can be installed after its cancel ran.
- [ ] **S3. A read can return a notification.**
  `BLEEventProcessor.swift:281-287`. Any `didUpdateValue` resolves a pending
  read first.
- [ ] **S4. A cancelled write's late acknowledgement completes the next
  write.** `BLEEventProcessor.swift:289-291`, `BLEManager.swift:397-399`.
  Reads have the same problem.
- [ ] **S5. A scan's timeout task outlives the scan.**
  `BLEManager.swift:97-108`. Interrupt a scan, start another, and the old
  timer stops the new one early. Starting a scan during `watch` replaces the
  stream without finishing it (`:67-79`).
- [ ] **S6. The notification stream is registered only after
  `setNotifyValue` is acknowledged.** `BLEManager.swift:466`. An immediate
  notification is dropped. A disconnect in that window installs a stream that
  never finishes.
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
- [ ] **S11. A registration made after Bluetooth left poweredOn is never
  failed.** `BLEManager.swift:110-153`, `BLEEventProcessor.swift` (the
  `centralStateChanged` case). The processor fails what is registered when
  the state changes, but nothing refuses a later registration: a power-off
  during `closeConnection` lets `beginConnect` install a wait that CoreBluetooth
  never answers, so `connect` exits 4 (timeout) instead of 3. Fix: the
  processor owns the central state under its lock (`BLECentral.cbState`
  reads it) and `beginConnect` and every `set*Continuation` fail at once
  with `BLEError.unavailable(state)` when it is not poweredOn.

### Exit codes and README contract

- [ ] **E1. ArgumentParser usage errors exit 64, not the documented 6.**
  `Blew.swift:55-56`.
- [ ] **E2. Scan and auto-connect map every error to 5.**
  `CommandRouter.swift:217-219`, `:306-308`, `:389-391`. With Bluetooth off
  they should exit 3. They also print the raw enum instead of
  `localizedDescription`. A scan that Bluetooth turning off ends
  (`BLEEventProcessor` finishes the scan stream; `scan -w`, `watch`) prints
  its table and exits 0; it should exit 3. Make the scan stream an
  `AsyncThrowingStream` finished with `bluetoothUnavailable`, as the
  notification stream is, and iterate it with `for try await`.
- [ ] **E4. A short global `-t` with Bluetooth off exits 4 instead of 3.**
  `waitForPoweredOn(5s)` runs inside `waitInterruptible(globals.timeout)`.
  `BLEManager.swift:61-71` also polls the full 5 s instead of failing fast;
  `ensurePoweredOn` (`:43`) is unused.
- [ ] **E7. Invalid option values are silently accepted.**
  `CommandRouter.swift:886`; `Sources/blew/DataFormatter.swift:29-30,59-60`.
  `-c abc` means unlimited. An unknown `-f` means hex. An unknown config
  `format` means hex.

### NUS bridge

- [ ] **N1. `--reconnect` with fixed or piped input exits 0 with data
  unsent.** `Sources/blew/NUS/NUSPort.swift:62,71-81`,
  `Sources/blew/NUS/CommandRouter+NUS.swift:124-125`. After a reconnect the
  input stream is already finished.
- [ ] **N2. No back-pressure from BLE to local input.** `NUSPort.swift:40`,
  `:73`: the `AsyncStream` buffer is unbounded, so memory grows without
  limit for large files and fast TCP or pty clients.
- [ ] **N3. Data to slow TCP or pty clients is dropped silently.**
  `NUSPort.swift:297-313`. Add at least a drop counter and an `nusStatus`
  event.
- [ ] **N4. Reconnect eligibility uses one connection-state sample.**
  `CommandRouter+NUS.swift:260`. A write error that arrives before the
  disconnect callback exits 5 instead of reconnecting.
- [ ] **N5. NUS writes have no operation deadline in the CLI.**
  `CommandRouter+NUS.swift:307-310`. A write with response that the device
  never acknowledges, or a write without response that never gets
  flow-control credit, blocks `blew nus` until Ctrl-C. MCP `ble_nus` calls
  end by their time budget.

### MCP

- [ ] **M3. Deprecated `.text(_:)`.** `MCPServer.swift:250`, `:260`. Use
  `.text(text:annotations:_meta:)`. These are the only build warnings.

### Output

- [ ] **O1. kv output escaping and missing values.**
  `Sources/blew/Output/KVRenderer.swift:84-105,137,170`,
  `Sources/blew/Output/OutputFormatter.swift:57-82`.
  - Newlines, tabs, control characters and backslashes are not escaped, so a
    device name `x\nconnected=yes` forges a record.
  - Decoded multi-field values print no `value=`.
- [ ] **O2. Text output passes device strings raw.** ESC sequences in a
  device name reach the terminal. Error messages do the same with config
  and argument text (`TextRenderer.swift:58`, `KVRenderer.swift:64`): a
  config with `"properties": ["\u001b]0;x\u0007"]` sends an OSC sequence to
  stderr through `PeripheralConfig.describe`, and so do
  `ConfigError.invalidValue` and `periph set`'s "invalid value". The UUID
  error quotes with `String.debugDescription`, which escapes C0 but passes C1
  controls and bidi overrides; it should use the shared escaping function
  once one exists.
- [ ] **O3. Table widths use grapheme counts while `padding(toLength:)`
  counts UTF-16 units.** `OutputFormatter.swift:93-109`,
  `TextRenderer.swift:108-139,216-220`. Names with emoji are truncated, and
  wide characters misalign columns.

### Commands

- [ ] **C1. `exec` splits scripts on `;` inside quotes.**
  `CommandRouter.swift:25`.
- [ ] **C2. `periph clone --save` reports success when the write fails.**
  `CommandRouter.swift:1606-1613` (`try?`).
- [ ] **C8. Option values can become `sub -b`.** `CommandRouter.swift`
  (`runSub`, `backgroundFlags`) tests every argument for `-b` and `--bg`,
  option values included, so in the REPL `sub -n -b 2A19` starts a
  background subscription. MCP calls are immune (`foregroundOnly`), but the
  other MCP builders still pass free text through a command line; build them
  from typed fields, as `ble_nus` does.
- [ ] **C4. Values starting with `-` cannot be written.**
  `CommandRouter.swift:799`, `:804`. `write -f float32le fff1 -1.5` fails,
  even after `--`.
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

### Decoding and code generation

- [ ] **D1. 44 conditional fields are decoded as always present.**
  `Scripts/generate-ble-characteristics.rb:67`. The regex misses "of the
  Flags field" and "of Presence Flags field". This affects 14
  characteristics, including Battery Level Status, Battery Energy Status,
  CGM Status and Blood Pressure Record.
- [ ] **D2. SFLOAT and FLOAT special values ignore the exponent.**
  `Sources/blew/GATTDecoder.swift:224-228`, `:244-248`. 0x17FF shows as NaN
  instead of 20470, and the reserved values are missed.
- [ ] **D3. `shortUUID` drops the upper bits of 32-bit UUIDs.**
  `Sources/blew/BLENames.swift:25-28`. `12342A19` is decoded as Battery
  Level, and so is `12342A19-0000-1000-8000-00805F9B34FB` (`:30-35`). Fix:
  derive it from `BLEUUID.key` (`Sources/BLEManager/BLEUUID.swift`), which
  is 4 digits exactly for a 16-bit UUID.
- [ ] **D4. The characteristics generator reads its YAML in the locale
  encoding.** `Scripts/generate-ble-characteristics.rb:209`, `:214`. This is
  the same bug a3d3d69 fixed in the names script; the build fails under
  `LANG=C` *(plausible)*.

### Peripheral mode

- [ ] **P1. Prepared (long) writes ignore `request.offset`.**
  `BLEPeripheralDelegate.swift:155-167`. Only the last fragment is kept.
  Reads past the end return success with empty data instead of an
  invalid-offset error.
- [ ] **P2. `updateValue` returning false is ignored.**
  `BLEPeripheral.swift:131-133`. Implement
  `peripheralManagerIsReady(toUpdateSubscribers:)`.
- [ ] **P3. `configure` and `startAdvertising` cannot be cancelled.**
  `BLEPeripheral.swift:60`, `:91`. A late callback can start advertising
  after the command reported failure.
- [ ] **P4. Power-state handling is incomplete.**
  `BLEPeripheralDelegate.swift:15,35,66-88`. `stateContinuation` is never
  set. `_isAdvertising` stays true after a power-off. `removeAllSubscribers`
  is never called.

## P2: release hygiene (0.3.0)

- [ ] **R1. The version string is out of date.** `Sources/blew/Blew.swift:16`
  says `0.2.0`; the latest tag is `v0.2.2`. Set it to `0.3.0` for the
  release.
- [ ] **R3. A fresh clone without submodules fails** with a Ruby `ENOENT`
  backtrace. `Plugins/GenerateBLENames/plugin.swift:9-17`,
  `Scripts/generate-ble-names.rb:26`. Check for the submodules with a clear
  message, and document `git submodule update --init` /
  `git clone --recursive` in the README.
- [ ] **R4. Bluetooth usage description** *(plausible)*. `Package.swift:42`
  excludes `Info.plist`, and nothing embeds `NSBluetoothAlwaysUsageDescription`.
  Verify how release binaries get it (e.g. `-sectcreate __TEXT __info_plist`).
- [ ] **R5. README examples use options that don't exist.**
  - `scan … -t 10` (line 921): scan has no `-t`.
  - Global `-n` (lines 117, 654).
  - `-x` (line 117).
  - `-b` in the CLI `sub` synopsis (line 418).
- [ ] **R6. Example configs contain wrong values.**
  `Examples/health-thermometer.json:11` decodes to 10360.38 °C.
  `Examples/blood-pressure.json:11` sets flags 0x16 but is only 5 bytes long.

## P3: later (after 0.3.0)

- [ ] Codegen backslash escaping is a no-op (`gsub("\\", "\\\\")`).
  `generate-ble-characteristics.rb:164`, `generate-ble-names.rb:31`. "CO2
  Concentration" renders a TAB.
- [ ] Codegen emits Swift that doesn't compile for empty input.
  `generate-ble-names.rb:35`, `generate-ble-characteristics.rb:267-269`.
- [ ] GATT flags are taken only from the first boolean field, and truncated
  fields are skipped. `GATTDecoder.swift:107-126`.
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
