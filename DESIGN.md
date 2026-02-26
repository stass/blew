# blew — Software Architecture

## 1. Overview

blew is organized as a Swift Package with three targets:

| Target | Kind | Role |
|--------|------|------|
| `blew` | Executable | CLI argument parsing, commands, REPL, output formatting |
| `BLEManager` | Library | CoreBluetooth wrapper exposing an async/await API |
| `LineNoise` | Library | Vendored linenoise port — raw-mode terminal line editing |

The two library targets are intentionally decoupled. `BLEManager` has no knowledge of the CLI layer; `LineNoise` has no knowledge of BLE. The executable target wires them together.

---

## 2. High-level data flow

```
┌─────────────────────────────────────────────────────────────────────┐
│ blew (executable)                                                   │
│                                                                     │
│  ArgumentParser ──► Blew (@main)                                    │
│        │                 │                                          │
│        │           ┌─────┴─────┐                                    │
│        │           │           │                                    │
│        │         REPL     CommandRouter  ◄── --exec script          │
│        │           │           │                                    │
│        └───────────┴───────────┘                                    │
│                        │                                            │
│                   OutputFormatter                                   │
│                  (stdout / stderr)                                  │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ async/await calls
┌───────────────────────────────▼─────────────────────────────────────┐
│ BLEManager                                                          │
│                                                                     │
│  BLECentral (singleton facade)                                      │
│       │                                                             │
│       │  CheckedContinuation / AsyncStream bridges                  │
│       │                                                             │
│  BLEEventProcessor  ◄──  BLEEventQueue (SPSC ring)  ◄──  BLEDelegate│
│  (dedicated thread)       (lock-free, 1024 slots)     (CB queue)   │
│       │                                                   │         │
│       └────── resumes continuations / yields to streams   │         │
│                                                           │         │
│                                              CoreBluetooth (OS)     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. BLEManager target

### 3.1 Event pipeline

CoreBluetooth is callback-based and runs all its callbacks on a dedicated serial queue. blew's internal architecture converts this into a typed event pipeline:

```
CBCentralManager/CBPeripheral callbacks
        │  (on blew.cb DispatchQueue)
        ▼
   BLEDelegate
  - extracts value types from CB objects
  - enqueues BLEEvent to BLEEventQueue
  - returns immediately (never blocks)
        │
        ▼
   BLEEventQueue  (lock-free SPSC ring buffer, 1024 slots)
        │
        ▼  (on blew.event-processor Thread)
   BLEEventProcessor
  - drains queue in a tight loop
  - routes each event to the correct
    CheckedContinuation or AsyncStream
```

This design keeps the CoreBluetooth queue unblocked at all times and avoids any callback-to-async bridging on the CB thread itself.

### 3.2 BLEEvent

`BLEEvent` is a `Sendable` enum whose associated values are all plain Swift value types (`String`, `Int`, `Data`, `UUID`, etc.). CB objects (`CBPeripheral`, `CBService`, etc.) are never stored in events — data is extracted before enqueueing so events cross thread boundaries safely.

Cases:

```
centralStateChanged(CBManagerState)
didDiscover(peripheralId, name, rssi, serviceUUIDs, manufacturerData)
didConnect(peripheralId)
didFailToConnect(peripheralId, error)
didDisconnect(peripheralId, error)
didDiscoverServices(peripheralId, serviceUUIDs, error)
didDiscoverCharacteristics(peripheralId, serviceUUID, characteristics, error)
didDiscoverDescriptors(peripheralId, characteristicUUID, descriptorUUIDs, error)
didUpdateValue(peripheralId, characteristicUUID, value, error)
didWriteValue(peripheralId, characteristicUUID, error)
didUpdateNotificationState(peripheralId, characteristicUUID, isNotifying, error)
```

### 3.3 BLEEventQueue

A lock-free SPSC (single-producer / single-consumer) ring buffer backed by `swift-atomics`.

- Capacity: 1024 (must be a power of 2; uses bitmask for modulo arithmetic)
- Producer: `BLEDelegate` on the CB queue
- Consumer: `BLEEventProcessor` on its dedicated thread
- Full queue: newest event is silently dropped; `droppedCount` is incremented
- Empty queue: consumer blocks on a `DispatchSemaphore` (signalled by producer on each enqueue)

### 3.4 BLEEventProcessor

Runs a permanent `while running` loop on a dedicated `Thread` named `blew.event-processor`. On each dequeued event it calls `handleEvent(_:)` under `NSLock`.

`handleEvent` maintains two kinds of registered handlers:

**One-shot `CheckedContinuation`s** (for operations that complete exactly once):

| Operation | Continuation type |
|-----------|------------------|
| connect | `CheckedContinuation<Void, Error>` |
| disconnect | `CheckedContinuation<Void, Error>` |
| discoverServices | `CheckedContinuation<[String], Error>` |
| discoverCharacteristics | `[serviceUUID: CheckedContinuation<[DiscoveredCharacteristic], Error>]` |
| discoverDescriptors | `[charUUID: CheckedContinuation<[String], Error>]` |
| read | `[charUUID: CheckedContinuation<Data, Error>]` |
| write (with response) | `[charUUID: CheckedContinuation<Void, Error>]` |
| subscribe (enable notify) | `[charUUID: CheckedContinuation<Void, Error>]` |

**Ongoing `AsyncStream` continuations** (for streaming operations):

| Operation | Continuation type |
|-----------|------------------|
| scan | `AsyncStream<DiscoveredDevice>.Continuation` |
| notifications per characteristic | `[charUUID: AsyncStream<Data>.Continuation]` |

`didUpdateValue` is the one event that serves two purposes: if a one-shot read continuation is registered for that UUID it is fulfilled and removed; otherwise the value is yielded to the notification stream.

On `didDisconnect`, all active notification streams are finished and any pending continuations are failed.

### 3.5 BLECentral

The public facade and the only exported type. It is a singleton (`BLECentral.shared`).

Responsibilities:

- Owns `CBCentralManager`, `BLEDelegate`, `BLEEventQueue`, `BLEEventProcessor`
- Serializes all CoreBluetooth calls onto `blew.cb` (a dedicated serial `DispatchQueue`)
- Maintains connection state under `NSLock`: connected peripheral ID/name, all discovered `CBService` and `CBCharacteristic` objects, active subscription UUIDs
- Exposes an async/await API that bridges to the continuation/stream model

Key behaviors:

- **`scan(timeout:)`** — starts `CBCentralManager.scanForPeripherals`, returns `AsyncStream<DiscoveredDevice>`. A background `Task` stops scanning after `timeout` seconds and finishes the stream.
- **`connect(deviceId:timeout:)`** — looks up the peripheral in the delegate's cache or via `retrievePeripherals(withIdentifiers:)`, connects, then immediately runs full GATT discovery (all services, all characteristics for each service) so subsequent read/write/subscribe calls can proceed without additional discovery round-trips.
- **`subscribe(characteristicUUID:)`** — enables notifications via `setNotifyValue(true)`, waits for the state-change callback to confirm, then returns `AsyncStream<Data>`. On stream termination, disables notifications and removes the subscription.

### 3.6 Value types (DeviceInfo.swift)

All data passed between `BLEManager` and the CLI layer uses plain `Sendable` structs:

```
DiscoveredDevice   — identifier, name?, rssi, serviceUUIDs, manufacturerData?
ServiceInfo        — uuid, isPrimary
CharacteristicInfo — uuid, properties: [String], descriptors: [DescriptorInfo]
DescriptorInfo     — uuid
ServiceTree        — uuid, isPrimary, characteristics: [CharacteristicInfo]
ConnectionStatus   — isConnected, deviceId?, deviceName?, counts, lastError?
WriteType          — withResponse | withoutResponse | auto
```

### 3.7 BLEError

A `Sendable` enum that maps each failure kind to both a human-readable description and an exit code integer. This makes error-to-exit-code mapping explicit and centralised, rather than scattered across command implementations.

---

## 4. blew executable target

### 4.1 Entry point and modes

`Blew` is the `@main` `ParsableCommand`. Its `run()` method selects one of two modes:

```
blew [global-options] <subcommand> [command-options]  →  subcommand's own run() is called by ArgumentParser
blew [global-options] --exec                          →  CommandRouter.executeScript()
blew [global-options]                                 →  REPL.run()
```

Before any mode exits, `cleanupBeforeExit()` performs a best-effort disconnect (waits up to 2 seconds for the disconnect to complete). SIGINT and SIGTERM both call this function before exiting.

### 4.2 GlobalOptions

A `ParsableArguments` struct included via `@OptionGroup` in the root `Blew` command only. Global options are parsed exclusively at the root level — they must appear before the subcommand name on the command line. Subcommands access the parsed values via `GlobalOptions.current`, a static property set in `Blew.validate()` (which ArgumentParser calls before dispatching to the subcommand).

```
--verbose (-v)       flag count (0 / 1 / 2)
--timeout (-t)       Double? — BLE operation timeout
--out (-o)           OutputFormat: text | kv
--id (-i)            explicit device UUID
--name (-n)          device name filter
--service (-S)       [String] — service UUID filter, repeatable
--manufacturer (-m)  Int? — manufacturer ID filter
--rssi-min (-r)      Int? — minimum RSSI
--pick (-p)          PickStrategy: strongest | first | only
--exec (-x)          String? — semicolon-separated script
--keep-going (-k)    Bool — continue past errors in --exec
--dry-run            Bool — print parsed steps, don't run
```

This design keeps global options out of each subcommand's `--help` output and prevents them from being supplied after the subcommand name.

### 4.3 Subcommands

Each subcommand is a thin `ParsableCommand` that:
1. Validates/collects its own flags (e.g. `-c`, `-F`, `-d`)
2. Creates a `CommandRouter` with `GlobalOptions.current` (set by `Blew.validate()`)
3. Translates its parsed arguments into a string token array
4. Calls the matching `CommandRouter.run*()` method
5. Throws `BlewExitCode` if the result is non-zero

The subcommand list:

```
scan
connect [<device-id>]
gatt
  svcs
  tree   [-d/--descriptors]  [-V]
  chars  -S <service-uuid>   [-V]
  desc   -c <char-uuid>
read     -c <char-uuid>  [-F <fmt>]
write    -c <char-uuid>  -d <data>  [-F <fmt>]  [-R|-W]
sub      -c <char-uuid>  [-F <fmt>] [-D <sec>]  [-C <count>]
```

`disconnect` and `status` are available in REPL and `--exec` mode but are not exposed as CLI subcommands — they carry no value when the process starts fresh with no persistent state.

### 4.4 Implicit auto-connect

`gatt`, `read`, `write`, and `sub` call `CommandRouter.ensureConnected()` before executing. This means operations can be used directly from the CLI without a separate `connect` step:

```
blew --id <uuid> gatt tree
blew --name "My Device" read -c 2A19
```

`ensureConnected()` is a no-op when a connection is already established (REPL / `--exec` after an explicit `connect`). When not connected it resolves the target device using `GlobalOptions`:

1. `--id` present → connect directly
2. Any scan filter present (`--name`, `--service`, `--manufacturer`, `--rssi-min`) → run a scan, apply `--pick` strategy to select one device, then connect
3. Neither → error: user must specify a device

The `pickDevice(from:)` helper applies `globals.pick`:
- `strongest` / `first` → first element of the RSSI-sorted scan results
- `only` → the single result, or an error listing all candidates if more than one was found

### 4.5 CommandRouter

The central command dispatcher. It is the shared implementation used by all three entry paths (ArgumentParser subcommands, `--exec`, and REPL).

**`dispatch(_:)`** — tokenizes a single command-line string (with basic single/double-quote handling) and routes to the appropriate `run*()` method.

**`executeScript(_:)`** — splits the `--exec` string on `;`, strips whitespace and empty segments, calls `dispatch` on each. With `--dry-run`, prints numbered steps instead. With `--keep-going`, records first error but continues.

**`run*()` methods** — each is a synchronous function that:
1. Parses its args from the token array via private `parseStringOption`/`parseIntOption`/`parseDoubleOption` helpers
2. Creates a `DispatchSemaphore`
3. Launches a `Task` calling the appropriate `BLECentral.shared` async method
4. Signals the semaphore on completion (success or error)
5. Waits on the semaphore
6. Returns an exit code

This semaphore pattern bridges Swift's structured concurrency into the synchronous world of the CLI main thread and REPL loop.

**Device/UUID resolution** — `CommandRouter` can resolve partial or friendly identifiers to full UUIDs:

- `resolveDevice(_:)`: tries (in order) exact UUID match → name substring match → UUID substring match (hyphens stripped). Returns `.resolved`, `.ambiguous`, or `.notFound`.
- `resolveCharacteristic(_:)` / `resolveService(_:)`: prefix-matches against the `BLECentral`-cached UUID lists. After `connect`, all characteristic UUIDs are known, enabling short-prefix convenience like `2A` to match `2A19`.

**Scan results cache** — `lastScanResults: [DiscoveredDevice]` is updated after every successful scan. Used for device resolution in `connect` and for REPL tab completion.

**Text output** — uses the `ScanSpinner` (a `DispatchSourceTimer`-based braille spinner on stderr) when stdout is a TTY and a scan is running.

### 4.6 OutputFormatter

Wraps `OutputFormat` (text|kv) and `verbosity` (0/1/2). All output goes through this type; no command calls `Swift.print` directly.

| Method | Destination | Visibility |
|--------|-------------|------------|
| `printError(_:)` | stderr, prefixed `Error:` | always |
| `printInfo(_:)` | stderr, plain | verbosity ≥ 1 |
| `printDebug(_:)` | stderr, prefixed `[debug]` | verbosity ≥ 2 |
| `print(_:)` | stdout | always |
| `printRecord(_:)` | stdout | always |
| `printTable(headers:rows:)` | stdout | always |

`printRecord` and `printTable` adapt their output to the selected format:
- **text**: `key: value` pairs (record) or auto-padded aligned columns (table)
- **kv**: space-separated `key=value` on one line; values with spaces or quotes are double-quoted

### 4.7 DataFormatter

A static enum with `format(_:as:)` and `parse(_:as:)` methods covering: `hex`, `utf8`, `base64`, `uint8`, `uint16le`, `uint32le`, `float32le`, `raw`. Shared by `read`, `write`, and `sub`.

The `hex` and `raw` formats both produce hex output but differ: `hex` is a compact lowercase string (`deadbeef`); `raw` is space-separated bytes (`de ad be ef`). Both `raw` and `hex` inputs strip spaces before parsing.

### 4.8 REPL

`REPL` wraps `LineNoise` (from the `LineNoise` target) and `CommandRouter`.

- History file: `~/.config/blew/history`, loaded on init, saved on clean exit
- Prompt: `blew> `
- `Ctrl-C` during REPL: prints `^C` and continues (does not exit)
- `EOF` or `quit`/`exit`: saves history and returns

Tab completion is registered via `LineNoise.setCompletionCallback`. The callback receives the current buffer and returns an array of replacement strings. Coverage:

| Context | Completions |
|---------|-------------|
| First word | All command names |
| `connect <partial>` | Matching device IDs from last scan (by name or UUID substring) |
| `gatt <partial>` | `svcs`, `tree`, `chars`, `desc` |
| `gatt chars -S <partial>` | Known service UUIDs (prefix match) |
| `gatt desc -c <partial>` | Known characteristic UUIDs (prefix match) |
| `read/write/sub -c <partial>` | Known characteristic UUIDs (prefix match) |
| After `-F`/`--format` | All format names |

### 4.9 WellKnownCharacteristics

`WellKnownCharacteristics` is a namespace enum that maps standard Bluetooth SIG characteristic UUIDs to the `DataFormatter` format string that correctly decodes their value. It is used by `gatt tree -V` and `gatt chars -V` to produce human-readable values inline.

The internal `formats` dictionary keys are 4-char uppercase short UUIDs. Examples:

- `"2A00"` → `"utf8"` (Device Name)
- `"2A19"` → `"uint8"` (Battery Level)
- `"2A01"` → `"uint16le"` (Appearance)
- `"2A23"` → `"hex"` (System ID)

`bestFormat(for:)` returns the format for a UUID, falling back to `"hex"` for unknown UUIDs. `decode(_:uuid:)` returns a decoded string only when the UUID has a known format entry; callers use `nil` to decide whether to apply the format or fall back to hex.

Only characteristics with a single unambiguous scalar or string encoding are included. Multi-field characteristics (e.g. Heart Rate Measurement) are intentionally omitted and decoded as hex.

### 4.10 BLENames

`BLENames` is a namespace enum in the `blew` executable target responsible for mapping standard Bluetooth SIG UUIDs to human-readable names.

**Data source**

The Nordic Semiconductor [bluetooth-numbers-database](https://github.com/NordicSemiconductor/bluetooth-numbers-database) is included as a git submodule at `Vendor/bluetooth-numbers-database/`. It contains three JSON files under `v1/`:

- `service_uuids.json`
- `characteristic_uuids.json`
- `descriptor_uuids.json`

Entries with `source == "gss"` are official Bluetooth SIG assignments.

**Build-time generation**

The `GenerateBLENames` SwiftPM build tool plugin (`Plugins/GenerateBLENames/plugin.swift`) declares a `prebuildCommand` that invokes `Scripts/generate-ble-names.rb` before each build. The Ruby script reads the three JSON files from the submodule, deduplicates entries by UUID, and writes `BLENames.generated.swift` into SwiftPM's plugin work directory. SwiftPM compiles this generated file as part of the `blew` target. The generated file is not checked in.

To update the name database, run `git submodule update --remote Vendor/bluetooth-numbers-database` and rebuild.

**UUID normalization**

CoreBluetooth represents standard Bluetooth SIG UUIDs in their short form (e.g. `"180F"` rather than `"0000180F-0000-1000-8000-00805F9B34FB"`). `BLENames.shortUUID(_:)` handles all three input forms:

- 4-char short hex (`"180F"`) — returned as-is uppercased
- 8-char 32-bit hex (`"0000180F"`) — last 4 chars returned
- Full 128-bit Bluetooth Base UUID (`"0000XXXX-0000-1000-8000-00805F9B34FB"`) — `XXXX` extracted

Custom vendor UUIDs that do not follow the Bluetooth Base pattern return `nil`.

**Resolution order**

1. Look up the short UUID in the appropriate `BLENameData` dictionary (services / characteristics / descriptors)
2. If not found, return the raw UUID string as-is

**Output conventions**

- Text mode: names appended inline — `180F (Battery Service)`
- KV mode: separate `name=` field emitted when a name is known; field omitted for unknown UUIDs

### 4.11 ExitCodes

`BlewExitCode` is a thin `Error` wrapper around `Int32`. It implements `CustomNSError` so ArgumentParser can extract and propagate the exit code correctly.

```
0   success
2   not found / no match
3   Bluetooth unavailable or permission denied
4   timeout
5   operation failed (connect / GATT / read / write / subscribe)
6   invalid arguments
```

---

## 5. Threading model

```
Thread                  Runs
──────────────────────  ─────────────────────────────────────────────
Main thread             ArgumentParser, REPL getLine loop,
                        synchronous command dispatch,
                        DispatchSemaphore.wait() during BLE operations
blew.cb (serial queue)  All CBCentralManager / CBPeripheral calls
blew.event-processor    BLEEventQueue drain loop, continuation resumes
Swift cooperative pool  async Task bodies (BLECentral async methods)
```

The semaphore-based bridge is the key synchronisation point:

```swift
let semaphore = DispatchSemaphore(value: 0)
Task {
    do { try await BLECentral.shared.someOperation() }
    catch { ... }
    semaphore.signal()
}
semaphore.wait()
```

This lets the REPL and `--exec` runner remain purely synchronous while the BLE stack operates asynchronously. The cost is one thread blocked per in-flight BLE operation, which is acceptable given the interactive/scripting nature of the tool.

---

## 6. Module dependency graph

```
blew (executable)
 ├── BLEManager                        (CoreBluetooth, swift-atomics)
 ├── LineNoise                         (system libedit — linenoise Swift implementation)
 ├── ArgumentParser                    (swift-argument-parser)
 └── [build plugin] GenerateBLENames   (reads Vendor/bluetooth-numbers-database/v1/*.json
                                        via Scripts/generate-ble-names.rb,
                                        emits BLENames.generated.swift at compile time)
```

`BLEManager` and `LineNoise` have no dependency on each other. `BLEManager` has no dependency on ArgumentParser or any CLI concern. The `GenerateBLENames` plugin runs as a prebuild command and has no runtime presence.

---

## 7. Key design decisions

### Callback → event pipeline (not direct continuation bridging)

CoreBluetooth's delegate callbacks could be bridged directly to continuations inside the delegate. Instead, blew routes everything through `BLEEventQueue → BLEEventProcessor`. This separates CB callback latency from continuation-resume latency, allows future event batching or logging, and makes the data flow visible as a typed enum rather than implicit closures.

### Lock-free SPSC queue

The queue has exactly one producer (the CB delegate queue) and one consumer (the event processor thread), making an SPSC lock-free ring buffer the natural fit. The `swift-atomics` library provides the acquire/release memory ordering primitives needed.

### Semaphore-based async bridge

The REPL loop and `--exec` runner are inherently synchronous. Using `DispatchSemaphore` to wait for each `Task` is intentional — it avoids converting the entire CLI layer to `async`, which would complicate the REPL loop and signal handling. The alternative (running a detached async main with `RunLoop.main.run()`) adds complexity without benefit for a single-user interactive tool.

### Auto GATT discovery on connect

`BLECentral.connect()` always discovers all services and characteristics immediately after connection is established. This adds ~100ms at connect time but means `read`, `write`, `sub`, and `gatt` commands never need to trigger discovery themselves. It also populates the UUID caches that power tab completion.

### Shared CommandRouter across all entry paths

The same `CommandRouter.run*()` implementations are called from ArgumentParser subcommands, `--exec` parsing, and the REPL. This eliminates three independent implementations of the same BLE operation logic and guarantees identical behavior regardless of how a command is invoked.

### Value-type GATT model

`BLEManager` stores live `CBService` and `CBCharacteristic` objects internally (they are reference types that must be retained). However, the public API only exposes plain `Sendable` value-type structs (`ServiceInfo`, `CharacteristicInfo`, etc.), keeping the `CoreBluetooth` import boundary entirely within `BLEManager`.
