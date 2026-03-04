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
│            OutputRenderer (TextRenderer / KVRenderer)               │
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

## 3. BLEManager target — central and peripheral

The target now contains both a central (scanning/connecting) and a peripheral (GATT server) subsystem. They share `BLEError` and value types but are otherwise independent.

### 3.1 Event pipeline (central)

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

### 3.5 BLECentral (central facade)

The public facade and the only exported type. It is a singleton (`BLECentral.shared`).

Responsibilities:

- Owns `CBCentralManager`, `BLEDelegate`, `BLEEventQueue`, `BLEEventProcessor`
- Serializes all CoreBluetooth calls onto `blew.cb` (a dedicated serial `DispatchQueue`)
- Maintains connection state under `NSLock`: connected peripheral ID/name, all discovered `CBService` and `CBCharacteristic` objects, active subscription UUIDs
- Exposes an async/await API that bridges to the continuation/stream model

Key behaviors:

- **`scan(timeout:allowDuplicates:)`** — starts `CBCentralManager.scanForPeripherals`, returns `AsyncStream<DiscoveredDevice>`. When `timeout` is non-nil, a background `Task` stops scanning after that many seconds and finishes the stream. When `timeout` is `nil` the stream runs until the caller cancels (used by `--watch` mode). `allowDuplicates` maps directly to `CBCentralManagerScanOptionAllowDuplicatesKey`; watch mode passes `true` so RSSI updates arrive continuously.
- **`connect(deviceId:timeout:)`** — looks up the peripheral in the delegate's cache or via `retrievePeripherals(withIdentifiers:)`, connects, then immediately runs full GATT discovery (all services, all characteristics for each service) so subsequent read/write/subscribe calls can proceed without additional discovery round-trips.
- **`subscribe(characteristicUUID:)`** — enables notifications via `setNotifyValue(true)`, waits for the state-change callback to confirm, then returns `AsyncStream<Data>`. On stream termination, disables notifications and removes the subscription.

### 3.6 BLEPeripheral subsystem

The peripheral subsystem exposes the Mac as a GATT server that remote centrals (phones, other computers) can connect to and interact with.

**Architecture:**

```
CLI / REPL  ──async/await──►  BLEPeripheral (singleton)
                                   │
                         ┌─────────┼─────────┐
                         │         │         │
                   CBPeripheralManager  GATTStore  BLEPeripheralDelegate
                         │                   │         │
                         └───────────────────┘◄────────┘
                            (delegate callbacks read/write
                             GATTStore synchronously; events
                             flow to AsyncStream for logging)
```

**Key difference from the central path:** Read and write requests from connected centrals must be answered synchronously inside `CBPeripheralManagerDelegate` callbacks. The delegate therefore accesses `GATTStore` directly (under `NSLock`) and calls `respond(to:withResult:)` immediately. Events are emitted to an `AsyncStream<PeripheralEvent>` after responding, purely for logging and REPL feedback. There is no event queue or processor thread on the peripheral side.

**New files:**

| File | Role |
|------|------|
| `BLEPeripheral.swift` | Public singleton facade. Owns `CBPeripheralManager`, `GATTStore`, delegate. API: `configure`, `startAdvertising`, `stopAdvertising`, `updateValue`, `events()`, `peripheralStatus()`. |
| `BLEPeripheralDelegate.swift` | `CBPeripheralManagerDelegate`. Answers read/write requests synchronously via `GATTStore`. Emits `PeripheralEvent` to stream. |
| `GATTStore.swift` | Thread-safe value map + subscriber map. Accessed from `blew.pm` queue (delegate) and any thread (CLI commands). Guarded by `NSLock`. |
| `PeripheralTypes.swift` | `ServiceDefinition`, `CharacteristicDefinition`, `CharacteristicProperty`, `PeripheralStatus` — all `Sendable` value types. |
| `PeripheralEvent.swift` | `PeripheralEvent` enum: `stateChanged`, `advertisingStarted`, `serviceAdded`, `centralConnected`, `centralDisconnected`, `readRequest`, `writeRequest`, `subscribed`, `unsubscribed`, `notificationSent`. |

**CoreBluetooth peripheral limitations:**

- Only `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey` are allowed in the advertisement dictionary. Manufacturer data, service data, and other ADV fields are rejected by CoreBluetooth.
- ADV interval, TX power, and connection parameters are OS-controlled.
- Clone mode replicates GATT structure and initial values; raw ADV bytes cannot be reproduced.
- macOS TCC may prompt for Bluetooth permission on first run.
- On macOS, a subset of standard Bluetooth SIG service UUIDs are reserved by the system and cannot be registered in short form via `CBPeripheralManager` — they return "The specified UUID is not allowed for this operation." These are the services macOS itself exposes as a peripheral: `1800` (Generic Access), `1801` (Generic Attribute), `1805` (Current Time), `180A` (Device Information), `180F` (Battery Service), `1812` (Human Interface Device), `181E` (Bond Management). The full 128-bit Bluetooth Base UUID form (e.g. `0000180F-0000-1000-8000-00805F9B34FB`) is accepted by `CBPeripheralManager` for all UUIDs, but registers as a raw 128-bit UUID — centrals do not recognise it as the standard service. For the blocked services, use the long form if GATT structure matters, or custom UUIDs if standard service recognition is needed. All other standard SIG UUIDs (e.g. `180D` Heart Rate, `1809` Health Thermometer, `181A` Environmental Sensing) work correctly in short form and are recognised by centrals as standard services.

### 3.7 Value types (DeviceInfo.swift)

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

### 3.8 BLEError

A `Sendable` enum that maps each failure kind to both a human-readable description and an exit code integer. This makes error-to-exit-code mapping explicit and centralised, rather than scattered across command implementations.

Central errors: `bluetoothUnavailable`, `notConnected`, `deviceNotFound`, `connectionFailed`, `timeout`, `serviceNotFound`, `characteristicNotFound`, `readFailed`, `writeFailed`, `subscribeFailed`, `operationFailed`.

Peripheral errors: `peripheralUnavailable`, `advertisingFailed`, `serviceRegistrationFailed`.

---

## 4. blew executable target

### 4.1 Entry point and modes

`Blew` is the `@main` `AsyncParsableCommand`. Its `run()` method selects one of three modes:

```
blew [global-options] <subcommand> [command-options]  →  subcommand's own run() is called by ArgumentParser
blew [global-options]                                 →  REPL.run()
blew mcp                                             →  MCP server over stdio (see 4.12)
```

Before any mode exits, `cleanupBeforeExit()` performs a best-effort disconnect (waits up to 2 seconds for the disconnect to complete). SIGINT and SIGTERM both call this function before exiting.

### 4.2 GlobalOptions and DeviceTargetingOptions

`GlobalOptions` is a `ParsableArguments` struct included via `@OptionGroup` in the root `Blew` command only. Global options must appear before the subcommand name. Subcommands access them via `GlobalOptions.current`, a static property set in `Blew.validate()`.

```
--verbose (-v)       flag count (0 / 1 / 2)
--timeout (-t)       Double? — BLE operation timeout
--out (-o)           OutputFormat: text | kv
```

`DeviceTargetingOptions` is a `ParsableArguments` struct included via `@OptionGroup` in each subcommand that connects to a device. These options appear after the subcommand name.

```
--id (-i)            String? — explicit device UUID
--name (-n)          String? — device name filter (substring)
--service (-S)       [String] — service UUID filter, repeatable
--manufacturer (-m)  Int? — manufacturer ID filter
--rssi-min (-R)      Int? — minimum RSSI (uppercase -R to avoid conflict with -r/--read, -r/--with-response)
--pick (-p)          PickStrategy: strongest | first | only
```

`DeviceTargetingOptions.toArgs()` serializes non-nil values into a flat string array passed to `CommandRouter.run*()` methods.

### 4.3 Subcommands

Each subcommand is a thin `ParsableCommand` that:
1. Validates/collects its own flags and an `@OptionGroup var targeting: DeviceTargetingOptions` where applicable
2. Creates a `CommandRouter` with `GlobalOptions.current`
3. Builds an args array via `targeting.toArgs()` + its own flags
4. Calls the matching `CommandRouter.run*()` method, receiving a `CommandResult`
5. Renders the result via `router.renderer.renderResult(result)`
6. Throws `BlewExitCode` if the result's exit code is non-zero

The subcommand list:

```
scan    [-n/-S/-R/-i/-m/-p] [-w/--watch]
connect [-n/-S/-i/-m/-p] [<device-id>]
exec    <script> [-k/--keep-going] [--dry-run]
gatt
  svcs  [-n/-S/-i/-m/-p]
  tree  [-n/-S/-i/-m/-p] [-d/--descriptors] [-r/--read]
  chars [-n/-S/-i/-m/-p] [-r/--read] <service-uuid>
  desc  [-n/-S/-i/-m/-p] <char-uuid>
  info  <char-uuid>                           (no device required)
read    [-n/-S/-i/-m/-p] [-f <fmt>] <char-uuid>
write   [-n/-S/-i/-m/-p] [-f <fmt>] [-r|-w] <char-uuid> <data>
sub     [-n/-S/-i/-m/-p] [-f <fmt>] [-d <sec>] [-c <count>] [-b] <char-uuid>
periph
  adv   [-n <name>] [-S <uuid>...] [-c/--config <file>]
  clone [-n/-S/-i/-m/-p] [-o/--save <file>]
```

`ExecCommand` replaces the old `--exec` global flag. It calls `CommandRouter.executeScript(_:keepGoing:dryRun:)` directly.

`PeriphCommand` is a normal subcommand container with two CLI-exposed nested subcommands: `AdvCommand` and `CloneCommand`. `AdvCommand` owns `-n`/`--name`, `-S`/`--service`, and `-c`/`--config`; `CloneCommand` uses `@OptionGroup var targeting: DeviceTargetingOptions` plus `--save`. Both serialize their parsed values into a string array and forward to `CommandRouter.runPeriphAdv()` / `runPeriphClone()`. The REPL-only periph commands (`stop`, `set`, `notify`, `status`) exist only in `CommandRouter.runPeriph()` and are not exposed as ArgumentParser subcommands.

`periph adv` and `periph clone` each run in two phases:

1. **Startup phase** (always blocking): configure the GATT server and call `startAdvertising`. Waits synchronously to confirm the peripheral came up successfully.
2. **Event-loop phase**: stream read/write/subscription events to stdout.

In CLI mode (ArgumentParser subcommand), phase 2 blocks until Ctrl-C — the process exits when advertising stops. In REPL and `exec` mode (`isInteractiveMode == true`), phase 2 runs as a stored background `Task` and the prompt (or script) continues immediately. `periph stop` cancels that task and stops advertising.

**macOS GAP name limitation:** `CBAdvertisementDataLocalNameKey` sets the advertising local name in the BLE advertisement data, but macOS always uses the computer hostname as the GAP (Generic Access Profile) device name. iOS scanners that have previously connected to the Mac will show the cached GAP name (hostname) in their device list instead of the advertising name. The advertising name is still accessible in the raw advertisement data (`kCBAdvDataLocalName`).

Additional `periph` subcommands available in REPL and `exec` mode (usable after `periph adv` or `periph clone` returns the prompt):

```
periph stop                             — cancel background event task, stop advertising
periph set  [-f <fmt>]  <char>  <val>  — update characteristic value in store
periph notify [-f <fmt>] <char> <val>  — update value and push notification to subscribers
periph status                          — show advertising state
```

`gatt info` does not require a connected device. It looks up the UUID in the generated `GATTCharacteristicDB` and prints the Bluetooth SIG specification: name, description, and field structure.

`disconnect` and `status` are available in REPL and `exec` mode but are not exposed as CLI subcommands — they carry no value when the process starts fresh with no persistent state.

`sleep <seconds>` pauses execution for the given number of seconds. `0` means infinite (block until Ctrl-C). Available in REPL and `exec` mode; not exposed as a CLI subcommand.

`sub` supports a `-b` (`--bg`) flag in REPL and `exec` mode that runs the subscription as a stored background `Task`, printing each notification via `printLive()` (stderr with ANSI cursor control) while the prompt remains available. Multiple simultaneous background subscriptions are supported, keyed by characteristic UUID. Two additional REPL/exec-only sub-subcommands manage them:

```
sub stop [<char-uuid>]   — cancel one (or all) background subscriptions
sub status               — list active background subscriptions
```

Background sub tasks are stored in `CommandRouter.backgroundSubTasks: [String: Task<Void, Never>]`, following the same pattern as `backgroundPeriphTask`. Starting a new `-b` sub on an already-subscribed UUID cancels and replaces the previous task. Background tasks are implicitly cleaned up when the notification stream ends (e.g. on disconnect).

### 4.4 Implicit auto-connect

`gatt`, `read`, `write`, and `sub` call `CommandRouter.ensureConnected(args:)` before executing. This means operations can be used directly from the CLI without a separate `connect` step:

```
blew gatt tree -i <uuid>
blew read -n "My Device" 2A19
```

`ensureConnected(args:)` is a no-op when a connection is already established (REPL / `exec` after an explicit `connect`). When not connected it resolves the target device from the args array:

1. `-i`/`--id` present → connect directly
2. Any scan filter present (`-n`, `-S`, `-m`, `-R`) → build scan args, run a scan, apply `-p` pick strategy to select one device, then connect
3. Neither → error: user must specify a device

The `pickDevice(from:pick:)` helper applies the pick parameter:
- `strongest` / `first` → first element of the RSSI-sorted scan results
- `only` → the single result, or an error listing all candidates if more than one was found

### 4.5 CommandRouter

The central command dispatcher. It is the shared implementation used by all three entry paths (ArgumentParser subcommands, `exec`, and REPL).

**`dispatch(_:)`** — tokenizes a single command-line string (with basic single/double-quote handling) and routes to the appropriate `run*()` method. Returns a `CommandResult`. After each `run*()` call, `dispatch()` renders the result via its `renderer` (which writes output to stdout/stderr). This means REPL callers get automatic rendering, while CLI subcommands render explicitly.

**`executeScript(_:keepGoing:dryRun:)`** — splits the script string on `;`, strips whitespace and empty segments, calls `dispatch` on each. Returns `Int32` exit code. With `dryRun: true`, prints numbered steps instead. With `keepGoing: true`, records first error but continues.

**`run*()` methods** — each is a synchronous function that returns a `CommandResult` containing structured output. The method:
1. Parses its args from the token array via private helpers: `parseStringOption`, `parseIntOption`, `parseDoubleOption`, `parseAllStringOptions`
2. Creates a `DispatchSemaphore`
3. Launches a `Task` calling the appropriate `BLECentral.shared` async method
4. Appends structured `CommandOutput` items to the result (instead of printing directly)
5. Signals the semaphore on completion (success or error)
6. Waits on the semaphore
7. Returns the `CommandResult`

Commands fall into two categories:
- **Non-streaming commands** (scan, connect, disconnect, status, read, write, gatt *, periph set/notify/status/stop): produce all output before returning. Their `CommandResult` contains the full structured output.
- **Streaming commands** (foreground sub, periph adv/clone event loops): produce output incrementally during execution. These accept an `emit: @escaping @Sendable (CommandOutput) -> Void` closure and call it for each item as it arrives. Their `CommandResult` contains only the exit code and any errors. The caller decides what the emit closure does — interactive callers pass `renderer.render(_:)`, MCP callers collect items into an array.

`runSub`, `runPeriph`, `runPeriphAdv`, and `runPeriphClone` all accept an `emit` parameter with a no-op default so existing call sites without a need for streaming output require no change.

This semaphore pattern bridges Swift's structured concurrency into the synchronous world of the CLI main thread and REPL loop.

**Device/UUID resolution** — `CommandRouter` can resolve partial or friendly identifiers to full UUIDs:

- `resolveDevice(_:)`: tries (in order) exact UUID match → name substring match → UUID substring match (hyphens stripped). Returns `.resolved`, `.ambiguous`, or `.notFound`.
- `resolveCharacteristic(_:)` / `resolveService(_:)`: prefix-matches against the `BLECentral`-cached UUID lists. After `connect`, all characteristic UUIDs are known, enabling short-prefix convenience like `2A` to match `2A19`.

**Scan results cache** — `lastScanResults: [DiscoveredDevice]` is updated after every successful scan. Used for device resolution in `connect` and for REPL tab completion.

**Scan UI** — uses the `ScanSpinner` (a `DispatchSourceTimer`-based braille spinner on stderr) when stdout is a TTY and a scan is running. In `--watch` mode, uses `ScanWatchDisplay` instead — a timer-based renderer that redraws the device table in-place on stderr every 250 ms using ANSI cursor movement. When the watch loop exits (Ctrl-C or timeout), the final table is printed once to stdout so it persists in scroll history.

### 4.6 Output architecture

Command output is structured rather than text-based. Commands produce `CommandResult` values containing typed `CommandOutput` items, and renderers convert these to text or key-value format for display.

**CommandResult and CommandOutput** (`Sources/blew/Output/CommandOutput.swift`)

`CommandResult` holds the exit code, an array of `CommandOutput` items, and arrays of error/info/debug messages:

```
struct CommandResult {
    var exitCode: Int32
    var output: [CommandOutput]
    var errors: [String]
    var infos: [String]
    var debugs: [String]
}
```

`CommandOutput` is an enum with cases for each kind of structured data: `.devices`, `.services`, `.characteristics`, `.descriptors`, `.gattTree`, `.characteristicInfo`, `.connectionStatus`, `.peripheralStatus`, `.readValue`, `.writeSuccess`, `.notification`, `.peripheralSummary`, `.peripheralEvent`, `.subscriptionList`, `.message`, `.empty`.

Each case wraps lightweight row/result structs (`DeviceRow`, `ServiceRow`, `CharacteristicRow`, `GATTTreeService`, `ReadResult`, `NotificationValue`, etc.) that carry display-oriented data.

**OutputRenderer protocol** (`Sources/blew/Output/OutputRenderer.swift`)

```
protocol OutputRenderer {
    func render(_ output: CommandOutput)
    func renderError(_ message: String)
    func renderInfo(_ message: String)
    func renderDebug(_ message: String)
    func renderResult(_ result: CommandResult)
    func renderLive(_ text: String)
}
```

Three implementations:

- **TextRenderer** (`Sources/blew/Output/TextRenderer.swift`): produces human-readable text output with aligned tables, GATT tree drawing, ANSI bold/dim when stdout is a TTY. Uses `OutputFormatter` internally for table formatting and ANSI helpers.
- **KVRenderer** (`Sources/blew/Output/KVRenderer.swift`): produces machine-readable `key=value` lines.
- **NullRenderer** (`Sources/blew/Output/NullRenderer.swift`): discards all output. Used by the MCP server to prevent any command output from reaching the JSON-RPC stdout transport.

**OutputFormatter** (`Sources/blew/Output/OutputFormatter.swift`)

Narrowed to a formatting utility used internally by `TextRenderer`. Provides:
- `bold(_:)` / `dim(_:)` — ANSI escape wrappers (no-op when not a TTY or in KV mode)
- `boldPaddingWidth` — byte-count adjustment for ANSI sequences in column alignment
- `formatTable(headers:rows:)` — builds an aligned text table as a `String`
- `printTable(headers:rows:)` / `printRecord(_:)` — convenience methods that format and write to stdout

The `isTTY` flag is detected at init time via `isatty(fileno(stdout))`. ANSI escapes are only applied in text mode with a TTY, so piped output is never polluted.

The `ScanWatchDisplay` still uses `OutputFormatter.formatTable` directly to compose its in-place redraw buffer on stderr.

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
| `gatt <partial>` | `svcs`, `tree`, `chars`, `desc`, `info` |
| `gatt chars [flags] <partial>` | Known service UUIDs (prefix match on first positional) |
| `gatt desc <partial>` | Known characteristic UUIDs (prefix match on first positional) |
| `read/write/sub [flags] <partial>` | Known characteristic UUIDs (prefix match on first positional) |
| After `-f`/`--format` | All format names |

### 4.9 GATTDecoder and GATTCharacteristicDB

`GATTDecoder` is the runtime decoder for standard Bluetooth SIG characteristic values. It replaces the old hand-maintained `WellKnownCharacteristics` table.

**Data source**

`GATTCharacteristicDB` is a generated enum (from `BLECharacteristics.generated.swift`) containing the complete field-level structure of all 265+ Bluetooth SIG characteristics sourced from the official bluetooth-SIG repository at `Vendor/bluetooth-SIG/gss/`. Each characteristic entry includes:

- `name` and `description` from the Bluetooth SIG GSS YAML files
- `fields: [Field]` — a flat ordered list of fully resolved fields, each with:
  - `name`: field name (struct fields are recursively inlined with dot-separated names, e.g. `"Date Time.Year"`)
  - `type`: a `FieldType` case — `uint8/16/24/32/48/64`, `sint8/16/32`, `boolean8/16/32`, `medfloat16/32`, `utf8s`, or `opaque`
  - `size`: byte count when present; `-1` = variable; `-2` = variable-length array
  - `flagBit`/`flagSet`: conditional field presence (`flagBit == -1` means always present; `flagBit >= 0` means present only when that bit of the first boolean/flags field has the value `flagSet`)

**Struct resolution**

Many GSS characteristics embed sub-structures defined in other characteristics (e.g., `Date Time` characteristic embedded inside `Day Date Time`). The code generator (`Scripts/generate-ble-characteristics.rb`) resolves these recursively at build time by following `\autoref{sec:org.bluetooth.characteristic.XXX}` annotations in each `struct`-typed field's description. Circular references and missing references fall back to `.opaque` fields with a build-time warning.

**Decoding** (`GATTDecoder.decode(_:uuid:)`)

Reads fields sequentially from the `Data` buffer:
1. The first `boolean[N]` field is decoded and stored as a flags bitmap.
2. Each subsequent conditional field (`flagBit >= 0`) is included or skipped based on that bitmap.
3. Variable-length fields consume all remaining bytes.
4. Single-field characteristics emit just the value; multi-field characteristics emit `"FieldName: value | FieldName: value"`.

Supported types include all standard GATT integer types (`uint8` through `uint64`, `sint8`/`sint16`/`sint32`), IEEE 11073-20601 medical floats (`medfloat16`, `medfloat32`), UTF-8 strings, and hex-encoded opaque blobs.

**Info query** (`GATTDecoder.info(for:)`)

Returns a `CharacteristicInfo` struct for use by `gatt info`, containing the name, description, and a `FieldInfo` array with human-readable type and size descriptions.

### 4.10 BLENames

`BLENames` is a namespace enum in the `blew` executable target responsible for mapping standard Bluetooth SIG UUIDs to human-readable names.

**Data sources**

Two git submodules under `Vendor/` provide the raw data:

- `Vendor/bluetooth-numbers-database/` — Nordic Semiconductor's JSON database with `service_uuids.json`, `characteristic_uuids.json`, and `descriptor_uuids.json` under `v1/`. Entries with `source == "gss"` are official Bluetooth SIG assignments.
- `Vendor/bluetooth-SIG/` — The official Bluetooth SIG repository. `assigned_numbers/uuids/characteristic_uuids.yaml` provides the UUID-to-identifier mapping; `gss/*.yaml` (277 files) provides full characteristic structure definitions.

**Build-time generation**

The `GenerateBLENames` SwiftPM build tool plugin (`Plugins/GenerateBLENames/plugin.swift`) declares a single `prebuildCommand` that runs `Scripts/generate-all-ble.sh` before each build. That shell script invokes two Ruby generators in sequence:

1. `Scripts/generate-ble-names.rb` — reads the Nordic JSON files, filters to `source == "gss"` entries, deduplicates by UUID, and writes `BLENames.generated.swift` (UUID-to-name dictionaries for services, characteristics, and descriptors).
2. `Scripts/generate-ble-characteristics.rb` — reads `characteristic_uuids.yaml` and all `gss/*.yaml` files, resolves struct fields recursively via `\autoref` annotations, and writes `BLECharacteristics.generated.swift` (the full `GATTCharacteristicDB` with field-level structure for each characteristic). Build-time warnings are emitted for struct fields that cannot be resolved.

Both generated files are written to SwiftPM's plugin work directory and compiled as part of the `blew` target. Neither is checked in.

To update the databases, run `git submodule update --remote` and rebuild.

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

### 4.12 MCP Server Mode

`blew mcp` starts an MCP (Model Context Protocol) server over stdio, allowing AI agents (Cursor, Claude Desktop, etc.) to discover and invoke BLE operations as structured tool calls.

**Architecture:**

The MCP server reuses the existing structured output system. Instead of rendering `CommandOutput` to text (via `TextRenderer` / `KVRenderer`), the server converts `CommandResult` data directly to JSON via `Codable` conformances and returns it as MCP `structuredContent`.

```
AI Agent
  | JSON-RPC over stdio
  v
BlewMCPServer (MCP SDK Server actor, StdioTransport)
  | run*() calls
  v
CommandRouter (isInteractiveMode: true, renderer: NullRenderer)
  | CommandResult with typed CommandOutput items
  v
BlewMCPServer
  | encodes Codable output types -> structuredContent (JSON)
  | builds text summary -> content fallback
  v
CallTool.Result { content: [.text(...)], structuredContent: Value, isError: Bool }
```

**Key files:**

| File | Role |
|------|------|
| `Sources/blew/Commands/MCPCommand.swift` | `AsyncParsableCommand` entry point for `blew mcp` |
| `Sources/blew/MCP/MCPServer.swift` | MCP server: tool definitions, call dispatch, `CommandOutput` to JSON conversion |
| `Sources/blew/Output/NullRenderer.swift` | `OutputRenderer` that discards all output (prevents any command output from reaching the JSON-RPC stdout) |

**Tool dispatch:**

The MCP server calls `CommandRouter.run*()` methods directly (not through `dispatch()`) to avoid automatic rendering to stdout. Non-streaming commands return their full output in `CommandResult.output`. For streaming commands (`sub`, `periph adv/clone`), the server passes a collecting closure as the `emit` parameter — items are accumulated in a local `StreamCollector`, then prepended to `CommandResult.output` before JSON encoding.

**Structured content:**

Each tool result includes both `structuredContent` (typed JSON via `Codable`) and a text `content` fallback. All output types (`DeviceRow`, `ServiceRow`, `CharacteristicRow`, `ReadResult`, `NotificationValue`, etc.) conform to `Codable`. The `StructuredResult` enum wraps each output type with a `type` discriminator for JSON serialization.

**Tool list:**

| MCP Tool | blew Command | Key Parameters |
|----------|-------------|----------------|
| `ble_scan` | `scan` | name?, service?, rssi_min?, manufacturer?, pick?, timeout? |
| `ble_connect` | `connect` | device_id?, name?, service?, manufacturer?, rssi_min?, pick? |
| `ble_disconnect` | `disconnect` | (none) |
| `ble_status` | `status` | (none) |
| `ble_gatt_services` | `gatt svcs` | targeting options |
| `ble_gatt_tree` | `gatt tree` | targeting options, descriptors?, read_values? |
| `ble_gatt_chars` | `gatt chars` | targeting options, service_uuid, read_values? |
| `ble_gatt_descriptors` | `gatt desc` | targeting options, char_uuid |
| `ble_gatt_info` | `gatt info` | char_uuid |
| `ble_read` | `read` | targeting options, char_uuid, format? |
| `ble_write` | `write` | targeting options, char_uuid, data, format?, with_response? |
| `ble_subscribe` | `sub` | targeting options, char_uuid, format?, duration?, count? |
| `ble_periph_advertise` | `periph adv` | name?, services?, config_file? |
| `ble_periph_clone` | `periph clone` | targeting options, save_file? |
| `ble_periph_stop` | `periph stop` | (none) |
| `ble_periph_set` | `periph set` | char_uuid, value, format? |
| `ble_periph_notify` | `periph notify` | char_uuid, value, format? |
| `ble_periph_status` | `periph status` | (none) |

**Subscribe behavior:** `ble_subscribe` collects notifications for the specified `duration` or `count`. If neither is specified, defaults to `count: 10` to prevent infinite blocking. All values are returned at once as a `[NotificationValue]` array.

**Peripheral commands:** `ble_periph_advertise` and `ble_periph_clone` start the peripheral and return the summary immediately (the `CommandRouter` runs with `isInteractiveMode: true`). Subsequent `ble_periph_status`, `ble_periph_set`, `ble_periph_notify`, `ble_periph_stop` calls operate on the running peripheral.

**stdout constraint:** In MCP mode, stdout is the JSON-RPC transport. The `CollectingRenderer` prevents any command output from being written to stdout, which would corrupt the transport. The `isTTY` check in `OutputFormatter` naturally returns false when stdout is a pipe.

---

## 5. Threading model

```
Thread                  Runs
──────────────────────  ─────────────────────────────────────────────
Main thread             ArgumentParser, REPL getLine loop,
                        synchronous command dispatch,
                        DispatchSemaphore.wait() during BLE operations
blew.cb (serial queue)  All CBCentralManager / CBPeripheral calls (central)
blew.pm (serial queue)  All CBPeripheralManager calls + delegate callbacks
                        GATTStore reads/writes (under NSLock)
blew.event-processor    BLEEventQueue drain loop, continuation resumes
Swift cooperative pool  async Task bodies (BLECentral and BLEPeripheral)
```

The `blew.pm` queue is separate from `blew.cb`. Both can coexist during `periph clone` (which temporarily runs in central mode to snapshot a real device, then switches to peripheral mode).

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
 │     Central: BLECentral, BLEDelegate, BLEEventQueue, BLEEventProcessor
 │     Peripheral: BLEPeripheral, BLEPeripheralDelegate, GATTStore
 │     Shared: BLEError, PeripheralTypes, PeripheralEvent, DeviceInfo
 ├── LineNoise                         (system libedit — linenoise Swift implementation)
 ├── ArgumentParser                    (swift-argument-parser)
 ├── MCP                               (modelcontextprotocol/swift-sdk)
 └── [build plugin] GenerateBLENames   runs Scripts/generate-all-ble.sh, which invokes:
                                         Scripts/generate-ble-names.rb
                                           reads Vendor/bluetooth-numbers-database/v1/*.json
                                           emits BLENames.generated.swift
                                         Scripts/generate-ble-characteristics.rb
                                           reads Vendor/bluetooth-SIG/gss/*.yaml
                                           reads Vendor/bluetooth-SIG/assigned_numbers/uuids/characteristic_uuids.yaml
                                           emits BLECharacteristics.generated.swift
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
