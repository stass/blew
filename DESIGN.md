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
│  BLEEventProcessor  ◄──  BLEEventQueue (FIFO)       ◄──  BLEDelegate│
│  (dedicated thread)       (drops scan results only) (CB queue)   │
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
   BLEEventQueue  (FIFO; only scan results are dropped when 1024 wait)
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
isReadyToSendWriteWithoutResponse(peripheralId)
```

### 3.3 BLEEventQueue

A FIFO under one `NSLock`, from `BLEDelegate` (and the processor's `connectIssued` markers), both on blew.cb, to `BLEEventProcessor` on its thread. The consumer blocks on a `DispatchSemaphore` signalled once per queued event.

Only scan results are ever dropped. A `didDiscover` that arrives while `scanResultLimit` (1024) events wait is dropped and counted in `droppedScanResults`, which `status` reports at `-vv`. A scan result answers no wait and is repeated by the device (each advertisement is a new result), so under an `allowDuplicates` flood dropping one loses at most an RSSI update. Every other event either answers or ends a wait (a connect, a GATT request, a disconnect, a state change), or is a notification value the device does not send again; dropping one would hang its wait or lose data without a trace, so those are always queued. Their number is bounded by what the device sends while the processor falls behind, and the processor never blocks on a consumer (streams buffer, continuations resume at once), so it falls behind only by scheduling latency. A bounded queue that drops lifecycle events, or blocks blew.cb when full, would hang waits or stall CoreBluetooth; separate lanes for scan results and other events would lose the order between a scan result and the connect it led to, for no gain.

### 3.4 BLEEventProcessor

Runs a permanent `while running` loop on a dedicated `Thread` named `blew.event-processor`. On each dequeued event it calls `handleEvent(_:)` under `NSLock`.

`handleEvent` maintains two kinds of registered handlers:

**One-shot `CheckedContinuation`s** (for operations that complete exactly once):

| Operation | Continuation type |
|-----------|------------------|
| connect | `CheckedContinuation<Void, Error>` in the `link` |
| disconnect | `CheckedContinuation<Void, Error>` |
| GATT requests: discoverServices, discoverCharacteristics, discoverDescriptors, read, write with response | `PendingCallbacks<CentralCallback, CentralWaiter>`, a FIFO per answering callback (`CentralRequest.swift`) |
| write without response (wait until ready) | the same `PendingCallbacks`, never issued, carrying its poll |
| subscribe (wait for notifications to be confirmed on) | `NotificationSubscriptions`, per subscriber |

**Ongoing stream continuations** (for streaming operations):

| Operation | Continuation type |
|-----------|------------------|
| scan | `ScanSink`, of the one running scan (`ScanID`) |
| notifications | one `NotificationSink` (a bounded stream) per subscriber, in `NotificationSubscriptions` |

**GATT requests are matched to their answers in issue order.** CoreBluetooth answers a peripheral's requests in the order they were made (ATT allows one outstanding request per bearer, and CoreBluetooth queues the rest), one callback each, with no request identifier. Each request is a `CentralRequest` (the wait for its answer, with the characteristic or service it names); the callback that answers it, a `CentralCallback`, follows from it, and is the key of its FIFO in `PendingCallbacks` (the type the peripheral side uses too). `BLECentral.request` drives every GATT request the same way:

1. `makeTicket()` reserves the request's identity before the wait exists, and the task's cancellation handler cancels that ticket, so a cancellation that comes first is not lost.
2. `submit(ticket, request, to: peripheral, on: blew.cb, call:)` registers the wait (or fails it with `CancellationError` when the ticket was cancelled first), then on blew.cb queues the request under its callback and makes the CoreBluetooth call in the same block. The FIFO order is therefore the order CoreBluetooth gets the calls. A request whose peripheral is no longer the connected one when its block runs fails with `notConnected` and is not made.
3. The answering callback takes the oldest request of its FIFO. A request cancelled after it went out stays in it as abandoned: the wait ends at once with `CancellationError`, and its late answer is consumed as its own instead of completing the next request.

Several requests to one characteristic may be in flight at once (a REPL `read` beside a background subscription, concurrent MCP calls); each gets its own answer. Refusing a second request while one is in flight would be no simpler (an abandoned request occupies its slot just as long) and would turn concurrent use into errors. The model relies on CoreBluetooth answering every request it makes, in order, or ending the connection (unverified for Enhanced ATT, where several bearers could answer one characteristic's requests out of order). A request it dropped without a callback would jam its FIFO until the disconnect: each later answer would be taken by the request before it, so requests in sequence would each time out, and concurrent ones would get each other's answers. TESTS.md has the manual checks. Requests CoreBluetooth is known to have no answer for are refused before they are issued (`CharacteristicAccess`): a read of a characteristic without the read property, a write of a type its properties do not allow (`-r` needs write, `-w` needs writeWithoutResponse, and the default picks without response when allowed, with response otherwise), a value longer than `maximumWriteValueLength` for the write type, and a subscribe to a characteristic that neither notifies nor indicates. Each fails with the error a refusal by the device would give (`readFailed`, `writeFailed`, `subscribeFailed`; exit code 5).

`didUpdateValue` is the one event that serves two purposes, and CoreBluetooth does not say which: a read's answer or a notification. A value with an error answers the oldest read in flight. A value without one is yielded to every subscriber's stream, so no notification is lost to a read, and also answers the oldest read in flight. While notifications are on, a read therefore completes with the first value after it was issued, which may be a notification, and its own answer then reaches the streams; after a read of a notifying characteristic was abandoned, the next read can complete with that read's late answer. README.md states this for `read`. While notifications are off, every value answers a read.

A write without response waits until the peripheral can take it. Its wait is a `CentralWaiter.readyToWrite` that stays unissued in the same `PendingCallbacks`, so it shares the ticket and cancellation path, and it carries a poll that runs at once and again on every `isReadyToSendWriteWithoutResponse`. The poll checks `canSendWriteWithoutResponse` on blew.cb and, when it is true, makes the write and resumes the wait in that block (`sendIfWaiting`), so no other write takes the room in between and a cancelled write is never sent. One ready event wakes every waiting write, oldest ticket first, so the polls queue their checks on blew.cb in that order; each that finds no room waits for the next. A new write's first poll runs when it registers, so one that arrives just as room frees up can still go ahead of older waiters.

**Notifications have one owner per characteristic**, `NotificationSubscriptions` in the processor. Each `BLECentral.subscribe` is a subscriber with its own stream: `sub -b X`, a foreground `sub X` beside it, an MCP subscribe and the NUS bridge can all subscribe to one characteristic, and each gets every value. Notifications are turned on for the first subscriber and off when the last one leaves (its stream ends, or its subscribe was given up). At most one `setNotifyValue` call per characteristic is in flight; when `didUpdateNotificationState` acknowledges it, the next call is made only if the subscribers now want the other state. Each acknowledgement therefore answers the call before it, `setNotifyValue(true)` is never made while notifications are on, and `setNotifyValue(false)` is made only after the device confirmed them on (a subscribe given up while they were being turned on turns them off once the confirmation arrives). The subscriber's stream is registered before notifications are turned on, so a notification right after the confirmation reaches it, and a disconnect at any point finishes it. Its wait resumes when the device confirms notifications on (at once when they already are) and fails with the device's error, which fails every subscriber waiting for that confirmation. A failed turning-off leaves them on, which is what the device reports; it is retried only when a later subscriber leaves, so a device that keeps refusing is not asked again and again. The `setNotifyValue` call is made on blew.cb and only while the subscriber's peripheral is still the connected one. Like a GATT request, this relies on CoreBluetooth acknowledging every call: an acknowledgement that never came would leave the call in flight, and every later subscribe to that characteristic would time out until the disconnect. `subscribe` takes a subscriber ID made by `makeSubscriberID()` before the wait exists, so a cancellation that comes first is not lost, like a request's ticket.

**A scan stream holds at most one unread result per device.** A scan that allows duplicates (`scan -w`) gets an advertisement from every device in range many times a second, with no flow control, so a reader slower than that (a redraw, a kv pipe) would otherwise make the stream's buffer grow for as long as the watch runs. `ScanStream` keeps the unread results in its `ScanSink`, one per identifier, in the order their devices were first seen while unread: an advertisement of a device whose result is still unread merges into it with `DiscoveredDevice.merging`, the same merge `ScanResults` applies, and keeps its place. The stream drops nothing, so it never loses a device's first sighting (the event queue in front of it can, under a flood; see below), and the waiting results are bounded by the number of distinct devices the scan sees, which `ScanResults` in the router holds for the whole scan anyway; a separate bound on the stream would not bound the scan's memory (TODO.md S15). The stream itself carries only wake-ups (an `AsyncThrowingStream<Void, Error>` holding at most one), whose end is the scan's end: the reader reads what waits, then the stream finishes or throws. A cancelled reader gets nil at once and ends the scan, also while results wait.

**A notification stream holds at most `NotificationStream.capacity` (1024) values.** Notifications have no flow control, and the processor never waits for a consumer, so a subscriber that reads slower than the device sends (`sub` to a paused terminal or a slow pipe) would otherwise grow blew's memory without limit, once per subscriber. Each subscriber's stream buffers the newest 1024 values (at most 512 KiB, an attribute value being at most 512 bytes); when another arrives, the oldest waiting one is dropped and counted in that subscriber's `droppedCount`, so a slow subscriber costs the others nothing. Its reader reports the drops: `sub` (through `CommandRouter.forEachNotification`) once when it first sees them and with the total when it ends, an MCP `ble_subscribe` result in its `dropped` field, and the NUS bridge as a `dropped` status at a session's first loss and with its total when it ends. An MCP `ble_subscribe` collects every value into its result as it comes, so its buffer does not fill; its memory is bounded by the call's duration. 1024 is about a second of a fast device's notifications, enough to ride out a scheduling delay of the reader without holding much memory.

The processor serves one connection at a time, its `link`, and each link belongs to one `ConnectAttempt` (the peripheral and a serial number from `makeConnectAttempt(to:)`, made before the wait exists, like a request's ticket). The link is `connecting(attempt, continuation, issued:)` from `beginConnect` until `didConnect`, then `connected(attempt)` until `didDisconnect`. A `didFailToConnect`, a cancelled connect (`cancelConnect(attempt)`), a connect past its deadline, a connection whose service discovery failed or was cancelled (`endConnection(attempt)`), a `beginConnect` while a link is held, and Bluetooth leaving `poweredOn` clear it. Cancels, deadlines and setup failures name their attempt, so one caller's cancel or deadline cannot end another caller's connect, also to the same device. The link is the one record of which peripheral is connected: `BLECentral` reads it (`connectedPeripheralId`, `isConnected(attempt)`) and keeps no copy.

**A connect takes only the answers to its own connect call.** CoreBluetooth's callbacks carry the peripheral, not the call they answer, so a late callback of an earlier attempt to the same device looks like the current one's. Two rules separate them. First, the CoreBluetooth `connect` is made through `issueConnect(attempt)` on blew.cb, which queues the attempt's `connectIssued` marker in the same block (and makes no call once the attempt stopped waiting). Callbacks are queued on blew.cb too, so the marker reaches the processor after every callback CoreBluetooth sent before the call; the attempt is `issued` from its marker on, and only then does a `didConnect` or `didFailToConnect` answer it. A `didConnect` of a cancelled attempt, queued before the retry's call, is dropped. Second, a `didDisconnect` while connecting is taken as the late answer to blew cancelling an earlier connection to the device (a failed setup, a cancelled connect), and is dropped, so a REPL or MCP retry faster than that cancel's round trip is not failed by it. This assumes CoreBluetooth answers a pending connect with `didConnect` or `didFailToConnect`, never `didDisconnect`; Apple's documentation does not say so, and it is unverified. It fails safely: were a pending connect ended by `didDisconnect`, the attempt would wait until its deadline and fail with `timeout` (exit code 4) instead of `connectionFailed` (exit code 5). Also unverified: whether CoreBluetooth may deliver a retry's `didConnect` before the previous connection's `didDisconnect`, and whether a pending connect survives `resetting` followed by `poweredOn` (blew cannot cancel it while the central is not poweredOn, so such a connect would connect the device later with no owner). TESTS.md has the manual checks.

**When blew ends a link, blew cancels its connection.** When blew, not CoreBluetooth, ends a link (a cancelled, replaced or timed-out connect, or a failed setup), the processor queues the canceller `BLECentral` registered (`onCancelConnection`, `cancelPeripheralConnection`) on blew.cb while it still holds the lock that ended the link. It therefore runs after any connect call of the ended attempt (made only while that attempt waited) and before the connect call of any later attempt, also one started at once from another thread (its `beginConnect` takes the lock after, and its `issueConnect` is queued after that), so it cannot cancel a retry. A replaced connection (a second caller's `connect` started while the first one's device was connected) is disconnected instead of staying connected at the OS level. A link CoreBluetooth ended (`didDisconnect`, `didFailToConnect`, a state other than `poweredOn`) needs no cancel. The link-ended callbacks (`onLinkEnded`) get the attempt, so `BLECentral` clears its cache only when it describes that attempt's connection.

**Nothing is registered while Bluetooth is not `poweredOn`.** The processor holds the central's state, set from `centralStateChanged` under the same lock that registrations take, and `BLECentral` reads it (`centralState`). A connect, a GATT request when it would go out, a write without response, a subscribe and a scan each fail at once with `bluetoothUnavailable` (exit code 3) while the state is anything else, so a registration made just after a power-off either sees the new state or came first and is ended by it (with `bluetoothUnavailable` too). A request whose link ended while Bluetooth stayed on fails with `notConnected`. A disconnect wait needs no refusal: a link exists only while the state is poweredOn, so a disconnect after a power-off finds nothing connected and returns at once, as one registered just before it is resumed by it.

Every one-shot continuation and notification stream belongs to the link. Events of any other peripheral are dropped before dispatch (`BLEEvent.connectionPeripheralId`); only the central's state and scan results belong to no peripheral. A late `didConnect`, `didDisconnect` or GATT result of a device blew stopped connecting to, or disconnected, therefore cannot complete or fail an operation on the current one; for an earlier attempt to the same device, the marker and the connecting rule above do the same for the connect callbacks.

When the link ends (`didDisconnect` of its peripheral, `endConnection(attempt)`, `cancelConnect(attempt)` or the connect deadline, a `beginConnect` while a link is still held, or a central state other than `poweredOn`), all active notification streams are finished with the error that ended it, and any pending continuations, including a waiting connect and every GATT request in flight or waiting to go out, are failed with that error; the FIFOs are emptied, since nothing in flight will be answered. A state change to `poweredOff`, `unauthorized`, `resetting` or `unsupported` (any state but `poweredOn`) ends the link with `BLEError.bluetoothUnavailable` and also finishes the scan stream, because CoreBluetooth stops scanning and drops its connections (whether it also sends a per-peripheral `didDisconnect` first, which would end the link with `connectionFailed`, is unverified; TESTS.md has the manual check); the new state is set under the lock before these effects run, so a caller woken by them already sees it. The link-ended callbacks run too, so `BLECentral` forgets a connection the device or the link ended, not only one it ended itself; they run before the waiting disconnects resume, so `disconnect()` returns with the state cleared. Each `beginDisconnect` holds its own wait (`DisconnectWait`, from `makeDisconnectWait()`); several may wait at once, every one resumes when the link ends, and `cancelDisconnect` ends only the one it names.

### 3.5 BLECentral (central facade)

The public facade and the only exported type. It is a singleton (`BLECentral.shared`).

Responsibilities:

- Owns `CBCentralManager`, `BLEDelegate`, `BLEEventQueue`, `BLEEventProcessor`
- Serializes all CoreBluetooth calls onto `blew.cb` (a dedicated serial `DispatchQueue`)
- Caches the connection's name, all discovered `CBService` and `CBCharacteristic` objects and active subscription UUIDs under `NSLock`. Which peripheral is connected is the processor's link; the cache is written only while that peripheral is connected (`updateConnection`) and cleared by the link-ended callback
- Exposes an async/await API that bridges to the continuation/stream model

Key behaviors:

- **`scan(timeout:allowDuplicates:)`** — starts `CBCentralManager.scanForPeripherals`, returns a `ScanStream`, which keeps at most one unread result per device (see below). Each scan has an identity (`ScanID`), and the processor holds the one running scan. When `timeout` is non-nil, a deadline on blew.cb ends that scan after that many seconds: the stream finishes and CoreBluetooth stops scanning. When `timeout` is `nil` the stream runs until the caller cancels (used by `--watch` mode). A deadline or a reader stopping ends only its own scan, so an interrupted scan's deadline cannot stop a later one. Commands run one at a time, so two scans overlap only when an interrupted command's task outlives `waitInterruptible`'s grace and still holds its scan; a scan started then replaces it: the earlier stream throws `operationFailed`, and CoreBluetooth is not stopped, since the new `scanForPeripherals` replaces its scan. Bluetooth leaving poweredOn ends the scan with `bluetoothUnavailable` (exit code 3), and a scan is refused with it while the state is not poweredOn. The `scanForPeripherals` and `stopScan` calls are queued on blew.cb under the lock that changes the running scan, so CoreBluetooth gets them in the order the scans begin and end. `allowDuplicates` maps directly to `CBCentralManagerScanOptionAllowDuplicatesKey`; watch mode passes `true` so RSSI updates arrive continuously.
- **`connect(deviceId:timeout:)`** — looks up the peripheral in the delegate's cache or via `retrievePeripherals(withIdentifiers:)`, connects, then immediately runs full GATT discovery (all services, all characteristics for each service) so subsequent read/write/subscribe calls can proceed without additional discovery round-trips. blew holds one connection: the connected device is disconnected first, also when it is the one asked for, so every connect runs connect and discovery afresh. `timeout` is the connect's own deadline: when the device has not connected that many seconds after `beginConnect`, the wait fails with `BLEError.timeout` (exit code 4), checked on blew.cb, so a caller need not cancel the task to bound it. Service discovery after `didConnect` is outside that deadline and ends when CoreBluetooth answers or the caller cancels. A connect that blew gives up (cancelled by an interrupt or the caller's timeout, past its deadline, or replaced) is cancelled in CoreBluetooth through `onCancelConnection`, because CoreBluetooth otherwise keeps the connect pending and connects the device later. Ordering on `blew.cb` makes this hold for every interleaving: `issueConnect` makes the call only while the processor still waits for the attempt, and the cancel is queued after the wait ended. A connect that reached the device but whose service discovery then failed or was cancelled (including a cancel just after `didConnect`) is not kept either: `endConnection(to:)` ends the link at once, so the state is "not connected" and auto-connect does not reuse a connection with an empty GATT cache, and `cancelPeripheralConnection` disconnects the device.
- **`writeCharacteristic(_:data:type:)`** — a write with response waits for `didWriteValue`. A write without response first waits until `canSendWriteWithoutResponse` is true (polled on `blew.cb` after any earlier write, or signalled by `peripheralIsReady(toSendWriteWithoutResponse:)`), because CoreBluetooth silently drops one issued while it is false.
- **`maximumWriteLength(withResponse:)`** — `maximumWriteValueLength(for:)` of the connection; without response it is the ATT MTU minus 3.
- **`subscribe(characteristicUUID:)`** — enables notifications via `setNotifyValue(true)`, waits for the state-change callback to confirm, then returns `AsyncThrowingStream<Data, Error>`. The stream throws the error that ended the connection (`connectionFailed` on a disconnect, `bluetoothUnavailable` when Bluetooth goes away), so `sub` and `nus` exit with that error's code. On stream termination, disables notifications and removes the subscription. A confirmation wait that is cancelled (the caller's deadline, a stop) queues `setNotifyValue(false)`; the processor queues the request to enable and the one to disable under its lock, so the disable follows the enable and precedes any subscribe started after the cancellation, and a device that confirms late is not left notifying an untracked subscription. The processor settles a subscribe wait only on a state change to notifying or an error, so the acknowledgement of the disable settles no later subscribe.

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

**Requests from a remote central** are untrusted and decided by pure functions in `GATTStore`: `read(_:at:)` answers a Read or Read Blob at an offset (Invalid Offset past the end), and `apply(_:to:)` applies the array CoreBluetooth delivers for one Write Request or one Execute Write (every Prepare Write fragment with its offset). A write at offset n keeps the first n bytes and replaces the rest, so fragments assemble a long value; an offset past the current end is Invalid Offset and a value over 512 bytes (the ATT maximum) is Invalid Attribute Value Length. The array is all or nothing, answered once through its first request, as CoreBluetooth requires.

**Waiting for callbacks.** `configure` (`didAdd`) and `startAdvertising` (`didStartAdvertising`) wait through `BLEPeripheral.request`, backed by `PendingCallbacks`, which the delegate owns under its lock. CoreBluetooth answers the requests for one key in order without an identifier, so the waiters per key are a FIFO; a request cancelled after it was issued stays in it as abandoned, so its late callback is not taken for a later request's. Each wait ends exactly once: with the callback, with `CancellationError` when the calling task is cancelled (`waitInterruptible` cancels it on timeout and Ctrl-C), or with the Bluetooth state error. A cancelled wait queues its undo on `blew.pm` after the request (`stopAdvertising`, `removeAllServices`), and an abandoned advertising start that still succeeds is stopped when no later start is in flight. State a request changes (`isAdvertising`, the registered services) is set on `blew.pm` in the same order, so a cancellation always wins over a success that arrives around it.

**Notifications.** `updateValue` runs on `blew.pm` (`pmQueue.sync`). When `CBPeripheralManager.updateValue` reports its transmit queue full, the notification waits in the delegate's `NotificationQueue` (at most 64) and is sent in order from `peripheralManagerIsReady(toUpdateSubscribers:)`; later notifications queue behind it. One that finds the queue full is an error to the caller and leaves the value unchanged; nothing is dropped silently.

**Leaving poweredOn.** CoreBluetooth stops advertising, invalidates the services and drops the centrals when the state drops below poweredOn. `BLEPeripheralDelegate.bluetoothStateChanged` then fails every pending wait with `BLEError.unavailable(state)`, empties the notification queue and the subscribers, and clears `BLEPeripheral`'s advertising and service state before it emits `stateChanged`. A one-shot `periph adv` ends on that event with exit code 3; it also checks, after subscribing to events, that advertising was not already lost.

**New files:**

| File | Role |
|------|------|
| `BLEPeripheral.swift` | Public singleton facade. Owns `CBPeripheralManager`, `GATTStore`, delegate. API: `configure`, `startAdvertising`, `stopAdvertising`, `updateValue`, `events()`, `peripheralStatus()`, `bluetoothState()`. |
| `BLEPeripheralDelegate.swift` | `CBPeripheralManagerDelegate`. Answers read/write requests synchronously via `GATTStore`. Owns the pending callbacks and the notification queue. Emits `PeripheralEvent` to stream. |
| `GATTStore.swift` | Thread-safe value map + subscriber map, and the pure ATT read/write decisions. Accessed from `blew.pm` queue (delegate) and any thread (CLI commands). Guarded by `NSLock`. |
| `PendingCallbacks.swift` | Pure FIFO of waiters per CoreBluetooth request key, with cancellation. |
| `NotificationQueue.swift` | Pure bounded FIFO of notifications waiting for the transmit queue; `ValueUpdate`, what `updateValue` did. |
| `PeripheralTypes.swift` | `ServiceDefinition`, `CharacteristicDefinition`, `CharacteristicProperty`, `PeripheralStatus` — all `Sendable` value types. Decoding a `CharacteristicDefinition` rejects descriptors (see below). |
| `BLEUUID.swift` | `BLEUUID`, the validated UUID every peripheral definition, table key and API argument uses. |
| `PeripheralEvent.swift` | `PeripheralEvent` enum: `stateChanged`, `advertisingStarted`, `serviceAdded`, `centralConnected`, `centralDisconnected`, `readRequest`, `writeRequest`, `subscribed`, `unsubscribed`, `notificationSent`. |

**UUIDs on the peripheral side.** `CBUUID(string:)` raises an Objective-C exception on malformed text and silently rewrites some text it accepts (`0x180F`, ` 180F`). Every UUID that reaches the peripheral from a config file, a command-line argument or an MCP argument is therefore parsed once into a `BLEUUID` (`init(parsing:)` or `Decodable`), which accepts exactly 4 or 8 ASCII hex digits or the 8-4-4-4-12 form; only BLEManager turns a `BLEUUID` into a `CBUUID`. `BLEUUID` keeps the spelling as written (uppercased), because CoreBluetooth registers a service in the form it is given, and compares and hashes by its shortest spelling, as `CBUUID` equality does. `GATTStore`, the registered-characteristic table and the pending service registrations are keyed by `BLEUUID`, and the delegate converts each callback's `CBUUID` the same way, so `180F`, `0000180F` and `0000180F-0000-1000-8000-00805F9B34FB` find one entry whichever spelling the config used and CoreBluetooth reports. Because these tables key by UUID alone, a config that names one characteristic UUID twice, in any spelling, is rejected when it is loaded.

**Descriptors.** CoreBluetooth creates 2900 and 2902 itself from the characteristic's properties, hosts no other descriptor except 2901 and 2904, and raises for those two without a value. The config format carries no descriptor values, so a config that lists any descriptor is rejected when it is loaded.

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

A `Sendable` enum that maps each failure kind to both a human-readable description (it is a `LocalizedError`, so `localizedDescription` gives the message also when it is seen as any `Error`) and an exit code integer (`exitCode`). `BLEError.unavailable(_:)` names a CoreBluetooth state that is not poweredOn; `persistentlyUnavailable(_:)` returns that error only for the states waiting does not end (powered off, unauthorized, unsupported), so both `waitForPoweredOn` loops fail at once on them and wait out only unknown and resetting.

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

Before any mode exits, `cleanupBeforeExit()` stops advertising and performs a best-effort disconnect (waits up to 2 seconds for the disconnect to complete).

`Blew.main()` sets standard output to line buffering when it is not a terminal, so piped and redirected output reaches its reader one line at a time, and calls `ProcessSignals.shared.install()` before parsing, so every mode handles signals the same way.

**Signals** (`ProcessSignals.swift`). SIGINT and SIGTERM are set to `SIG_IGN` and delivered through `DispatchSource` signal sources on the `blew.signals` serial queue, so their handling is ordinary code on that queue, never code inside a C signal handler. `ProcessSignals` counts open command spans under a lock. `Blew.main()` opens one span around every one-shot CLI command and `exec` script (the root REPL command and `blew mcp` conform to `OpensOwnCommandSpans` and open their own); a piped REPL script is one span; an interactive REPL command is a span from Enter to the next prompt; each MCP tool call is a span; and each `CommandRouter.waitInterruptible` is a span within these. So a Ctrl-C while a command renders a result or runs between two waits only stops the command, and a Ctrl-C that one wait misses stops the command's next step. Spans nest (a REPL command and its waits). MCP tool calls run one at a time (see 4.12), so at most one call has a span open. The phase is `idle` (no span open), `running`, or `interrupting` (a SIGINT asked the open spans to stop; the flag stays set until the outermost span closes, so an interrupted REPL command stops at its next wait). The decision is the pure `SignalPolicy.respond(to:in:)`:

| Signal | Phase | Response |
|--------|-------|----------|
| SIGINT | `running` | phase becomes `interrupting`; `waitInterruptible` cancels the command's task and returns `.interrupted`; the command returns exit code 130 |
| SIGINT | `idle` or `interrupting` | exit 130 |
| SIGTERM | any | exit 143 |

An interrupted command finishes the ordinary way: a CLI subcommand renders what it gathered (the final `scan -w` table, "Stopped advertising.") and exits 130, the REPL returns to the prompt, and `exec` stops the script even with `--keep-going`. An exit on a signal runs on the signal queue while the main thread may be blocked: it calls `LineNoise.restoreTerminalForExit()`, whose lock stays held so the REPL cannot enter raw mode again, then the exit hook (the REPL's history save; `History` locks its state, so the save may run beside the line editor), then `cleanupBeforeExit()` (which runs once per process, whichever thread exits first), flushes standard output unless another thread holds it (a write blocked on a full pipe must not keep blew from exiting), and calls `_exit(code)`.

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

`DeviceTargetingOptions.toArgs()` serializes non-nil values into a flat string array passed to `CommandRouter.run*()` methods, which read it with their `CommandSyntax`; `target()` reads it into a `DeviceTarget` for `nus`, which takes typed options.

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
nus     [-n/-S/-i/-m/-p] [-s <text>... | --file <path> | --pty | -l <port> [--bind <addr>]]
        [-e <text>] [-d <sec>] [--reconnect] [-r|-w]
periph
  adv   [-n <name>] [-S <uuid>...] [-c/--config <file>]
  clone [-n/-S/-i/-m/-p] [-o/--save <file>]
```

`ExecCommand` replaces the old `--exec` global flag. It calls `CommandRouter.executeScript(_:keepGoing:dryRun:)` directly.

`PeriphCommand` is a normal subcommand container with two CLI-exposed nested subcommands: `AdvCommand` and `CloneCommand`. `AdvCommand` owns `-n`/`--name`, `-S`/`--service`, and `-c`/`--config`; `CloneCommand` uses `@OptionGroup var targeting: DeviceTargetingOptions` plus `--save`. Both serialize their parsed values into a string array and forward to `CommandRouter.runPeriphAdv()` / `runPeriphClone()`. The REPL-only periph commands (`stop`, `set`, `notify`, `status`) exist only in `CommandRouter.runPeriph()` and are not exposed as ArgumentParser subcommands.

`periph adv` and `periph clone` each run in two phases:

1. **Startup phase** (always blocking): configure the GATT server and call `startAdvertising`. Waits synchronously to confirm the peripheral came up successfully.
2. **Event-loop phase**: stream read/write/subscription events to stdout.

In CLI mode (ArgumentParser subcommand), phase 2 first renders the startup result (the summary of what is advertised), then blocks until Ctrl-C, which stops advertising and returns exit code 130 with "Stopped advertising.". `streamPeripheralEvents` implements phase 2 for both `periph adv` and `periph clone`. In REPL and `exec` mode (`isInteractiveMode == true`), phase 2 runs as a stored background `Task` and the prompt (or script) continues immediately. `periph stop` cancels that task and stops advertising.

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

Background subscriptions are kept in `BackgroundSubscriptions` (`CommandRouter.backgroundSubscriptions`), a lock-protected table of one task per characteristic. Starting a new `-b` sub on an already-subscribed UUID cancels and replaces the previous task. A task removes its entry when it ends by itself (count or duration reached, an error such as a disconnect), but only its own entry, identified by a token: a replaced task that ends later leaves its replacement listed. `sub stop` and `sub status` read the same table, so they see every running subscription and none that ended. The tasks end off the main thread, hence the lock. Each task is its own notification subscriber in the processor, so a foreground `sub` of the same characteristic does not turn notifications off under a background one. Replacing a background subscription cancels the old task before the new one subscribes: when it was the only subscriber, notifications are turned off and on again, and values the device sends in between are not shown.

### 4.3a `nus` — Nordic UART Service bridge

`nus` moves bytes between a local endpoint and a device's Nordic UART Service (RX `6E400002-…` written by blew, TX `6E400003-…` notified by the device). Bytes pass unchanged. Its files, under `Sources/blew/NUS/`:

| File | Role |
|------|------|
| `NUSBridge.swift` | CoreBluetooth-free core: the NUS UUIDs, `NUS.unescape` (printf-style escapes of `--send`/`--expect`), `NUSExpect` (finds the expected bytes across notification boundaries, keeping only `pattern.count - 1` bytes of history) and `NUSSession`. |
| `NUSPort.swift` | The local endpoint: fixed bytes (`--send`, `--file`), standard input, a raw-mode pseudo-terminal (`openpty`), or a TCP listener bridging one client at a time. Also `NUSInputBuffer` (the bounded input queue) and `NUSDropTally` (counts bytes from the device the local end did not take). |
| `CommandRouter+NUS.swift` | Option parsing (`parseNUSOptions`), the default NUS service filter, and `runNUS`, the connect/session/reconnect loop. |

**Session.** `NUSSession.run()` races two child tasks: the downlink delivers each TX notification and feeds `NUSExpect`; the uplink takes the next piece of local input from the port's `NUSInputBuffer` (at most `maximumWriteLength(withResponse: false)` bytes, so the device never needs a long write, and never more than one read from the source), writes it under the operation timeout (`-t`, default 5 s), and consumes it from the buffer only after the write completed. Awaiting each write gives flow control. The first to finish decides the `NUSOutcome`: `matched`, `inputEnded` (input ended, every byte was written, and `linger` seconds passed), `expectMissed`, or `linkLost` (the TX stream finished because the device disconnected, or a write failed or timed out). `linkLost` carries `linkDown`, true when the error itself shows the connection is gone (`connectionFailed`, `notConnected`, `bluetoothUnavailable`). It is tested with in-memory streams.

**Ports outlive connections; input belongs to the port.** A port reads on one background thread for its whole life (started by the first session) into its `NUSInputBuffer`, and every session sends from that same buffer. A pty or TCP listener therefore stays open across `--reconnect`, and input a session did not write (read while no session ran, or left when the link was lost) is written by the next session. The piece whose write was under way when the link was lost is written again, so the device may receive up to one piece twice; without response, CoreBluetooth confirms no delivery, so pieces it accepted just before the link was lost may never arrive. `next` hands out an `NUSInputPiece` and `consume` takes it back; when a TCP client disconnects the port `discard`s what it sent and did not get written, so it never reaches the device on behalf of the next client, and a piece taken before the discard consumes nothing. `unsentCount` (the buffer plus what a fixed source has not read yet) is a lower bound for stream sources. The buffer is bounded (`NUSPort.inputCapacity`, 64 KiB, plus at most one 4 KiB read): while it is full the reader does not read, so a pipe or file waits and a pty or TCP client's writes wait in its kernel buffer. The pty port keeps its own slave descriptor open, so a terminal program may close and reopen the path.

**Bytes to the local end are dropped, counted and reported.** Notifications have no flow control, so blew cannot slow the device down. Writes to a pty or TCP client are non-blocking and drop what the kernel buffer does not take (all of it while no TCP client is connected), so a stalled local reader never stalls the BLE side. `NUSDropTally` counts the dropped bytes; the first loss after a complete delivery emits a `dropped` status event, and when the bridge ends a last `dropped` event gives the total. Standard output is a blocking write and drops nothing.

**Loop.** `runNUS` builds the port, then repeats: `ensureConnected` (with `NUSOptions.deviceFilter`, the NUS service, as the filter to scan with when the user gave no device option), check that RX and TX exist, run one session through the usual Task, semaphore and `waitInterruptible` bridge. `matched`/`inputEnded` exit 0, `expectMissed` exits 4, `linkLost` exits with its error's code (5, 3 when Bluetooth is unavailable, 4 for a write timeout) and the number of input bytes not sent, unless `--reconnect` and the connection is gone, which reconnects (retrying each second) with the same port. The connection is gone when `linkDown` says so or the connection state says so; a write error can arrive before the disconnect that caused it, so under `--reconnect` a `linkLost` without `linkDown` polls the connection state for `NUSOptions.linkSettleTime` (1 s, interruptible) before deciding (`NUSOptions.linkStaysUp`). Output goes through `emit`: `.nusData` (received bytes; the text renderer writes them raw to stdout, KV prints `ts=… rx=<hex>`) and `.nusStatus` (bridge events; stderr in text mode). In interactive mode (REPL, `exec`, MCP) standard input is not bridged; with no `--send`/`--file` the session only listens.

### 4.4 Implicit auto-connect

`gatt`, `read`, `write`, and `sub` call `CommandRouter.ensureConnected(to:)` with their `DeviceTarget` before executing. This means operations can be used directly from the CLI without a separate `connect` step:

```
blew gatt tree -i <uuid>
blew read -n "My Device" 2A19
```

The decisions are pure functions in `Sources/blew/DeviceSelection.swift`, tested without a radio; `ensureConnected` only runs the scans, disconnects and connects they call for:

- `DeviceTarget(_:)` reads the targeting options of a `ParsedArguments` into a `DeviceFilter` (`-i`, `-n`, `-S`, `-m`, `-R`) and an optional `PickStrategy`, rejecting a value it cannot use. Service UUIDs are compared in the form `BLENames.canonicalUUID` gives, the form `CBUUID.uuidString` has.
- `DeviceTarget.resolveIdentifier` turns a `-i` value (or MCP `device_id`) into a full identifier. It compares identifiers only, never advertised names, so a nearby device cannot capture the value by advertising it as its name: a value that parses as a UUID is exactly that identifier, seen or not; otherwise its hex digits (hyphens and case ignored) must occur in exactly one known identifier. Several matches are an `ambiguous` error listing them, none `notFound`, and a value that is not hex digits `notAnIdentifier`.
- `AutoConnectPlan.make` takes the target, the `ConnectedDevice` (its identifier and scan record), the identifiers of the last scan and a default filter (`nus` passes the NUS service). It resolves `-i` among the scanned identifiers and the connected device's, since a connected device usually stops advertising and is missing from a later scan; a value that does not resolve is the plan `unresolvedIdentifier`, and nothing is disconnected. A connected device is used when the target names no device or accepts it (`-i` compares identifiers; the selectors are matched against the scan record, and an unknown record matches nothing). Otherwise: `-i` connects directly; the selectors, or the default filter when nothing is named, scan and pick; with neither it is an error.
- `ensureConnected` calls `BLECentral.connect` (which disconnects the current device) only once the new device is known: after `-i` resolved, or after the scan ran (CoreBluetooth scans while connected) and picked. A failed lookup leaves the connection alone. When the old device is gone after `connect(to:)` returned (`BLECentral.connect` can fail before it disconnects), `ensureConnected` passes a `DeviceSwitch` to `CommandRouter.reportDeviceSwitch`, whether or not the new connect succeeded. It writes the notice to stderr at every verbosity, except inside `collectingDeviceSwitches`, which returns the switches with the body's value: the MCP server runs each call in it and returns the switches as the `deviceSwitches` field of the call's structured result. A cancelled call gets no response, so `UnreportedDeviceSwitches` keeps its switches for the next result. Commands check their own arguments (characteristic, data, format) before calling it.
- The connected device's scan record is the one `connect(to:)` saved when it connected (`connectedAdvertisement`), else its entry in `lastScanResults`, so a later scan that no longer sees the device (a connected device usually stops advertising) does not make it unknown.
- `PickStrategy.choose` picks from candidates in first-seen order: `strongest` the highest RSSI (the earlier seen on a tie), `first` the first seen, `only` the single candidate or an error listing all of them.

`runConnect` goes through the same plan, with a positional device treated as `-i` and `reconnect: true`: a named device is connected afresh even when it is the connected one (by its identifier, without a scan, since a connected device usually stops advertising), as `BLECentral.connect` documents; `connect` with no device named keeps the connected device.

### 4.5 CommandRouter

The central command dispatcher. It is the shared implementation used by all three entry paths (ArgumentParser subcommands, `exec`, and REPL).

**`dispatch(_:)`** — tokenizes a single command-line string (with basic single/double-quote handling) and routes to the appropriate `run*()` method. Returns a `CommandResult`. After each `run*()` call, `dispatch()` renders the result via its `renderer` (which writes output to stdout/stderr). This means REPL callers get automatic rendering, while CLI subcommands render explicitly.

**`executeScript(_:keepGoing:dryRun:)`** — splits the script string on `;` outside quotes (`splitScript`, by the quoting rule `tokenize` uses: `CommandRouter.quoteCharacters`, a quote runs to the next of the same character), strips whitespace and empty segments, calls `dispatch` on each. Returns `Int32` exit code. With `dryRun: true`, prints numbered steps instead. With `keepGoing: true`, records first error but continues.

**`run*()` methods** — each is a synchronous function that returns a `CommandResult` containing structured output. The method:
1. Parses its args once, at the top, with its `CommandSyntax` (see **Option parsing** below), then reads typed values from the `ParsedArguments`: `DeviceTarget(_:)` for the targeting options, `valueFormat`, `notificationCount`. Every option value is checked here, before auto-connect. A failure to start is a `CommandResult(failing:)` of the thrown error, which takes the message from `localizedDescription` and the exit code from the error's type (`BlewExitCode(for:)`); a message built from values is thrown as an `InvalidArgument`, and `invalidArguments(_:)` takes only a literal (`StaticString`), so no caught error is turned into exit 6 by its text. A failure of the operation is recorded with `CommandResult.fail(_:)`, by the same mapping.
2. Builds an async operation closure calling the appropriate `BLECentral.shared` async method, which appends structured `CommandOutput` items to the result (instead of printing directly)
3. Hands the operation to `waitInterruptible`, which starts it in a `Task` and blocks on a `DispatchSemaphore` until it finishes, is stopped or times out. A stop already requested when `waitInterruptible` is called keeps the operation from starting, so no operation starts once a stop has been seen. An operation that finished before the poll saw the stop keeps its result (`.completed`), so a write known to have completed is not reported as failed. A stop seen while the operation is still running cancels it and gives `.interrupted`, even if the device already acted on it. The stop stays set until the command's outermost span closes: `main` opens one span around every one-shot command and `exec` script, and the REPL and the MCP server open one per command or tool call, so the next wait of the same command does not start its operation.
4. Returns the `CommandResult`

Commands fall into two categories:
- **Non-streaming commands** (scan, connect, disconnect, status, read, write, gatt *, periph set/notify/status/stop): produce all output before returning. Their `CommandResult` contains the full structured output.
- **Streaming commands** (foreground sub, periph adv/clone event loops): produce output incrementally during execution. These accept an `emit: @escaping @Sendable (CommandOutput) -> Void` closure and call it for each item as it arrives. Their `CommandResult` contains only the exit code and any errors. The caller decides what the emit closure does — interactive callers pass `renderer.render(_:)`, MCP callers collect items into an array.

`runSub`, `runPeriph`, `runPeriphAdv`, and `runPeriphClone` all accept an `emit` parameter with a no-op default so existing call sites without a need for streaming output require no change.

This semaphore pattern bridges Swift's structured concurrency into the synchronous world of the CLI main thread and REPL loop.

**Option parsing** — `Sources/blew/CommandOptions.swift` is the one reader of command arguments. An `OptionSpec` is an option's short and long names and its arity (flag, single value, repeated value); a `PositionalSpec` is one positional: a subcommand word, a required operand or an optional one, by the name its usage shows (`<char>`, `[<id>]`). A `CommandSyntax` is a command's name, the options it takes and its positionals in order, and every command's syntax is declared in that file (`CommandSyntax.scan`, `.read`, `.sub`, `.subForeground`, `.gattSubcommands`, `.periphAdv`, `.nus`, ...). `CommandSyntax.parse` walks the arguments once and is the only code that decides which token is an option, a value or a positional:
- `--` ends the options; every token after it is positional.
- A token that starts with `-`, is longer than `-` and is not a number is an option; `-1.5`, `-7` and a bare `-` are positionals. An option the command does not declare is an error, so nothing a command does not take is skipped silently.
- An option that takes a value takes the next token, whatever it looks like: in `sub -n -b 2A19` the name is `-b`, and nothing starts in the background. `--long=value` carries its value in the same token.
- Short flags combine (`-dr`); an option that takes a value may only end the group (`-wR -70`).
- A missing value, a value given to a flag (`--watch=1`) and a second value of a single-value option are errors.
- Fewer positionals than the command requires and more than it declares are errors whose message names the command's usage, built from its syntax (`unexpected argument '02' -- usage: write [options] <char> <data>`), so `write fff1 01 02` writes nothing and `scan Thingy` scans nothing. A command reads its positionals by index, within the count its syntax guarantees.

`ParsedArguments` answers `value(_:)`, `values(_:)` and `flag(_:)` for a declared option of the right arity and traps for any other, so asking for an option a command does not declare is a programming error a test hits, not a silent nil. `gatt` reads its arguments twice with the same reader: `CommandSyntax.gatt` (every gatt option) finds the subcommand, the first positional, so options may come before it; `gattSubcommands[sub]` then reads them with that subcommand's options and positionals, its word first, so `gatt svcs -d` and `gatt svcs x` are errors. The first read is `subcommand(in:)`, which checks options but not positionals, so the subcommand's syntax alone decides how many positionals it takes and every error names that subcommand's usage. The MCP `sub` uses `subForeground`, which has no `-b`, so no tool argument can start a background subscription. The ArgumentParser commands, `DeviceTargetingOptions.target()` and the MCP builders produce command lines for these syntaxes: free text goes either as the value of an option, which takes the next token whatever it is, or after `--` as a positional; `ble_nus` alone builds `NUSOptions` from typed fields.

**Device/UUID resolution** — partial identifiers resolve to full ones:

- Device identifiers given to `-i` resolve in `DeviceTarget.resolveIdentifier` (section 4.4).
- `resolveCharacteristic(_:)` / `resolveService(_:)`: prefix-matches against the `BLECentral`-cached UUID lists. After `connect`, all characteristic UUIDs are known, enabling short-prefix convenience like `2A` to match `2A19`.

**Scan results cache** — `lastScanResults: [DiscoveredDevice]` holds the devices the last scan matched, in the order first seen (tables sort them by RSSI for display). Used for device resolution in `connect`, for checking a connected device against a target, and for REPL tab completion. A scan collects advertisements in `ScanResults`, which merges each device's advertisements (latest RSSI, and the latest name, service list and manufacturer data, so one missing from an advertisement keeps the earlier value) before the filter is applied. Lists are replaced, never accumulated, so a device that changes its advertisement cannot grow its record. Filtering is done on these records, not by CoreBluetooth (`scanForPeripherals(withServices: nil)`), so `-n`, `-m` and `-R` combine with `-S` in one place.

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

- **TextRenderer** (`Sources/blew/Output/TextRenderer.swift`): produces human-readable text output with aligned tables, GATT tree drawing, ANSI bold/dim when stdout is a TTY. Every line it prints is a `TextLine` (below), written through `OutputFormatter.write`.
- **KVRenderer** (`Sources/blew/Output/KVRenderer.swift`): produces machine-readable `key=value` lines.
- **NullRenderer** (`Sources/blew/Output/NullRenderer.swift`): discards all output. Used by the MCP server to prevent any command output from reaching the JSON-RPC stdout transport.

**OutputFormatter** (`Sources/blew/Output/OutputFormatter.swift`)

The renderers' writer for one output format. Provides:
- `write(_:)` — writes a `TextLine`, with its styles as ANSI codes only in text mode on a TTY
- `printTable(headers:rows:)` / `printRecord(_:)` — a table or record: through `TextTable` and `TextLine` in text mode, as kv records in kv mode
- `printError` / `printInfo` / `printDebug` — the stderr lines, through `StandardErrorLog`

**Lines and tables** (`Sources/blew/Output/TextLine.swift`)

A `TextLine` is a sequence of runs, each plain, bold or dim. Every run's text is escaped with `TerminalText.escape` when it is added, and no method adds text any other way, so the only bytes of a rendered line that are not escaped text are the ANSI codes of its styles. `TextTable.lines` is the one table layout: columns padded to their widest cell in terminal columns, two spaces apart, an optional bold header and dim rule, an optional unpadded trailing column (a characteristic's value, a field's size and condition) and continuation lines under a row indented to that column (the fields of a multi-field value). The characteristics table, the `gatt info` field list and every `printTable` table use it.

**Streams** (`Sources/blew/Output/StandardStreams.swift`)

`StandardOutput` and `StandardErrorLog` are the only code in `Sources/blew` that writes to stdout or stderr: a `TextLine`, kv records, an escaped stderr message (`write(lines:)` for one of several lines, such as ArgumentParser's usage error), a redraw of a live display, or raw `nus` bytes (`StandardOutput.writeRaw`). The help listing, `exec --dry-run` and the REPL's banner write `TextLine`s. The scan spinner and the `scan -w` table redraw themselves with `StandardErrorLog.redraw` and `erase`: escaped `TextLine`s after a `TerminalControl` sequence (erase line; cursor up and erase to end of screen), a closed enum that carries no text. `StandardOutput` also owns stdout's buffering: line buffering when it is not a terminal, the flush before LineNoise writes its prompt, and the flush that skips a locked stdout before a signalled exit. `OutputSourceTests` reads every file of `Sources/blew` and fails on any direct stream use outside `StandardStreams.swift`, since access control cannot keep a file from calling `print`. Three writers sit outside `Sources/blew`'s own code and do not pass through `StandardStreams`: the MCP SDK's stdio transport (JSON-RPC on stdout, so nothing else may write stdout in MCP mode), ArgumentParser's help and version output, and LineNoise's prompt and echo. None of them carries device text.

**Escaping and display width** (`Sources/blew/Output/TextEscaping.swift`)

Text from devices, config files, MCP clients and arguments is untrusted, so each output format has one function that every such string passes through on its way out, applied by the renderers rather than by the commands that produce the text:

- `TerminalText.escape` — text output and every stderr line: `StandardErrorLog.write` (error, info, debug and `nus` status lines, through `OutputFormatter.printError`/`printInfo`/`printDebug`) and `StandardErrorLog.writeLive` (`renderLive`). It escapes the characters of `TextEscaping.isEscaped`: C0 and C1 controls, DEL, U+2028/U+2029 and Unicode format characters (category Cf) other than ZWJ and ZWNJ.
- `KVText.value` / `KVText.record` — kv values: bare, or double-quoted with `\` and `"` escaped as well. Keys are `KVKey`s and table headers `ColumnHeader`s, both made only from string literals, so no device text becomes a key and keys are not escaped. README's "Key-value output" is the specification. A multi-field characteristic value is one `value=`, flattened by `LabeledValue.flattened`.

Both write escapes in one syntax (`\n`, `\r`, `\t`, `\xHH`, `\uHHHH`, `\UHHHHHHHH`). A `TextLine` adds ANSI bold and dim around escaped runs, never inside them. `nusData` in text mode is the one raw path: the bytes a UART delivers, written unchanged because the user asked for a byte stream.

`TerminalText.width` gives a string's width in terminal columns (East Asian wide and fullwidth characters and emoji 2, combining marks and format characters 0), and `TerminalText.pad` pads to a width without truncating; all table code measures and pads with them. The wide ranges are a merged copy of the W and F blocks of Unicode's EastAsianWidth.txt; emoji come from the standard library's `isEmojiPresentation`.

The `isTTY` flag is detected at init time via `StandardOutput.isTerminal`. ANSI escapes are only applied in text mode with a TTY, so piped output is never polluted.

### 4.7 DataFormatter

A static enum with `format(_:as:)` and `parse(_:as:)` methods taking a `ValueFormat`: `hex`, `utf8`, `base64`, `uint8`, `uint16le`, `uint32le`, `float32le`, `raw`. Shared by `read`, `write`, `sub`, `periph set|notify` and the peripheral config. `ValueFormat(parsing:)` is the one place a format name is read (any letter case); an unknown name throws, so no caller can fall back to hex. The ArgumentParser subcommands take `-f` as a `ValueFormat` (`ExpressibleByArgument`), and the REPL completes its names from `allCases`.

The `hex` and `raw` formats both produce hex output but differ: `hex` is a compact lowercase string (`deadbeef`); `raw` is space-separated bytes (`de ad be ef`). Both `raw` and `hex` inputs strip spaces before parsing.

### 4.8 REPL

`REPL` wraps `LineNoise` (from the `LineNoise` target) and `CommandRouter`.

- History file: `~/.config/blew/history`, for interactive input only: loaded on init, saved whenever `run()` returns or throws
- Prompt: `blew> `
- `Ctrl-C` during REPL: prints `^C` and continues (does not exit). At the prompt the terminal is in raw mode, so Ctrl-C is a key LineNoise reads; while a command runs it is a SIGINT that stops the command (see 4.1)
- A signal that ends the process (SIGTERM, or a SIGINT outside a command) saves the history through the `ProcessSignals` exit hook and restores the terminal
- `EOF` or `quit`/`exit`: saves history and returns
- Input that is not a terminal is a script: `LineNoise` reads it one line at a time without a prompt or editing; the REPL prints no banner, neither loads nor saves the history file, and throws the exit code of the first failing command, as `exec` does. A line that is not valid UTF-8 is an invalid argument (6) in a script and is skipped with an error at a terminal. A read or write error on the terminal or standard input exits 5.
- `LineNoise` decodes typed UTF-8 (`UTF8Input`) and edits the line as grapheme clusters (`EditState`: a `[Character]` and an integer cursor).

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
  - `type`: a `FieldType` case — `uint8/16/24/32/48/64`, `sint8/16/32`, `boolean8/16/24/32`, `medfloat16/32`, `utf8s`, or `opaque`
  - `size`: byte count when present; `-1` = variable; `-2` = variable-length array
  - `scale: Scale?`, `unit: Unit?` and `specialValues: [UInt64: String]`: the GSS "Represented values" of an integer field (the value is raw * `multiplier` * 10^`decimalExponent` * 2^`binaryExponent`), the unit of a numeric field's value (its `org.bluetooth.unit` identifier and its name from `assigned_numbers/uuids/units.yaml`; an identifier not in that file is no unit), and the raw values of an integer field the GSS gives a meaning ("A value of 0x8000 represents \"value is not known\""). An integer field gets a unit only with a scale, since without one the GSS gives the raw-to-value mapping in prose if at all. A float field gets no scale, as it carries its own exponent; where the GSS gives it one (kPa as pascal with d = 3), it gets no unit either. A field that names two units (chosen by a flag) gets none.
  - `conditions: [Condition]`: when the field is present; all must hold, and an empty list means always. A condition reads an earlier integer field by name: `.bit(field:bit:set:)` (a bit of a Flags field), `.equals(field:value:)` and `.notEquals(field:value:)` (a selector field). `.external(text)` is a condition outside the value, such as a bit of another characteristic or the service's choice; nothing in the value decides it, so it is allowed only on the last field, which is decoded when bytes remain for it.

The generator parses each field's "Present if ..." and "The presence of this field is defined by ..." sentences in the GSS YAML into conditions. It stops the build on a sentence in a phrasing it does not know, on a condition naming a field that is not an earlier integer field, on an external condition anywhere but the last field, and on a field sized "0 or N" with no condition. Every condition the GSS states is either evaluated or, for an external one, shown by `gatt info`.

In the same way it parses each field's scale line ("Represented values: M = 1, d = -2, b = 0", in the spellings the vendored GSS uses) and stops on a line that mentions M or "Represented values" in any other form, on a field with two scale lines, on a scale whose 64-bit product can overflow for its type, and on an integer field that states a scale and two units, and on a scaled unsigned field with a negative "Minimum". It parses special values the same way, stopping on a sentence that pairs a value with "represents", "indicates" or "means" in a form it does not know. `CONTRADICTED_SCALES` lists the fields whose stated scale contradicts their own description (High Voltage: b = 6 against "1/64V"); they are decoded raw, and the build stops when such a field's scale changes, so a corrected GSS removes the entry.

**Struct resolution**

Many GSS characteristics embed sub-structures defined in other characteristics (e.g., `Date Time` characteristic embedded inside `Day Date Time`). The code generator (`Scripts/generate-ble-characteristics.rb`) resolves these recursively at build time by following `\autoref{sec:org.bluetooth.characteristic.XXX}` annotations in each `struct`-typed field's description. Circular references and missing references fall back to `.opaque` fields with a build-time warning.

**Decoding** (`GATTDecoder.decode(_:uuid:)`)

Reads fields sequentially from the `Data` buffer:
1. Each decoded unsigned-integer or `boolean[N]` field is kept by name as an unsigned value.
2. A conditional field is included only when all its conditions hold on those values; a condition on a field that was not decoded does not hold.
3. Variable-length fields consume all remaining bytes.
4. An integer field with a scale is printed with the decimal places its resolution supports, max(0, -d) plus ceil(k * log10 2) for b = -k, none more for b >= 0 (2A6E `2340` is `23.40`, a b = -1 field `201` is `100.5`, a b = -16 field `0x8000` is `0.50000`); a value with more places is rounded half away from zero. The arithmetic is integer, so no binary floating-point error reaches the output: 2^-k is 5^k * 10^-k, so raw * M * 5^k (or * 2^b for b >= 0) is a 64-bit integer n and the exact value is n * 10^(d - k); ceil(k * log10 2) is the number of digits of 2^k. A raw value in the field's `specialValues` is shown as its text instead. A number, but not "(short)" or a float's special value, is followed by the unit's name (`degree Celsius`, `pascal`).
5. Single-field characteristics emit just the value; multi-field characteristics emit `"FieldName: value | FieldName: value"`.

Supported types include all standard GATT integer types (`uint8` through `uint64`, `sint8`/`sint16`/`sint32`), IEEE 11073-20601 medical floats (`medfloat16`, `medfloat32`), UTF-8 strings, and hex-encoded opaque blobs.

**Info query** (`GATTDecoder.info(for:)`)

Returns a `CharacteristicInfo` struct for use by `gatt info`, containing the name, description, and a `FieldInfo` array with human-readable type and size descriptions. Each `FieldInfo` keeps the field's `conditions`, the same values the decoder evaluates, and derives both of its condition outputs from them: `conditionDescription` ("present if bit 3 of Flags is 1 and bit 4 of Flags is 1", shown by the text and kv renderers) and, in JSON (MCP `structuredContent`), a `condition` object, which `GATTCharacteristicDB.Condition`'s `Codable` conformance writes with one `kind` per case (`allOf` wraps several). An unconditional field has neither. It also keeps the decoder's `scale` and `unit`, encoded as a `scale` object and a `unit` identifier when present. README.md's `gatt info` section is the schema.

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

`BlewExitCode` is a thin `Error` wrapper around `Int32`. It implements `CustomNSError` so ArgumentParser can extract and propagate the exit code correctly. `BlewExitCode(for:)` is the one mapping from an error to its code: a `BlewExitCode` as it is, a `BLEError` by its `exitCode`, an `InvalidArgument` 6, anything else 5. `Blew.main` exits quietly with a thrown `BlewExitCode`; for any other error `Blew.processExitCode(for:)` gives 0 for `--help` and `--version`, 6 for ArgumentParser's usage and validation errors (which ArgumentParser itself would exit with 64), and `BlewExitCode(for:)` otherwise, after printing ArgumentParser's message.

```
0   success
2   not found / no match
3   Bluetooth unavailable or permission denied
4   timeout
5   operation failed (connect / GATT / read / write / subscribe)
6   invalid arguments
130 interrupted by SIGINT (Ctrl-C)
143 terminated by SIGTERM
```

### 4.12 MCP Server Mode

`blew mcp` starts an MCP (Model Context Protocol) server over stdio, allowing AI agents (Cursor, Claude Desktop, etc.) to discover and invoke BLE operations as structured tool calls.

**Conditional compilation:**

The MCP swift-sdk dependency declares `swift-tools-version:6.1` and uses concurrency APIs (the parameterless `withThrowingTaskGroup` overload) introduced in Swift 6.1, so it cannot be built with Swift 6.0.x (Xcode 16.0–16.2). To keep blew buildable on those toolchains, MCP support is gated behind compiler-version detection:

- `Package.swift` uses `#if compiler(>=6.1)` to decide whether to add the swift-sdk package dependency, the `MCP` product dependency (on both the `blew` and `blewTests` targets), and the `MCP_ENABLED` swift define. The package's own `swift-tools-version` stays at `6.0` so the manifest itself loads under the older toolchain.
- All MCP source is wrapped in `#if MCP_ENABLED`: the files in `Sources/blew/MCP/`, `MCPCommand.swift`, `MCPTests.swift` and `MCPCallTests.swift` compile to nothing when the flag is absent. `Blew.subcommandList` appends `MCPCommand.self` only under `#if MCP_ENABLED`, so the `mcp` subcommand simply does not exist on a Swift 6.0 build.

When built with Swift 6.1+ everything below applies; on Swift 6.0.x the `mcp` subcommand is absent and every other command is unchanged.

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
| `Sources/blew/MCP/ToolArguments.swift` | Checks a call's arguments against the tool's input schema |
| `Sources/blew/MCP/ToolCallQueue.swift` | Runs tool calls one at a time on a dedicated serial queue, with cancellation and a time budget |
| `Sources/blew/StopRequest.swift` | A caller's request to stop one command (cancelled, or out of budget), which `waitInterruptible` honours like SIGINT |
| `Sources/blew/Output/NullRenderer.swift` | `OutputRenderer` that discards all output (prevents any command output from reaching the JSON-RPC stdout) |

**Tool dispatch:**

The MCP server calls `CommandRouter.run*()` methods directly (not through `dispatch()`) to avoid automatic rendering to stdout. Non-streaming commands return their full output in `CommandResult.output`. For streaming commands (`sub`, `nus`, `periph adv/clone`), the server passes a collecting closure as the `emit` parameter: items are accumulated in a per-call `StreamCollector` (under a lock), which is closed when the command returns and its items prepended to `CommandResult.output` before JSON encoding. Closing matters for `periph adv`, whose background task keeps emitting events after the call has returned; they are dropped instead of piling up in a collector nobody reads.

The router is built from the global options the process was started with (`GlobalOptions.current`), so `blew -t 30 mcp` and `blew -v mcp` apply to every call.

**A call's path.** `handleToolCall` handles one `tools/call` request in four steps:

1. *Validate.* `ToolArguments.validate` checks the arguments against the tool's `inputSchema`, the one description of what each tool accepts: every argument is a declared property of the declared JSON type, inside its `enum`, `minimum` and `maximum` (array items against `items`), and every `required` property is present. A mismatch is an error result with exit code 6; no argument is ignored or coerced. The argument builders run after validation, so they read only values of the declared types.
2. *Build.* `makeCommand` turns the arguments into a `ToolCommand`: the router work, and the duration the call itself asks for (the `ble_scan` `timeout`, the `ble_subscribe` or `ble_nus` `duration`, zero otherwise). `ble_subscribe` always passes `-d`: the call's `duration`, or `defaultSubscribeDuration` (10 s); `count` is optional and ends it earlier. It calls `runSub(foregroundOnly: true)`, so no argument text (a `name` of `-b`) can start a background subscription that outlives the call and mutates router state off the queue. Errors in the `ble_nus` options are argument errors too and return before the call is queued. The schemas cap these durations at `maxCallDuration` (300 s).
3. *Queue.* `ToolCallQueue.run` executes the work on its own serial `DispatchQueue` (`blew.mcp.calls`), so calls never overlap: each starts after the one before it returned. Requests a client pipelines without waiting for replies reach the queue in either order, because the swift-sdk's per-request Tasks race until they enqueue; the server's instructions tell clients to send a dependent call after the reply. The swift-sdk handles each request in its own Task; without the queue, concurrent calls would share the single-slot operation waits of `BLEEventProcessor`, the router's state (`lastScanResults`, `backgroundSubscriptions`) and the connection, and one call's auto-connect could replace the device another call is using. The router's commands block their thread on semaphores, so the queue's thread, not a thread of the cooperative pool, is the one that blocks; the request's Task suspends on a continuation until the work returns.
4. *Stop.* Each call has a `StopRequest`, attached to the router with `run(stoppingOn:)` for the call's duration; `run(stoppingOn:)` also makes the whole call one `ProcessSignals` span. `waitInterruptible` treats a set request like a SIGINT: it cancels the waiting operation and returns `.interrupted`. The request is set to `.cancelled` when the swift-sdk cancels the request's Task (it does on `notifications/cancelled`), and to `.budgetExhausted` when the call's budget runs out (a cancellation replaces an exhausted budget, never the reverse): its duration plus `setupAllowance` (60 s), or plus four times `-t` when that is longer, counted from when the call starts. A cancelled call throws `CancellationError`, so the swift-sdk sends no response; a cancelled call still waiting its turn never starts. A call whose budget ran out and that did not succeed fails with exit code 4 and keeps the output it collected.

**SIGINT in MCP mode.** `ProcessSignals` keeps one process-wide interrupt flag. With calls serialized and each call one span, a SIGINT while a call runs stops exactly that call, at its next wait if it is between two, which returns exit code 130 to its client; the server keeps serving. A SIGINT with no call running ends the server with 130, as in every other mode, and SIGTERM ends it with 143.

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
| `ble_nus` | `nus --send` | targeting options, send?, expect?, duration?, with_response? |

**Subscribe behavior:** `ble_subscribe` collects notifications for `duration` seconds (10 when not given, at most 300) or until `count` have arrived, whichever comes first. Enabling notifications waits for the device's confirmation for at most the operation timeout (`-t`, else 5 s), in the CLI as well. All values are returned at once as a `[NotificationValue]` array.

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
blew.signals            SIGINT / SIGTERM handling (ProcessSignals)
blew.mcp.calls          MCP tool calls, one at a time (ToolCallQueue);
                        blocks in DispatchSemaphore waits like the main thread
blew.mcp.budgets        Timers that stop an MCP call when its budget runs out
Swift cooperative pool  async Task bodies (BLECentral and BLEPeripheral)
```

The `blew.pm` queue is separate from `blew.cb`. Both can coexist during `periph clone` (which temporarily runs in central mode to snapshot a real device, then switches to peripheral mode).

The semaphore-based bridge, `CommandRouter.waitInterruptible`, is the key synchronisation point:

```swift
let operation: () async -> Void = {
    do { try await BLECentral.shared.someOperation() }
    catch { ... }
}
switch waitInterruptible(operation, timeout: 5) {   // Task + DispatchSemaphore inside
case .completed: ...
case .interrupted: ...   // SIGINT or StopRequest; exit 130
case .timedOut: ...      // exit 4
}
```

This lets the REPL and `--exec` runner remain purely synchronous while the BLE stack operates asynchronously. The cost is one thread blocked per in-flight BLE operation, which is acceptable given the interactive/scripting nature of the tool.

---

## 6. Module dependency graph

```
blew (executable)
 ├── BLEManager                        (CoreBluetooth)
 │     Central: BLECentral, BLEDelegate, BLEEventQueue, BLEEventProcessor
 │     Peripheral: BLEPeripheral, BLEPeripheralDelegate, GATTStore
 │     Shared: BLEError, PeripheralTypes, PeripheralEvent, DeviceInfo
 ├── LineNoise                         (system libedit — linenoise Swift implementation)
 ├── ArgumentParser                    (swift-argument-parser)
 ├── MCP                               (modelcontextprotocol/swift-sdk; only when compiler >= 6.1)
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

### Event queue that drops only scan results

The queue is a FIFO under one lock. A fixed-size lock-free ring has to drop or block when full: dropping a `didConnect` or a GATT answer hangs its wait, and blocking stalls blew.cb. An uncontended lock per event costs nothing measurable at Bluetooth LE event rates, and lets the queue keep every event but scan results, which it drops past 1024 waiting (section 3.3).

### Semaphore-based async bridge

The REPL loop and `--exec` runner are inherently synchronous. Using `DispatchSemaphore` to wait for each `Task` is intentional — it avoids converting the entire CLI layer to `async`, which would complicate the REPL loop and signal handling. The alternative (running a detached async main with `RunLoop.main.run()`) adds complexity without benefit for a single-user interactive tool.

### Auto GATT discovery on connect

`BLECentral.connect()` always discovers all services and characteristics immediately after connection is established. This adds ~100ms at connect time but means `read`, `write`, `sub`, and `gatt` commands never need to trigger discovery themselves. It also populates the UUID caches that power tab completion.

### Shared CommandRouter across all entry paths

The same `CommandRouter.run*()` implementations are called from ArgumentParser subcommands, `--exec` parsing, and the REPL. This eliminates three independent implementations of the same BLE operation logic and guarantees identical behavior regardless of how a command is invoked.

### Value-type GATT model

`BLEManager` stores live `CBService` and `CBCharacteristic` objects internally (they are reference types that must be retained). However, the public API only exposes plain `Sendable` value-type structs (`ServiceInfo`, `CharacteristicInfo`, etc.), keeping the `CoreBluetooth` import boundary entirely within `BLEManager`.
