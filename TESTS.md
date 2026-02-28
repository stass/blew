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

The test target depends directly on the `blew` executable and uses `@testable import blew` for white-box access. A handful of `CommandRouter` helpers are `internal` (rather than `private`) so they can be exercised directly from tests; everything else is accessed through public interfaces or by running the compiled binary as a subprocess.

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

**Data model**

`ExitCodeAndTargetingTests` — verifies exit code values and `CustomNSError` conformance, and exercises `DeviceTargetingOptions.toArgs()` serialization for all option combinations.

**Output formatting**

`OutputFormatterTests` — captures stdout via `dup`/`pipe` and verifies KV and text record formatting, table alignment, and quoting rules. Captures are flushed before each redirect to prevent bleed between tests.

**CLI argument parsing**

`CLIParsingTests` — calls `Blew.parseAsRoot()` for every subcommand and flag combination to verify that ArgumentParser accepts valid inputs and rejects invalid ones. Nothing is executed; only parsing is validated.

**End-to-end integration**

`CLIIntegrationTests` — launches the compiled `.build/debug/blew` binary as a subprocess using `Process` and checks exit codes and stdout/stderr content. Tests are skipped automatically if the binary has not been built. Covers: `--help`, `--version`, `gatt info` (known and unknown UUIDs), `exec --dry-run`, and invalid subcommands.
