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

**Command routing and scripting**

`CommandDispatchTests`, `ExecuteScriptTests` — exercise `CommandRouter.dispatch()` and `executeScript()` using commands that do not require a BLE connection (`help`, `gatt info`, `periph stop/status`, `sub status`, `sleep`). Error paths and exit codes are verified directly.

**Device and service resolution**

`DeviceResolutionTests` — populates `CommandRouter.lastScanResults` with synthetic `DiscoveredDevice` fixtures and exercises the UUID/name matching logic: exact match, substring match, ambiguous match, and not-found.

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

`BLEEventProcessorTests` — hands `BLEEventProcessor` events directly, without CoreBluetooth: a disconnect ends notification streams and runs disconnect callbacks that re-enter the processor without deadlock, and `handleEvent` returns its effects for the caller to run after unlocking.

**CLI argument parsing**

`CLIParsingTests` — calls `Blew.parseAsRoot()` for every subcommand and flag combination to verify that ArgumentParser accepts valid inputs and rejects invalid ones. Nothing is executed; only parsing is validated.

**End-to-end integration**

`CLIIntegrationTests` — launches the compiled `.build/debug/blew` binary as a subprocess using `Process` and checks exit codes and stdout/stderr content. Tests are skipped automatically if the binary has not been built. Covers: `--help`, `--version`, `gatt info` (known and unknown UUIDs), `exec --dry-run`, and invalid subcommands.

**MCP server**

`MCPArgBuilderTests` — unit tests for all nine argument builder methods on `BlewMCPServer` (`buildTargetingArgs`, `buildScanArgs`, `buildConnectArgs`, `buildReadArgs`, `buildWriteArgs`, `buildSubArgs`, `buildPeriphAdvArgs`, `buildPeriphCloneArgs`, `buildPeriphSetArgs`). Exercises each option combination and verifies the resulting `[String]` arrays.

`MCPStructuredResultTests` — `Codable` round-trip tests for every `StructuredResult` case. Each case is encoded to JSON, verified to have the correct `type` discriminator, decoded back, and checked for field equality.

`MCPCollectingRendererTests` — unit tests for `CollectingRenderer`: verifies that `render`, `renderError`, `renderInfo`, `renderDebug`, `renderLive` (no-op), `reset`, and `renderResult` behave correctly.

`MCPEncodeStructuredContentTests` — tests for `BlewMCPServer.encodeStructuredContent(_:)`: empty arrays, `empty`-only arrays, individual output cases, notification aggregation (multiple `.notification` items collapsed into `.notifications([...])`), and peripheral-event aggregation.

`MCPToolDispatchTests` — exercises `handleToolCall` for commands that do not require a BLE connection: `ble_gatt_info` (known UUID, unknown UUID, missing param), `ble_status`, `ble_periph_status`, `ble_periph_stop`, and unknown tool name (expects `MCPError.methodNotFound`). Also tests `executeTool`, `buildMCPResult`, and `buildTextContent` directly.

`MCPToolDefinitionTests` — verifies the static `toolDefinitions` array: correct count (19 tools), all expected tool names present, `readOnlyHint` and `idempotentHint` annotations, and required-field schemas for `ble_gatt_info`, `ble_write`, and `ble_gatt_chars`.

`MCPIntegrationTests` — launches `blew mcp` as a subprocess and communicates via JSON-RPC over stdio. Tests the full MCP protocol handshake (`initialize`), tool listing (`tools/list`, 19 tools), and a `tools/call` for `ble_gatt_info` verifying structured content and text output. Tests are skipped if the binary is not built.
