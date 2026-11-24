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

`DataFormatterTests`, `BLENamesTests`, `GATTDecoderTests` — stateless functions with no I/O. Format and parse all data representations, UUID lookups, and GATT characteristic decoding. Fast and fully deterministic.

**REPL command parsing**

`TokenizerTests`, `ArgParsingHelperTests` — unit tests for the internal tokenizer and option-parsing helpers in `CommandRouter`. These call `internal` methods directly.

**Line editor**

`LineNoiseTests` — drive the vendored line editor through pipes: raw-mode key handling (UTF-8 input assembly, invalid sequences, Ctrl-T, backspace and delete around multibyte characters), the bytes written to the terminal, and non-TTY input (one line per command, end of input, invalid UTF-8, read errors). A pseudo-terminal checks the newline written after a raw-mode line.

`REPLScriptTests` — the REPL with a pipe as standard input: a script runs to end of input without touching the history, and the first failing command, an invalid UTF-8 line and an unreadable input end it with codes 6, 6 and 5.

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

**Data model**

`ExitCodeAndTargetingTests` — verifies exit code values and `CustomNSError` conformance, and exercises `DeviceTargetingOptions.toArgs()` serialization for all option combinations.

**Output formatting**

`OutputFormatterTests` — captures stdout via `dup`/`pipe` and verifies KV and text record formatting, table alignment, and quoting rules. Captures are flushed before each redirect to prevent bleed between tests.

**Nordic UART Service**

`NUSTests` — the `nus` core without CoreBluetooth: chunking, escape decoding, `NUSExpect` (matches split across chunks, no false matches from discarded bytes), `NUSSession` against in-memory streams (ordering, unchanged delivery, expect matched and missed, device disconnect, write failure), the ports (fixed input ends once and stays ended; a pty and a TCP listener on an ephemeral port are exercised over loopback, including a second TCP client after the first leaves), `parseNUSOptions` defaults and rejected combinations (an option value is never read as an option; `-d` must be finite and at most a year), the default NUS service filter, the pure reconnect decisions of `NUSOptions.step` (Ctrl-C during a reconnect scan ends; a failure while still connected ends), ArgumentParser parsing, and the `ble_nus` MCP options builder (a free-text field never becomes an option) and transcript. `SubDeadlineTests` checks that `sub -d` ends a subscription that receives nothing.

**Event processor**

`BLEEventProcessorTests` — hands `BLEEventProcessor` events directly, without CoreBluetooth: a disconnect ends notification streams and runs disconnect callbacks that re-enter the processor without deadlock, and `handleEvent` returns its effects for the caller to run after unlocking. Events are matched to their peripheral: another peripheral's connect, connect failure, disconnect or GATT result does not complete or fail the current connect or its operations, and a cancelled connect's late events do not reach the next one. The connected peripheral follows the link (a cancel after the connect completed leaves it connected), a disconnect wait resumes at once for a peripheral that is not connected, and starting a connect ends a connection still held.


**CLI argument parsing**

`CLIParsingTests` — calls `Blew.parseAsRoot()` for every subcommand and flag combination to verify that ArgumentParser accepts valid inputs and rejects invalid ones. Nothing is executed; only parsing is validated.

**End-to-end integration**

`CLIIntegrationTests` — launches the compiled `.build/debug/blew` binary as a subprocess using `Process` and checks exit codes and stdout/stderr content. Tests are skipped automatically if the binary has not been built. Covers: `--help`, `--version`, `gatt info` (known and unknown UUIDs), `exec --dry-run`, and invalid subcommands.

`SignalIntegrationTests` — launches the binary and signals it mid-command, without a radio (`exec "gatt info 2A19; sleep 0"`): with stdout piped, output printed before the signal reaches the reader, SIGINT exits 130 and SIGTERM 143, and Ctrl-C stops an `exec -k` script. The REPL runs on a pseudo-terminal: SIGTERM and SIGINT at the prompt exit 143 and 130 and leave the terminal in cooked mode, and SIGINT during `sleep 0` returns to the prompt. The commands use no device, but `cleanupBeforeExit` creates the CoreBluetooth managers. `SignalPolicyTests` covers the pure `SignalPolicy.respond(to:in:)` for each signal and phase.

**MCP server**

`MCPArgBuilderTests` — unit tests for all nine argument builder methods on `BlewMCPServer` (`buildTargetingArgs`, `buildScanArgs`, `buildConnectArgs`, `buildReadArgs`, `buildWriteArgs`, `buildSubArgs`, `buildPeriphAdvArgs`, `buildPeriphCloneArgs`, `buildPeriphSetArgs`). Exercises each option combination and verifies the resulting `[String]` arrays.

`MCPStructuredResultTests` — `Codable` round-trip tests for every `StructuredResult` case. Each case is encoded to JSON, verified to have the correct `type` discriminator, decoded back, and checked for field equality.

`MCPCollectingRendererTests` — unit tests for `CollectingRenderer`: verifies that `render`, `renderError`, `renderInfo`, `renderDebug`, `renderLive` (no-op), `reset`, and `renderResult` behave correctly.

`MCPEncodeStructuredContentTests` — tests for `BlewMCPServer.encodeStructuredContent(_:)`: empty arrays, `empty`-only arrays, individual output cases, notification aggregation (multiple `.notification` items collapsed into `.notifications([...])`), and peripheral-event aggregation.

`MCPToolDispatchTests` — exercises `handleToolCall` for commands that do not require a BLE connection: `ble_gatt_info` (known UUID, unknown UUID, missing param), `ble_status`, `ble_periph_status`, `ble_periph_stop`, and unknown tool name (expects `MCPError.methodNotFound`). Also tests `executeTool`, `buildMCPResult`, and `buildTextContent` directly.

`MCPToolDefinitionTests` — verifies the static `toolDefinitions` array: correct count (19 tools), all expected tool names present, `readOnlyHint` and `idempotentHint` annotations, and required-field schemas for `ble_gatt_info`, `ble_write`, and `ble_gatt_chars`.

`MCPArgumentValidationTests` — arguments are checked against the tool's input schema before anything runs: a string `duration` or `count`, a `duration` above 300 s, a `count` of 0, an undeclared argument, a non-string `services` item and a `pick` outside its enum are errors; `ble_subscribe` without `duration` collects for the documented 10 s; the global options reach the router and widen the call budget; a collector drops what arrives after its call returned.

`ToolCallQueueTests` — the tool-call queue without a device: concurrent calls run one at a time, the first arrival first; cancelling a running call stops it within a second; a call cancelled while waiting its turn never starts; a call past its budget is stopped; and a `StopRequest` ends the router's `waitInterruptible` as interrupted.

`MCPIntegrationTests` — launches `blew mcp` as a subprocess and communicates via JSON-RPC over stdio. Tests the full MCP protocol handshake (`initialize`), tool listing (`tools/list`, 19 tools), and a `tools/call` for `ble_gatt_info` verifying structured content and text output. Tests are skipped if the binary is not built.

## Manual checks (radio)

Behaviour that needs a real device, exercised before a release:

- **Connect timeout stops connecting.** With device A out of range, `blew -t 3 connect <A>` times out (exit 4). Bring A into range: it does not connect (it stays advertising, and `system_profiler SPBluetoothDataType` does not list it as connected).
- **Connecting to another device.** In the REPL, `connect <A>`, then `connect <B>`: A is disconnected first and `status` shows B. `connect <B>` again disconnects and reconnects B.
- **Scan filters.** `blew -o kv scan -S <a service A advertises>` lists only devices advertising it; `blew -o kv scan -m <company id>` only devices whose manufacturer data starts with that company; `blew scan -p first` shows one device, the first discovered (not necessarily the strongest).
- **Auto-connect switches devices.** `blew -v exec "connect -n A; read -n B <char>; status"` reports replacing A (at `-v`) and `status` shows B. `blew exec -k "connect -n A; read -n NoSuchDevice <char>; status"` reports no devices found and `status` still shows A.
- **Bare `nus`.** It picks only a device advertising the Nordic UART Service; with none in range it exits 2.
- **Unbounded watch.** `blew -t inf -o kv scan -w` exits 6 at once.
- **Bluetooth power-off ends every waiting command.** Turn Bluetooth off (Control Center) while each of these runs; each ends within a second. `blew sub <char>` on a notifying device exits 3 with "Bluetooth unavailable: Bluetooth is powered off". `blew nus` (no `--reconnect`) exits 3. `blew scan -w` stops. In the REPL, `status` then shows not connected, and a `sub -b` reports a `sub error`. Repeat by revoking blew's (the terminal's) Bluetooth permission in System Settings > Privacy & Security > Bluetooth.
- **A failed service discovery leaves nothing connected.** Against a device that drops the link during discovery, or with `blew -t 1 connect <A>` on a device with a large GATT database so discovery is cancelled: the command fails, `status` in the REPL shows not connected, the device is disconnected (`system_profiler SPBluetoothDataType`), and a following `read <char>` connects afresh instead of failing with "Characteristic not found".
- **Ctrl-C in one-shot commands.** `blew scan -w` prints its final table on Ctrl-C and exits 130. `blew periph adv -S 180D` prints "Advertising ..." before any event; Ctrl-C prints "Stopped advertising." and exits 130, and a scanner no longer sees it. `blew -o kv sub -n <A> <char> >> log` appends each notification at once (`tail -f log`); Ctrl-C exits 130 and A is disconnected. `kill <pid>` of a connected `sub` exits 143 and disconnects A.
