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

- [ ] **B2. A failed service discovery leaves the state "connected".**
  `BLEManager.swift:154-160`, `:499-541`. `connectedPeripheralId` is set
  before `discoverAllServices`, and nothing rolls it back if discovery throws
  or times out. Auto-connect then returns at once and every operation fails
  with `characteristicNotFound`. The `try? await Task.sleep` at `:512` also
  swallows cancellation.
- [ ] **B3. Bluetooth power-off or loss of authorization fails nothing**
  *(plausible)*. `BLEManager.swift:30-34`,
  `BLEEventProcessor.swift:218-219`. Only `cbState` is recorded. Pending
  continuations are not failed, the scan and notification streams are not
  finished, and the connection state is not cleared. `sub`, `nus` and
  `scan -w` hang, and `status` still says connected.
- [ ] **B4. Scan ignores `-S`, `-m`, `-i` and `-p`.**
  `Sources/blew/CommandRouter.swift:157-221`,
  `BLEManager.swift:88-90` (`withServices: nil`). Those options are parsed
  into `scanOpts` but never used. `connect -S 180F` (a README example) and
  `write -m 89 fff1 01` pick the strongest device of any kind. Bare `nus`
  does not require a device that advertises NUS.
- [ ] **B5. When a device is already connected, auto-connect ignores the
  requested target.** `CommandRouter.swift:1091-1100`, `:407-414`.
  `exec "connect -n A; write -n B fff1 01"` writes to A and exits 0, and
  `connect -n B` while connected to A does nothing. MCP `ble_nus` has the
  same flaw. Fix: compare the target with the connected device; fail, or
  switch devices.
- [ ] **B6. Ctrl-C in one-shot commands bypasses all interrupt handling.**
  `Sources/blew/Blew.swift:65`. `installSignalHandlers` runs only on the REPL
  path. In CLI mode SIGINT kills the process, so there is no exit code 130,
  `cleanupBeforeExit` never runs, and block-buffered stdout is lost
  (`blew -o kv sub … >> log`). `scan -w` never prints its final table.
  `periph adv` and `periph clone` never print their startup summary or
  "Stopped advertising" (`CommandRouter.swift:1469-1524`, `:1634-1686`). Also
  flush stdout per record when it is not a TTY.
- [ ] **B7. Concurrent MCP tool calls race on the shared router and BLE
  state.** `Sources/blew/MCP/MCPServer.swift:54`. The swift-sdk runs each
  request in its own Task. Single-slot continuations
  (`BLEEventProcessor.swift:78-143`) are overwritten, so calls hang.
  `lastScanResults`, `backgroundSubTasks`, `commandIsRunning` and
  `interruptRequested` race. Handlers that block on `DispatchSemaphore` hold
  threads from the cooperative pool; enough stuck calls deadlock the whole
  server *(plausible)*. Fix: serialize `handleToolCall`, and stop blocking
  pool threads on semaphores.
- [ ] **B8. `ble_subscribe` has no deadline and cannot be cancelled.**
  `MCPServer.swift:310-316`, `CommandRouter.swift:965`. With no `duration`
  only `-c 10` is passed, and MCP `notifications/cancelled` does not reach the
  inner Task. `duration: "5"` (a string) passes neither `-c` nor `-d`, so the
  subscription is unbounded. Subscription setup and NUS writes also have no
  operation deadline (`CommandRouter.swift:948`).
- [ ] **B9. LineNoise has no UTF-8 support.**
  - `Sources/LineNoise/linenoise.swift:668` reads each byte as Latin-1, so
    typing `é` sends `C3 83 C2 A9` to the device and saves mojibake to
    history.
  - `:213` writes `text.count` (graphemes) as the byte length, which
    truncates the output and cuts escape sequences.
  - `EditState.swift:179-180`: Ctrl-T next to a multibyte character traps
    (index out of bounds).
  - `EditState.swift:53-67,114`: backspace and delete leave stale indices
    *(plausible)*.
  - Commit a3d3d69 fixed only the names generator script.
- [ ] **B11. `blew -t inf scan -w` crashes.** `CommandRouter.swift:164`,
  `:265`, `:349` → `BLEManager.swift:99`. Watch mode skips
  `isValidDuration`, and `UInt64(inf * 1e9)` traps.

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

### Exit codes and README contract

- [ ] **E1. ArgumentParser usage errors exit 64, not the documented 6.**
  `Blew.swift:55-56`.
- [ ] **E2. Scan and auto-connect map every error to 5.**
  `CommandRouter.swift:217-219`, `:306-308`, `:389-391`. With Bluetooth off
  they should exit 3. They also print the raw enum instead of
  `localizedDescription`.
- [ ] **E3. `sub` exits 0 when the device disconnects.**
  `CommandRouter.swift:945-969`.
- [ ] **E4. A short global `-t` with Bluetooth off exits 4 instead of 3.**
  `waitForPoweredOn(5s)` runs inside `waitInterruptible(globals.timeout)`.
  `BLEManager.swift:61-71` also polls the full 5 s instead of failing fast;
  `ensurePoweredOn` (`:43`) is unused.
- [ ] **E5. SIGTERM exits 0.** `Blew.swift:90-99`. The handlers call
  async-signal-unsafe code (Task, semaphores, print). A SIGINT outside
  `waitInterruptible` `_exit`s the REPL without saving history.
- [ ] **E6. `--pick first` behaves like `strongest`.**
  `CommandRouter.swift:1142-1147`, sort at `:237`.
- [ ] **E7. Invalid option values are silently accepted.**
  `CommandRouter.swift:912`, `:1167`; `Sources/blew/DataFormatter.swift:29-30,59-60`.
  `-p bogus` means strongest. `-c abc` means unlimited. An unknown `-f`
  means hex. An unknown config `format` means hex.

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

### MCP

- [ ] **M1. The MCP server ignores global options.** `MCPServer.swift:19`
  parses `[]` instead of using `GlobalOptions.current`, so `blew -t 30 mcp`
  and `blew -v mcp` have no effect.
- [ ] **M2. The response collector keeps growing after the response
  returns.** `MCPServer.swift:9-12`, `:97`, `CommandRouter.swift:1500`.
  Advertising events keep appending with no lock. `ble_nus` durations of up
  to a year also accumulate without bound.
- [ ] **M3. Deprecated `.text(_:)`.** `MCPServer.swift:147`, `:157`. Use
  `.text(text:annotations:_meta:)`. These are the only build warnings.
- [ ] **M4. `ble_periph_advertise` drops `services` entries that are not
  strings.** `MCPServer.swift:339-343`. `"services": ["180D", 6159]`
  advertises only `180D` and reports success.

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
- [ ] **C3. Non-TTY input loops forever.** `linenoise.swift:499` returns `""`
  instead of reading the line or reporting EOF. `blew </dev/null` spins,
  printing newlines (`Sources/blew/REPL/REPL.swift:28-34`). `readCharacter`
  returns 0 on a read error, which inserts a NUL.
- [ ] **C4. Values starting with `-` cannot be written.**
  `CommandRouter.swift:799`, `:804`. `write -f float32le fff1 -1.5` fails,
  even after `--`.

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
- [ ] **R2. There is no `.gitignore`** (`.build/` shows as untracked).
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
- [ ] **R7. SIGTERM at the prompt leaves the terminal in raw mode.**
  `Blew.swift:89-92`, `Sources/LineNoise/Terminal.swift:47-54`. Also, the
  restore `defer` is registered before `tcgetattr`.

## P3: later (after 0.3.0)

- [ ] Codegen backslash escaping is a no-op (`gsub("\\", "\\\\")`).
  `generate-ble-characteristics.rb:164`, `generate-ble-names.rb:31`. "CO2
  Concentration" renders a TAB.
- [ ] Codegen emits Swift that doesn't compile for empty input.
  `generate-ble-names.rb:35`, `generate-ble-characteristics.rb:267-269`.
- [ ] GATT flags are taken only from the first boolean field, and truncated
  fields are skipped. `GATTDecoder.swift:107-126`.
- [ ] `load(as:)` on possibly misaligned `Data`; use `loadUnaligned`.
  `GATTDecoder.swift:118` and others, `DataFormatter.swift:17-25`.
- [ ] A single field containing " | " is split as several fields.
  `CommandRouter.swift:601-603`, `GATTDecoder.swift:23`.
- [ ] `parseHex` accepts signed tokens ("+f", "-0"). `DataFormatter.swift:71`.
- [ ] Config loading: `fileNotFound` hides permission errors, and
  `Data(contentsOf:)` has no size or file-type check, so an MCP
  `config_file` of `/dev/zero` exhausts memory and a FIFO blocks before any
  deadline. `PeripheralConfig.swift` (`load`).
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
  - A bare Esc swallows the next two keys (`linenoise.swift:526`).
  - `ESC[1;5C` inserts "5C".
  - Cursor columns count graphemes, not display width (`:220`, `:340`).
- [ ] REPL history: `try?` load at `REPL.swift:20`; invalid UTF-8 history
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
