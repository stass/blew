# Testing

## Running tests

```sh
swift test
```

The integration tests require the binary to be built first:

```sh
swift build && swift test
```

## Test location

All tests live in `Tests/blewTests/`. The target is declared in `Package.swift` as a `.testTarget` depending on `blew`, using `@testable import blew` for white-box access.

## Architecture

The test target depends directly on the `blew` executable and uses `@testable import blew` for white-box access. A handful of `CommandRouter` and `BlewMCPServer` helpers are `internal` (rather than `private`) so they can be exercised directly from tests; everything else is accessed through public interfaces or by running the compiled binary as a subprocess.

Tests that instantiate `CommandRouter` use `GlobalOptions.parse([])` to get a properly initialized options struct — ArgumentParser property wrappers require parsing to initialize, so direct construction is not used.

The suite deliberately avoids CoreBluetooth. BLE-dependent paths (scan, connect, read, write, subscribe) are covered only at the ArgumentParser parsing level, not at execution time, since they require hardware.

## Test categories

**Pure data logic**

`DataFormatterTests`, `BLENamesTests`, `GATTDecoderTests` — stateless functions with no I/O. Format and parse all data representations, UUID lookups, GATT characteristic decoding, and the `gatt info` field JSON (each `condition` kind, its omission for unconditional fields, and its round trip). Fast and fully deterministic.

**REPL command parsing**

`TokenizerTests` — unit tests for the internal tokenizer in `CommandRouter`. `CommandOptionsTests` — the option reader (`CommandSyntax.parse`: `--`, numbers, combined flags, missing and repeated values, unknown options) and the commands that use it, which fail on bad options before connecting.

**Line editor**

`LineNoiseTests` — drive the vendored line editor through pipes: raw-mode key handling (UTF-8 input assembly, invalid sequences, Ctrl-T, backspace and delete around multibyte characters), the bytes written to the terminal, and non-TTY input (one line per command, end of input, invalid UTF-8, read errors). A pseudo-terminal checks the newline written after a raw-mode line.

`REPLScriptTests` — the REPL with a pipe as standard input: a script runs to end of input without touching the history, and the first failing command, an invalid UTF-8 line and an unreadable input end it with codes 6, 6 and 5; a Ctrl-C during a line stops the script after it with 130. `CommandSpanTests` — `main` opens an outer span for every command except the REPL and `blew mcp`; a Ctrl-C as one step of a command finishes keeps the next step from starting, and one as a script command finishes stops `exec`, also with `-k`, before the next command.

**Command routing and scripting**

`CommandDispatchTests`, `ExecuteScriptTests` — exercise `CommandRouter.dispatch()` and `executeScript()` using commands that do not require a BLE connection (`help`, `gatt info`, `periph stop/status`, `sub status`, `sleep`). Error paths and exit codes are verified directly.

**Device and service resolution**

`DeviceResolutionTests` — populates `CommandRouter.lastScanResults` with synthetic `DiscoveredDevice` fixtures and exercises the UUID/name matching logic: exact match, substring match, ambiguous match, and not-found.

`DeviceSelectionTests` — device selection without a radio: `DeviceFilter` matching (every service-UUID spelling, all `-S` required, little-endian company ID, id, name and RSSI), rejected targeting values, `PickStrategy.choose` (`first` is the first seen, not the strongest), `ScanResults` merging and first-seen order, `AutoConnectPlan` (use, switch from or ignore the connected device), `scan` arguments rejected before the radio is touched (an unbounded `-t` in watch mode, `-p` with `-w`), and `read`, `write` and `sub` arguments checked before auto-connect.

**Utility functions**

`RSSIBarAndSplitFieldTests` — covers two pure static functions: `rssiBar()` (signal strength bar rendering) and `splitFieldPart()` (GATT field label parsing).

**Configuration**

`PeripheralConfigTests` — JSON decoding of peripheral config files, `resolvedInitialValues()` for all supported data formats, and error handling for missing or malformed files.

`PeripheralUUIDTests` — `BLEUUID` parsing and equality, checked against `CBUUID` equality and `uuidString` (no radio needed); rejection of malformed UUIDs and of descriptors at each peripheral entry point (config file, `periph adv -S`, `periph set`, `ble_periph_advertise`) with exit code 6; and lookups in `GATTStore` and the pending service registrations that match whichever spelling the config used and CoreBluetooth reports.

`PeripheralGATTTests` — the GATT server's answers to a remote central without a radio: reads at, at the end of and past the end of a value (Invalid Offset); long writes assembled from their fragments, a fragment past the end (Invalid Offset) and a value over 512 bytes (Invalid Attribute Value Length), each rejecting the whole request; the bounded notification queue (sent at once, queued in order behind a full transmit queue, drained on ready, rejected when full); the pending-callback FIFO (a cancelled request keeps its place, cancellation before the request is issued stops it); and Bluetooth leaving poweredOn, which fails every pending wait with "Bluetooth is powered off" and empties the notification queue.

**Data model**

`ExitCodeAndTargetingTests` — verifies exit code values and `CustomNSError` conformance, and exercises `DeviceTargetingOptions.toArgs()` serialization for all option combinations.

**Output formatting**

`OutputFormatterTests` — captures stdout via `dup`/`pipe` and verifies KV and text record formatting, table alignment, and quoting rules. Captures are flushed before each redirect to prevent bleed between tests.

**Nordic UART Service**

`NUSTests` — the `nus` core without CoreBluetooth: `NUSInputBuffer` (pieces of at most the write length that never span two reads, bytes kept until consumed, a cancellable wait), escape decoding, `NUSExpect` (matches split across chunks, no false matches from discarded bytes), `NUSSession` against in-memory streams (ordering, unchanged delivery, expect matched and missed, device disconnect, write failure, a write that never completes times out, input a lost link left unsent is written by the next session), the ports (fixed input ends once and stays ended; the reader stops while the input buffer is full; bytes a pty nobody reads or a TCP listener with no client does not take are counted, each run of losses reported once; a pty and a TCP listener on an ephemeral port are exercised over loopback, including a second TCP client after the first leaves), `parseNUSOptions` defaults and rejected combinations (an option value is never read as an option; `-d` must be finite and at most a year), the default NUS service filter, the pure reconnect decisions of `NUSOptions.step` (Ctrl-C during a reconnect scan ends; a failure while still connected ends; a write error that shows the link is gone reconnects; the settle wait sees a late disconnect; unsent input is reported), ArgumentParser parsing, and the `ble_nus` MCP options builder (a free-text field never becomes an option) and transcript. `SubDeadlineTests` checks that `sub -d` ends a subscription that receives nothing.

**Event processor**

`BLEEventQueueTests` — a queue full of scan results drops and counts the next one, but a didConnect and a write answer queued behind them still arrive, in order.

`BLEEventProcessorTests` — hands `BLEEventProcessor` events directly, without CoreBluetooth: a disconnect ends notification streams and runs link-ended callbacks that re-enter the processor without deadlock, and `handleEvent` returns its effects for the caller to run after unlocking. Events are matched to their peripheral: another peripheral's connect, connect failure, disconnect or GATT result does not complete or fail the current connect or its operations, and a cancelled connect's late events do not reach the next one. The connected peripheral follows the link (a cancel after the connect completed leaves it connected), a disconnect wait resumes at once for a peripheral that is not connected, and starting a connect ends a connection still held. Connects are told apart by attempt: a stale didConnect, didFailToConnect or marker of a cancelled attempt does not complete a retry to the same device before the retry's own `connectIssued` marker, a late didDisconnect of a failed setup does not fail a retry, `issueConnect` queues the marker before the call and makes no call for an attempt that stopped waiting, concurrent connects each settle (a replaced one fails and its connection is cancelled) and a replaced attempt's late cancel leaves the newest one waiting, an earlier attempt to the same device ends a later one neither by its cancel nor by its deadline, the cancel of an ended link is queued before the next attempt's connect call, a connect past its deadline fails with `timeout` and is cancelled while one that completed first is left alone, and several disconnect waits each resume while a cancel ends only its own. While Bluetooth is not poweredOn (also before its first state), a connect, a read, a write without response and a subscribe each fail at once with `bluetoothUnavailable`, no setNotifyValue call is made, and a disconnect returns at once. Notification subscribers share one characteristic: notifications are turned on once, every subscriber gets every value, they stay on until the last subscriber leaves and are then turned off; a notification right after the confirmation reaches the stream; a disconnect while notifications are being turned on fails the subscribe and ends its stream; a subscribe given up while they are being turned on turns them off only after the confirmation, and that acknowledgement does not confirm the next subscribe; a second subscribe that gives up leaves the first on; a failed turning-off confirms a subscribe waiting meanwhile and is not retried; a refused confirmation fails every subscribe waiting for it; and a subscribe cancelled first, or to a peripheral that is not connected, makes no call. GATT requests are answered in the order they were issued: two reads of one characteristic each get their own value, a cancelled read's or write's late answer is consumed as the abandoned request's and does not complete the next one, a request cancelled before it registered ends at once and is never issued, and one whose peripheral is no longer connected fails with `notConnected` without its CoreBluetooth call. A notification that arrives while a read is in flight still reaches the stream, and a read's error answer reaches the read, not the stream. One ready event wakes every waiting write without response, oldest first, each is sent once, and a cancelled one is not sent; an ended scan's deadline does not end a later scan, a scan's deadline ends it and stops CoreBluetooth's scan, a scan started while another runs ends the earlier stream with an error, Bluetooth turning off ends a scan with exit code 3 and a scan while it is off is refused; a slow scan reader gets each device once, its advertisements merged with the latest RSSI, results waiting for a busy reader keep their devices' first-sighting order and are read before the error that ended the scan, and a cancelled reader stops at once and ends the scan while results wait; a subscriber that stops reading keeps only the newest `NotificationStream.capacity` values and counts the drops while another subscriber gets every value.

`CharacteristicAccessTests` — requests the characteristic's properties do not allow are refused before they are issued, with exit code 5: a read without `read`, `-r` without `write`, `-w` without `writeNoResp`, any write to a characteristic with neither, a value longer than the maximum for its write type, and a subscribe without `notify` or `indicate`; the default write type is without response when allowed.

`BackgroundSubscriptionsTests` — the `sub -b` table: a replaced subscription that ends later does not remove its replacement, so `sub status` lists it and `sub stop` cancels it; one that ends by itself leaves the table; `sub stop` with no characteristic cancels every subscription.


**CLI argument parsing**

`CLIParsingTests` — calls `Blew.parseAsRoot()` for every subcommand and flag combination to verify that ArgumentParser accepts valid inputs and rejects invalid ones. Nothing is executed; only parsing is validated.

**End-to-end integration**

`CLIIntegrationTests` — launches the compiled `.build/debug/blew` binary as a subprocess using `Process` and checks exit codes and stdout/stderr content. Tests are skipped automatically if the binary has not been built. Covers: `--help`, `--version`, `gatt info` (known and unknown UUIDs), `exec --dry-run`, and invalid subcommands.

`SignalIntegrationTests` — launches the binary and signals it mid-command, without a radio (`exec "gatt info 2A19; sleep 0"`): with stdout piped, output printed before the signal reaches the reader, SIGINT exits 130 and SIGTERM 143, and Ctrl-C stops an `exec -k` script. With a script piped to the REPL whose writer stays open, SIGINT while the REPL waits for the next line exits 130. The REPL runs on a pseudo-terminal: SIGTERM and SIGINT at the prompt exit 143 and 130 and leave the terminal in cooked mode, SIGTERM exits 143 even when the terminal's reader has stopped reading its output, and SIGINT during `sleep 0` returns to the prompt. The commands use no device, but `cleanupBeforeExit` creates the CoreBluetooth managers. `SignalPolicyTests` covers the pure `SignalPolicy.respond(to:in:)` for each signal and phase.

**MCP server**

`MCPArgBuilderTests` — unit tests for all nine argument builder methods on `BlewMCPServer` (`buildTargetingArgs`, `buildScanArgs`, `buildConnectArgs`, `buildReadArgs`, `buildWriteArgs`, `buildSubArgs`, `buildPeriphAdvArgs`, `buildPeriphCloneArgs`, `buildPeriphSetArgs`). Exercises each option combination and verifies the resulting `[String]` arrays.

`MCPStructuredResultTests` — `Codable` round-trip tests for every `StructuredResult` case. Each case is encoded to JSON, verified to have the correct `type` discriminator, decoded back, and checked for field equality.

`MCPCollectingRendererTests` — unit tests for `CollectingRenderer`: verifies that `render`, `renderError`, `renderInfo`, `renderDebug`, `renderLive` (no-op), `reset`, and `renderResult` behave correctly.

`MCPEncodeStructuredContentTests` — tests for `BlewMCPServer.encodeStructuredContent(_:)`: empty arrays, `empty`-only arrays, individual output cases, notification aggregation (multiple `.notification` items collapsed into `.notifications([...])`), and peripheral-event aggregation.

`MCPToolDispatchTests` — exercises `handleToolCall` for commands that do not require a BLE connection: `ble_gatt_info` (known UUID, unknown UUID, missing param, a field's `condition` and `conditionDescription` in `structuredContent`), `ble_status`, `ble_periph_status`, `ble_periph_stop`, and unknown tool name (expects `MCPError.methodNotFound`). Also tests `executeTool`, `buildMCPResult`, and `buildTextContent` directly.

`MCPToolDefinitionTests` — verifies the static `toolDefinitions` array: correct count (19 tools), all expected tool names present, `readOnlyHint` and `idempotentHint` annotations, and required-field schemas for `ble_gatt_info`, `ble_write`, and `ble_gatt_chars`.

`MCPArgumentValidationTests` — arguments are checked against the tool's input schema before anything runs: a string `duration` or `count`, a `duration` above 300 s, a `count` of 0, an undeclared argument, a non-string `services` item and a `pick` outside its enum are errors; `ble_subscribe` without `duration` collects for the documented 10 s; the global options reach the router and widen the call budget; a collector drops what arrives after its call returned.

`ToolCallQueueTests` — the tool-call queue without a device: concurrent calls run one at a time, the first arrival first; cancelling a running call stops it within a second; a call cancelled while waiting its turn never starts; a call past its budget is stopped; a client cancellation after the budget ran out still ends the call cancelled; and a `StopRequest` ends the router's `waitInterruptible` as interrupted, keeps an operation requested after it from starting, and counts when it arrives during an operation that then finishes at once.

`MCPIntegrationTests` — launches `blew mcp` as a subprocess and communicates via JSON-RPC over stdio. Tests the full MCP protocol handshake (`initialize`), tool listing (`tools/list`, 19 tools), and a `tools/call` for `ble_gatt_info` verifying structured content and text output. Tests are skipped if the binary is not built.

## Manual checks (radio)

Behaviour that needs a real device, exercised before a release:

- **Connect timeout stops connecting.** With device A out of range, `blew -t 3 connect <A>` times out (exit 4). Bring A into range: it does not connect (it stays advertising, and `system_profiler SPBluetoothDataType` does not list it as connected).
- **Connecting to another device.** In the REPL, `connect <A>`, then `connect <B>`: A is disconnected first and `status` shows B. `connect <B>` again disconnects and reconnects B.
- **Scan filters.** `blew -o kv scan -S <a service A advertises>` lists only devices advertising it; `blew -o kv scan -m <company id>` only devices whose manufacturer data starts with that company; `blew scan -p first` shows one device, the first discovered (not necessarily the strongest).
- **Auto-connect switches devices.** `blew -v exec "connect -n A; read -n B <char>; status"` reports replacing A (at `-v`) and `status` shows B. `blew exec -k "connect -n A; read -n NoSuchDevice <char>; status"` reports no devices found and `status` still shows A.
- **A subscribe that timed out leaves notifications off.** When `sub <char>` times out (exit 4) waiting for the device to confirm (a device that confirms slowly, with a short `-t`), a PacketLogger trace shows its Client Characteristic Configuration descriptor written back to 0, and a connection kept afterwards (the REPL, `exec -k`) receives no notifications from it.
- **`nus --reconnect` with a file.** `blew nus -n <dev> --file <a few hundred KiB> --reconnect -r`, and switch the device off and on midway: blew reports `disconnected` and `reconnecting`, then sends the rest; the device receives the whole file (one piece may arrive twice) and blew exits 0. Without `--reconnect` it exits 5 with "(at least <n> bytes of input not sent)", where n is the size of the part not yet sent. With `-l`, a client that types while the device is away and disconnects gets "client disconnected; <n> bytes it sent were not written to the device", and the next client's bytes are not preceded by them.
- **Bare `nus`.** It picks only a device advertising the Nordic UART Service; with none in range it exits 2.
- **Unbounded watch.** `blew -t inf -o kv scan -w` exits 6 at once.
- **Power-off during a scan.** Turn Bluetooth off while `blew -t 30 scan`, `blew scan -w` and `blew -t 30 -n <name> connect` (a name nothing advertises) run: each exits 3 with "Bluetooth unavailable: Bluetooth is powered off" within a second.
- **Slow `sub` reader.** On a device notifying at least 100 times a second, run `blew -o kv sub -d 30 <char> | (sleep 20; cat)`: blew's memory stays flat, and the output has `sub=dropped` records whose `total` grows to the notifications lost.
- **Bluetooth power-off ends every waiting command.** Turn Bluetooth off (Control Center) while each of these runs; each ends within a second. `blew sub <char>` on a notifying device exits 3 with "Bluetooth unavailable: Bluetooth is powered off". `blew nus` (no `--reconnect`) exits 3. `blew scan -w` stops. In the REPL, `status` then shows not connected, and a `sub -b` reports a `sub error`. Repeat by revoking blew's (the terminal's) Bluetooth permission in System Settings > Privacy & Security > Bluetooth.
- **A fast retry after a failed or cancelled connect.** In the REPL, `connect <A>` with `-t 1` against a device with a large GATT database (discovery outlasts the deadline), then `connect <A>` again at once: the retry connects (exit 0) and is not failed by the first connection's `didDisconnect`. Repeat with Ctrl-C during the first connect. A PacketLogger trace shows whether CoreBluetooth delivers the retry's `didConnect` before the first connection's `didDisconnect`; if it does, the retry fails with exit code 5 and DESIGN.md section 3.4 must be revised. The same trace shows which callback, if any, answers a pending connect that fails or is cancelled: a `didDisconnect` there contradicts the assumption in section 3.4 (the attempt then exits 4 at its deadline instead of 5).
- **A pending connect across a Bluetooth reset.** With device A out of range, start `blew -t 30 connect <A>`, then turn Bluetooth off and on within the 30 s: blew exits 3 at once. Bring A into range: it does not connect (it stays advertising).
- **A failed service discovery leaves nothing connected.** Against a device that drops the link during discovery, or with `blew -t 1 connect <A>` on a device with a large GATT database so discovery is cancelled: the command fails, `status` in the REPL shows not connected, the device is disconnected (`system_profiler SPBluetoothDataType`), and a following `read <char>` connects afresh instead of failing with "Characteristic not found".
- **Ctrl-C in one-shot commands.** `blew scan -w` prints its final table on Ctrl-C and exits 130. `blew periph adv -S 180D` prints "Advertising ..." before any event; Ctrl-C prints "Stopped advertising." and exits 130, and a scanner no longer sees it. `blew -o kv sub -n <A> <char> >> log` appends each notification at once (`tail -f log`); Ctrl-C exits 130 and A is disconnected. `kill <pid>` of a connected `sub` exits 143 and disconnects A.
- **Long writes to the GATT server.** `blew periph adv --config device.json` with a writable characteristic; from a phone (nRF Connect), write a value longer than the MTU (for example 100 bytes): the `writeRequest` event shows all 100 bytes, and reading it back from the phone returns them in full (several Read Blob requests). A write of more than 512 bytes fails on the phone with Invalid Attribute Value Length, and the value stays as it was.
- **Notify back-pressure.** With a phone subscribed to a notifying characteristic, `blew exec -k "periph adv --config device.json; sleep 15; periph notify <char> 01; periph notify <char> 02; ..."` with a hundred `periph notify` commands (subscribe from the phone during the `sleep`): some notifications report "queued notification ... waiting for the Bluetooth transmit queue", the phone receives every value in order, and past 64 waiting a `periph notify` fails with exit 5 instead of being dropped.
- **Cancelled GATT requests do not answer later ones.** In the REPL against a device with a slow read or write (a characteristic whose server delays its response, such as an nRF Connect server with a delayed response), Ctrl-C a `read <char>`, then `read <char>` again at once: the second prints the device's current value, not an error or a value left over from the first. The same with `write -r <char> 01` interrupted, then `write -r <char> 02`: the second succeeds or fails on its own result (a PacketLogger trace shows two Write Requests, each with its response). `read` of a characteristic without the read property, `write -r` to one without the write property and `sub` of one that neither notifies nor indicates each fail at once with exit 5 naming its properties, and a PacketLogger trace shows no request for them.
- **Several subscriptions to one characteristic.** In the REPL, `sub -b <char>`, then `sub -c 3 <char>`: the foreground `sub` prints three values and returns, and the background one keeps printing. `sub -b <char>` again: `sub status` lists `<char>` once and it keeps printing (replacing it turns notifications off and on again). With a short `-t` against a device that confirms slowly, a foreground `sub <char>` that times out leaves the background one printing. `sub stop <char>`: `sub status` lists nothing, and a PacketLogger trace shows the Client Characteristic Configuration descriptor written to 0 only after the last subscription ended (and around the replacement).
- **Reading a subscribed characteristic.** In the REPL, `sub -b <char>` on a characteristic that both notifies and is readable, then `read <char>` a few times: each read prints a value, and the subscription keeps printing every notification (it also prints the value that answers each read). `sub stop <char>`, then `read <char>`: each read prints the read result only.
- **Repeated subscribe confirmations.** `sub -b <char>`, `sub stop <char>`, `sub -b <char>` in quick succession, and again with the first `sub` interrupted by Ctrl-C before the device confirms (a short `-t`): the last subscription receives notifications, and a PacketLogger trace shows one confirmation (`didUpdateNotificationStateFor`) per Client Characteristic Configuration write.
- **`periph clone` stops on Ctrl-C.** Against a device with many readable characteristics, Ctrl-C `blew periph clone -n <A> -o clone.json` during the snapshot: it exits 130 within a second, writes no file, and a PacketLogger trace shows no Read Requests after the interrupt. A device that refuses some reads (Read Not Permitted) still clones, with no initial value for those.
- **Power-off during advertising.** Turn Bluetooth off while `blew periph adv -S 180D` runs: it exits 3 with "Bluetooth unavailable: Bluetooth is powered off" within a second. In the REPL, after `periph adv --config device.json`, turn Bluetooth off: `periph status` shows not advertising, no services and no subscribers, and `periph notify <char> 01` exits 3. Turn it on again and run `periph adv` to advertise again. With `blew -t 1 periph adv --config device.json` timing out, or Ctrl-C during startup, a scanner does not see the Mac advertising afterwards.
- **Bluetooth usage description.** `otool -P` on the copied release binary prints `NSBluetoothAlwaysUsageDescription`. After `tccutil reset BluetoothAlways`, a scan run from Terminal and from a non-terminal parent (an MCP client) asks for permission and does not abort.
