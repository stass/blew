# blew -- BLE scanner and CLI tool for Mac OS X

Stop fumbling with GUI apps to debug Bluetooth Low Energy devices. `blew` gives you full BLE control from the macOS command line: scan the airwaves, drill into any device's GATT tree, read and write characteristics, stream live notifications, and even spin up a virtual peripheral that other devices can connect to.

<img src="img/scan.avif" alt="BLE scan" width="100%">

<img src="img/gatttree.avif" alt="GATT tree" width="49%"> <img src="img/uart.avif" alt="UART" width="49%">

### Why blew

- **One tool, zero ceremony.** Scan, connect, inspect, read, write, subscribe -- each is a single command. Auto-connect means you never have to manually pair before doing real work.
- **Interactive when you want it.** Launch the REPL for an exploratory session with tab completion, persistent history, and background subscriptions that print while you keep typing.
- **Scriptable when you need it.** Chain commands with `exec`, pipe machine-readable `kv` output into `awk` or a log file, and use deterministic exit codes in CI or monitoring scripts.
- **Full GATT visibility.** Print the service/characteristic tree of any device in one shot. Read all values inline. Look up any Bluetooth SIG characteristic's field-level spec without even connecting.
- **Peripheral mode.** Turn your Mac into a virtual BLE device. Define a GATT server from a JSON config, or clone a real device's entire service tree and replay it.
- **Human-readable by default.** Standard Bluetooth SIG UUIDs are resolved to their names everywhere -- scan results, GATT trees, notifications -- sourced from the official Bluetooth SIG database.

### Modes of operation

- **Command mode** -- run a single command, then exit: `blew [global-options] <command> [command-options]`
- **Interactive REPL** -- run `blew` with no command for a readline-style shell with history and tab completion
- **Script mode** -- run a semicolon-separated sequence sharing one connection: `blew exec "connect -n Sensor; gatt tree; read -f uint8 2A19"`
- **MCP server mode** -- expose all BLE operations as MCP tools for AI agents: `blew mcp`

> Requires macOS 13+ and Bluetooth permission.

### Things you can do

**Clone a real device and impersonate it.** Walk up to a heart rate monitor, clone its full GATT tree, and your Mac starts advertising as that device. Other apps can connect to the clone as if it were the real thing:

```sh
% blew periph clone -n "Heart Rate Monitor" --save hr.json
```

**Watch the BLE airwaves live.** See every device around you with signal-strength bars, updating in real time. Filter by name, service, or signal floor to zero in on what you need in a crowded venue:

```sh
% blew scan -w -R -70
```

**X-ray a device in one shot.** Connect, discover all services, read every readable characteristic, and print the whole thing as a tree, including names, properties, descriptors and live values:

```sh
% blew gatt tree -n "Thingy" -dr
```

**Look up any Bluetooth SIG characteristic without a device.** Instantly see the field-level structure of any standard characteristic, like byte layout, types, conditional fields:

```sh
% blew gatt info 2A37    # Heart Rate Measurement spec
```

**Stream sensor data straight to a log.** Subscribe to a characteristic, format values as key-value pairs, and pipe to a file or another tool. Runs headless, exits cleanly on timeout:

```sh
% blew -o kv sub -n "Sensor" -f uint16le -d 3600 fff1 >> hourly.log
```

**Talk to a Nordic UART Service device like a serial port.** Type at it, script it with an expected reply, or hand a pseudo-terminal to `screen`, `cu` or `picocom`:

```sh
% blew nus -n "erxos"                                  # stdin to the device, its output to stdout
% blew nus -n "erxos" -s 'ping\n' -e ping && echo ok   # exit status says whether the echo came back
% blew nus -n "erxos" --pty --reconnect                # prints e.g. /dev/ttys012 for screen/cu/picocom
```

**Spin up a virtual BLE device from a JSON file.**  Define services, characteristics, properties, and initial values in a config file and start advertising in one command:

```sh
% blew periph adv --config Examples/health-thermometer.json
```

**Run a multi-step test sequence as a one-liner.** Connect, inspect, read, write, wait, read again or subscribe to notifications as a single command:

```sh
% blew exec -k "connect -n Sensor; gatt tree; write -f uint8 fff2 01; sleep 2; read -f uint16le fff1"
```

---

## Installation

### Homebrew

```bash
brew install stass/tap/blew
```

### Requirements

- macOS 13 (Ventura) or later
- Xcode 16 or later (Swift 6.0+ toolchain)

The MCP server (the `blew mcp` subcommand) depends on the MCP swift-sdk, which requires the Swift 6.1 toolchain (Xcode 16.3+). To keep blew building on older toolchains, MCP support is compiled in conditionally: when built with Swift 6.1 or newer the `mcp` subcommand is available; when built with Swift 6.0.x (Xcode 16.0–16.2) the MCP server is omitted and every other command works unchanged. No flags are needed — the detection happens automatically in `Package.swift`.

### Build from source

```bash
git clone --recurse-submodules https://github.com/stass/blew.git
cd blew
swift build -c release
cp .build/release/blew /usr/local/bin/blew
```

`--recurse-submodules` is required — the Bluetooth SIG name and characteristic databases are included as git submodules under `Vendor/`. The Swift build generates all data files automatically from the submodule data, and stops with an error naming the missing file when the submodules are not checked out. In a clone made without `--recurse-submodules`, fetch them with:

```bash
git submodule update --init
```

The build embeds `Sources/blew/Info.plist` in the executable, in its `__TEXT,__info_plist` section, so the copied binary carries it. The plist holds `NSBluetoothAlwaysUsageDescription`, the purpose string macOS's Bluetooth privacy check reads from the executable; a command-line tool has no app bundle to carry it. Check that the binary has it with:

```bash
otool -P .build/release/blew
```

On first run, macOS will prompt for Bluetooth permission. Grant it in **System Settings → Privacy & Security → Bluetooth**.

---

## Quick start

```sh
# Scan for nearby devices
% blew scan

# Print the GATT tree of a device (connects automatically)
% blew gatt tree -n "Thingy"

# Read a characteristic (battery level)
% blew read -n "Thingy" -f uint8 2A19

# Subscribe to notifications for 10 seconds
% blew sub -n "Thingy" -d 10 fff1

# Run a multi-step procedure in one invocation
% blew exec "connect -n Thingy; gatt tree; read -f uint8 2A19"

# Start the interactive REPL
% blew
```

---

## Global options

These options apply to all commands and must be placed **before** the subcommand name:

```sh
% blew [global-options] <command> [command-options]
```

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Increase log verbosity. Repeatable: `-vv` for debug-level detail. |
| `-o, --out <format>` | Output format for results: `text` (default, human-readable) or `kv` (key=value, one record per line — easier to parse). |
| `-t, --timeout <sec>` | Timeout in seconds for BLE operations. |
| `-h, --help` | Show help and exit. |
| `--version` | Show version and exit. |

## Device targeting options

Commands that connect to a device (`scan`, `connect`, `gatt`, `read`, `write`, `sub`, `nus`, `periph clone`) accept these options to identify the target. Pass them after the subcommand name.

Use `--id` to target an explicit device, or combine selectors to let blew find a match automatically. A device must pass every selector given.

| Flag | Description |
|------|-------------|
| `-i, --id <device-id>` | Target a specific device by its identifier. `connect` and auto-connect also take a fragment of the identifier (hex digits, hyphens and case ignored) that occurs in exactly one identifier of the last scan or of the connected device; a fragment that matches several is an error listing them. A full identifier (a UUID, with or without its hyphens) names exactly that device, seen or not. Names are never matched: select by name with `-n`. With `-i`, `connect` and auto-connect connect directly and ignore the other selectors. |
| `-n, --name <substring>` | Filter by advertised name (case-insensitive substring). |
| `-S, --service <uuid>` | Filter by advertised service UUID: 4 or 8 hex digits or a 128-bit UUID, so `180F` and `0000180F-0000-1000-8000-00805F9B34FB` are the same service. Repeatable; the device must advertise every one. |
| `-m, --manufacturer <id>` | Filter by manufacturer: the decimal Bluetooth SIG company identifier at the start of the advertised manufacturer data (e.g. `89` for Nordic Semiconductor, `76` for Apple). |
| `-R, --rssi-min <dBm>` | Minimum RSSI threshold (e.g. `-R -70`). |
| `-p, --pick <strategy>` | How to pick when multiple devices match: `strongest` (default, highest RSSI), `first` (the first discovered in the scan), `only` (error, exit code 2, if more than one matches). |

An invalid value (a malformed UUID, a manufacturer ID outside 0 to 65535, an unknown strategy) or a selector other than `-S` given twice is an error, and nothing is scanned or connected.

When a device is already connected (in `exec`, the REPL or the MCP server), a command other than `connect` uses it if its targeting options name no device, or if the connected device matches them: `-i` compares identifiers, and the selectors are checked against what the device advertised when blew connected to it (or in the last scan); `-p` does not apply then. Otherwise blew finds the device the options name, by identifier or by scanning, and only then disconnects the connected one and connects to it, so `exec "connect -n A; write -n B fff1 01"` writes to B. When the named device is not found, by its identifier or by the scan, the connection is left as it was; once blew starts connecting to the named device, the old connection ends even if that connect then fails. When blew has disconnected the connected device to connect to another, it says so on stderr at every verbosity, whether or not that connect succeeds: `disconnected <old-id> to connect to <new-id>`. Background subscriptions on the old device end with it.

---

## Commands

### `scan` — Scan for BLE devices

```
blew scan [-n <name>] [-S <uuid>] [-R <dBm>] [-i <id>] [-m <id>] [-p <strategy>] [-w]
```

Scans for advertising BLE peripherals and prints a table of discovered devices. Timeout defaults to 5 seconds. In the REPL and `exec`, `scan` also takes `-t <sec>` for the timeout of that scan (`scan -t 3`); on the command line it is the global `-t`. If Bluetooth is turned off or blew loses Bluetooth permission during a scan (also `scan -w` and the scan that finds a device to connect to), the scan fails with exit code 3.

**Flags:**

| Flag | Description |
|------|-------------|
| `-n, --name` | Filter results by device name substring. |
| `-S, --service` | Filter by advertised service UUID. Repeatable. |
| `-R, --rssi-min` | Minimum RSSI threshold (e.g. `-R -70`). |
| `-i, --id` | Show only the device with this identifier (the full identifier, any case). |
| `-m, --manufacturer` | Filter by manufacturer ID (decimal company identifier). |
| `-p, --pick` | Show only the device auto-connect would pick with this strategy: `strongest`, `first`, `only`. Not valid with `-w`. |
| `-w, --watch` | Continuously scan and show a live-updating device list. Runs until Ctrl-C or `-t` expires. Requires a TTY in text mode; use `-o kv` for piped output. |

**Output columns (text):** ID, Name, RSSI, Signal (visual bar), Services

`scan -w -o kv` writes a record each time a device is seen. When the reader
falls behind, the advertisements a device sent meanwhile come as one record
with the latest RSSI, so a slow pipe gets fewer updates rather than a growing
backlog.

Standard Bluetooth SIG service UUIDs in the Services column are shown with their human-readable name: e.g. `180F (Battery Service), 180A (Device Information)`.

**Examples:**
```sh
% blew scan                          # Scan for 5 seconds
% blew -t 10 scan                    # Scan for 10 seconds
% blew scan -w                       # Continuously scan until Ctrl-C
% blew -t 30 scan -w                 # Watch for 30 seconds then stop
% blew scan -n "Heart" -w            # Watch for Heart Rate devices
% blew scan -S 180D -R -65           # Heart Rate service, RSSI ≥ -65 dBm
% blew scan -m 89 -p first           # The first Nordic device discovered
% blew -o kv scan                    # Machine-readable output
% blew -o kv scan -w                 # Stream device updates (piping-friendly)
```

---

### `connect` — Connect to a device

```
blew connect [-n <name>] [-S <uuid>] [-i <id>] [<device-id>]
```

Explicitly connects to a BLE device and exits. Useful for testing connectivity or pre-warming a connection in `exec` scripts. The device can be specified by positional argument, `--id`, or device-targeting selectors (the tool will scan briefly to resolve them), but not by a positional argument and options together (exit code 6). In `exec` or the REPL, a connected device stays connected until the named device is found; with no device named, `connect` keeps it.

For `gatt`, `read`, `write`, and `sub` you do not need to run `connect` first — those commands connect automatically using the same device-targeting options.

blew holds one connection at a time: `connect` disconnects the current device first, also when it is the same one, and then connects and discovers its services afresh. `-t` (default 10 seconds) bounds the wait for the device to connect: past it `connect` fails with exit code 4. A connect that times out or is interrupted stops connecting, so the device does not connect later. A connect whose service discovery fails or is interrupted fails too and leaves nothing connected. While Bluetooth is off, or when it turns off during the connect, `connect` fails with exit code 3, as do GATT commands and `sub`.

The connection is automatically closed on exit.

**Examples:**
```sh
% blew connect F3C2A1B0-...          # Test connectivity to an explicit ID
% blew connect -n "Thingy"           # Test connectivity by name
% blew connect -S 180F               # Connect to device advertising Battery Service
```

---

### `gatt` — Inspect GATT structure

`gatt` connects automatically if no connection is active. Specify the target device with `--id`, `--name`, or other device-targeting options.

All UUID outputs include human-readable names for standard Bluetooth SIG UUIDs. Custom or vendor UUIDs are shown as-is.

#### `gatt svcs` — List services

```
blew gatt svcs [-n <name>] [-i <id>]
```

Lists all discovered services. Output columns: UUID, Name, Primary.

```
UUID   Name                  Primary
------------------------------------
180F   Battery Service       yes
180A   Device Information    yes
FFF0                         yes
```

#### `gatt tree` — Show full GATT tree

```
blew gatt tree [-n <name>] [-i <id>] [-d] [-r]
```

Prints services and their characteristics with properties (read / write / notify / indicate). Standard UUIDs show their human-readable name alongside.

```
Service 180F  Battery Service
├── 2A19  Battery Level  [read, notify]
│   └── 2902  Client Characteristic Configuration
└── FFF1  [read, write-without-response, notify]

Service FFF0
└── FFF1  [read, write-without-response, notify]
```

| Flag | Description |
|------|-------------|
| `-d, --descriptors` | Also show descriptors for each characteristic. |
| `-r, --read` | Read and display values for all readable characteristics inline. Well-known Bluetooth SIG characteristics are decoded to their natural type (e.g. battery level as an integer, manufacturer name as a string); others are shown as hex. An integer field the Bluetooth SIG GSS gives a scale ("Represented values: M, d, b") is shown scaled, with the decimal places its resolution supports, and followed by the name of its unit (Temperature `2409` is `23.40 degree Celsius`, Pressure `02760f00` is `101325.0 pascal`). A decimal exponent d = -2 gives 2 places, and a binary exponent b = -k adds ceil(k × log10 2): Percentage 8 (b = -1) `c9` is `100.5 percentage`, Chromaticity Coordinate (b = -16) `0080` is `0.50000`. A value with more places than that is rounded half away from zero (`0004` there, 0.015625, is `0.01563`); an integer field with no scale is shown raw, with no unit. A raw value the GSS gives a meaning is shown as that meaning (Temperature `0080` is `value is not known`). The unit is the one the GSS names for the field, by its name in the Bluetooth SIG assigned units; a field whose GSS names no unit, several, or one that is not an assigned unit gets none. A medical float (SFLOAT, FLOAT) is followed by its unit only when its GSS states no scale other than M = 1, d = 0, b = 0. |

With `-r`:
```
Service 180F  Battery Service
└── 2A19  Battery Level  [read, notify]  = 85

Service 180A  Device Information
├── 2A29  Manufacturer Name String  [read]  = Apple Inc.
└── 2A24  Model Number String  [read]  = MacBookPro18,3
```

#### `gatt chars` — List characteristics for a service

```
blew gatt chars [-n <name>] [-i <id>] [-r] <service-uuid>
```

Output columns: UUID, Name, Properties.

| Flag | Description |
|------|-------------|
| `-r, --read` | Read and display values for all readable characteristics. Adds a Value column to the table; non-readable characteristics get an empty cell. |

#### `gatt desc` — List descriptors for a characteristic

```
blew gatt desc [-n <name>] [-i <id>] <char-uuid>
```

Output columns: UUID, Name.

#### `gatt info` — Show Bluetooth SIG specification for a characteristic

```
blew gatt info <char-uuid>
```

Displays the Bluetooth SIG name, description, and field-level structure for any standard characteristic UUID. Does **not** require a connected device — it reads directly from the generated characteristic database.

```
$ blew gatt info 2A37
Heart Rate Measurement (2A37)

The Heart Rate Measurement characteristic is used to represent data related to a heart rate measurement.

Structure:
  Flags                                             boolean[8]  1 byte
  Heart Rate Measurement Value (8 bit resolution)   uint8       1 byte  [present if bit 0 of Flags is 0]
  Heart Rate Measurement Value (16 bit resolution)  uint16      2 bytes  [present if bit 0 of Flags is 1]
  Energy Expended                                   uint16      2 bytes  [present if bit 3 of Flags is 1]
  RR-interval                                       opaque      variable (array)  [present if bit 4 of Flags is 1]
```

Struct-typed fields (such as an embedded `Date Time`) are recursively inlined with dot-separated names:

```
$ blew gatt info 2A0A
Day Date Time (2A0A)

The Day Date Time characteristic is used to represent weekday, date, and time.

Structure:
  Date Time.Year           uint16  2 bytes
  Date Time.Month          uint8   1 byte
  Date Time.Day            uint8   1 byte
  Date Time.Hours          uint8   1 byte
  Date Time.Minutes        uint8   1 byte
  Date Time.Seconds        uint8   1 byte
  Day of Week.Day of Week  uint8   1 byte
```

With `-o kv`, one record per field is emitted (for scripting); a conditional field's record has `condition=` with the "present if ..." text.

The MCP tool `ble_gatt_info` returns the same fields as JSON in `structuredContent`, at `characteristicInfo.fields`. A conditional field has two more keys: `conditionDescription`, the "present if ..." text, and `condition`, the same condition as an object. A field that is always present has neither. A field the decoder scales has `scale`, `{"multiplier": M, "decimalExponent": d, "binaryExponent": b}` (the value is raw * M * 10^d * 2^b). A field whose decoded value is followed by a unit has `unit`, the unit's identifier (such as `org.bluetooth.unit.thermodynamic_temperature.degree_celsius`). Either can appear without the other. Part of the result for `char_uuid` `2C27` (Recipe Parameters), with `description` and most fields left out:

```json
{
  "type": "characteristicInfo",
  "characteristicInfo": {
    "uuid": "2C27",
    "name": "Recipe Parameters",
    "fields": [
      {"name": "Cooking Step Index", "typeName": "uint16", "sizeDescription": "2 bytes"},
      {"name": "Duration", "typeName": "uint16", "sizeDescription": "2 bytes",
       "condition": {"kind": "notEquals", "field": "Cooking Process Type", "value": 0},
       "conditionDescription": "present if Cooking Process Type is not 0"},
      {"name": "Temperature Gradient", "typeName": "uint8", "sizeDescription": "1 byte",
       "condition": {"kind": "allOf", "conditions": [
         {"kind": "bit", "field": "Flags", "bit": 3, "value": 1},
         {"kind": "bit", "field": "Flags", "bit": 4, "value": 1}]},
       "conditionDescription": "present if bit 3 of Flags is 1 and bit 4 of Flags is 1"}
    ]
  }
}
```

`condition` has one of these shapes. `field` names an earlier field of the same characteristic, read as a little-endian unsigned integer.

| `kind` | Other keys | The field is present when |
|---|---|---|
| `bit` | `field`, `bit`, `value` (0 or 1) | bit `bit` of `field` (bit 0 is the least significant) equals `value` |
| `equals` | `field`, `value` | `field` equals `value` |
| `notEquals` | `field`, `value` | `field` does not equal `value` |
| `external` | `description` | something outside this value says so, such as a bit of another characteristic; `description` says what. Only the last field has this kind, and blew decodes it when bytes remain for it |
| `allOf` | `conditions`: two or more of the kinds above | every condition in `conditions` holds |

**Examples:**
```sh
% blew gatt tree -n "Thingy"
% blew gatt tree -n "Thingy" -d        # Include descriptors
% blew gatt tree -n "Thingy" -r        # Read values for readable characteristics
% blew gatt tree -n "Thingy" -dr       # Descriptors + values
% blew gatt chars -n "Thingy" 180F
% blew gatt chars -n "Thingy" -r 180A  # Read values for Device Information
% blew gatt desc -n "Thingy" 2A19
```

---

### `read` — Read a characteristic value

```
blew read [-n <name>] [-i <id>] [-f <format>] <char-uuid>
```

Reads the value of a characteristic and prints it in the requested format. Connects automatically if no connection is active.

Reading a characteristic that is subscribed at the same time (`sub -b`) is ambiguous: CoreBluetooth reports read results and notifications the same way and does not say which a value is. The read then prints the first value the device sends after the read was issued, which may be a notification, and the subscription also shows the value that answers the read. A characteristic blew has not subscribed to does not normally notify, so its values are read results.

A characteristic whose properties do not include `read` is not read: `read` fails with exit code 5 and names its properties (shown by `char`).

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Output format (see table below; any other is an error, exit code 6). Default: `hex`. |

**Formats:**

| Format | Description |
|--------|-------------|
| `hex` | Hexadecimal string (default) |
| `utf8` | UTF-8 string |
| `base64` | Base64-encoded string |
| `uint8` | Unsigned 8-bit integer |
| `uint16le` | Unsigned 16-bit integer, little-endian |
| `uint32le` | Unsigned 32-bit integer, little-endian |
| `float32le` | 32-bit float, little-endian |
| `raw` | Raw bytes |

**Examples:**
```sh
% blew read -n "Thingy" -f uint8 2A19     # Battery level as integer
% blew read -n "Thingy" -f utf8 2A29      # Manufacturer name string
% blew read -n "Thingy" fff1              # Raw characteristic as hex
```

---

### `write` — Write to a characteristic

```
blew write [-n <name>] [-i <id>] [-f <format>] [-r|-w] <char-uuid> <data>
```

Writes data to a characteristic. Connects automatically if no connection is active. Write mode (with or without response) is auto-selected based on the characteristic's properties unless overridden: without response when the characteristic allows it, with response otherwise.

A write the characteristic does not allow is not sent and fails with exit code 5, naming its properties: `-r` to one without `write`, `-w` to one without `writeNoResp`, any write to one with neither, and a value longer than one write of that kind carries (512 bytes with response; the connection's ATT MTU minus 3 without).

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Data format (same values as `read`; any other is an error, exit code 6). Default: `hex`. |
| `-r, --with-response` | Force write-with-response. |
| `-w, --without-response` | Force write-without-response. |

**Examples:**
```sh
% blew write -n "Thingy" fff1 "deadbeef"           # Write hex bytes
% blew write -n "Thingy" -f uint8 -r 2A06 1        # Write uint8 with response
% blew write -n "Thingy" -f utf8 fff2 "hello"      # Write a UTF-8 string
% blew write -n "Thingy" -f float32le fff1 -- -1.5 # A value that starts with -
```

`--` ends the options: every argument after it is a value, even one that starts with `-`. On the command line a negative number needs it; in `exec` and the REPL a number such as `-1.5` is always a value, and `--` is needed only for other text that starts with `-`.

The data is one argument: quote a value that holds spaces (`write -f utf8 fff2 "hello world"`). `write fff1 01 02` writes nothing and fails with exit code 6, as does any command given more arguments than it takes; in `exec` and the REPL the error shows the command's usage (`unexpected argument '02' -- usage: write [options] <char> <data>`).

---

### `sub` — Subscribe to notifications or indications

```
blew sub [-n <name>] [-i <id>] [-f <format>] [-d <sec>] [-c <count>] <char-uuid>
```

Subscribes to a characteristic and streams received values to stdout, one event per line. Connects automatically if no connection is active. Stops on `Ctrl-C`, or when a duration/count limit is reached. If the connection ends first, `sub` fails: exit code 5 when the device disconnects, 3 when Bluetooth is turned off or blew loses Bluetooth permission. If the device does not confirm that notifications are on within the operation timeout (`-t`, default 5 seconds), `sub` fails with exit code 4. A characteristic that neither notifies nor indicates is not subscribed to: `sub` fails with exit code 5. A background subscription reports the same as a `sub error` line.

Several subscriptions to one characteristic (`sub -b X` and a foreground `sub X`, or an MCP subscribe beside them) each receive every value. Notifications stay on until the last of them ends, so one ending, timing out or being stopped does not silence the others. `sub -b X` while `X` already has a background subscription replaces it; `sub status` lists each background subscription until it ends or is stopped.

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Value format (same values as `read`). Default: `hex`. |
| `-d, --duration <sec>` | Stop after this many seconds, whether or not notifications arrive (at most a year). |
| `-c, --count <n>` | Stop after receiving this many notifications (a whole number, at least 1). |
| `-b, --bg` | Run in background (REPL and `exec` mode only; the `blew sub` command line does not take it). Returns the prompt immediately; notifications are printed as they arrive. Use `sub stop` to cancel. |

With `--out kv`, each line includes `ts=`, `char=`, and `value=` fields.

Notifications have no flow control, so a device can send them faster than `sub` writes them out (a terminal paused with Ctrl-S, output piped to a slow reader). Each subscription keeps at most 1024 values waiting; when another arrives, the oldest waiting one is dropped. Drops are reported, not hidden: once when `sub` sees the first of them, and with the total when it ends, as `sub 1024 notifications of <char> dropped: they came faster than they were written out` on stderr (`sub=dropped char=<char> total=<n>` on stdout with `--out kv`; the count is the total so far). A background subscription reports them on its own line, and an MCP `ble_subscribe` result has a `dropped` field.

**Background mode** (`-b`) is available in the REPL and `exec` scripts. Multiple characteristics can be subscribed simultaneously. Background notifications are printed to stderr with ANSI cursor control so they appear cleanly over the prompt:

```
blew> sub -b -f uint8 2A19
Subscribing to 2A19 (Battery Level) in background. Use 'sub stop 2A19' to stop.
blew> sub -b fff1
Subscribing to fff1 in background. Use 'sub stop fff1' to stop.
blew> sub status
Active background subscriptions:
  2A19 (Battery Level)
  fff1
blew> sub stop 2A19
Stopped subscription for 2A19 (Battery Level).
blew> sub stop
Stopped all background subscriptions.
```

**Examples:**
```sh
% blew sub -n "Thingy" fff1                        # Stream indefinitely (Ctrl-C to stop)
% blew sub -n "Thingy" -f uint16le -d 30 fff1      # 30-second capture as uint16
% blew -o kv sub -n "Thingy" -c 100 2A37           # Capture 100 events, kv output
% blew -o kv sub -n "Thingy" fff1 >> data.log      # Append to a log file
```

---

### `nus` — Nordic UART Service bridge

```
blew nus [-n <name>] [-i <id>] [-S <uuid>] [-p <strategy>]
         [-s <text>]... | [--file <path>] | [--pty] | [-l <port> [--bind <addr>]]
         [-e <text>] [-d <sec>] [--reconnect] [-r|-w]
```

Bridges a local endpoint to a device's [Nordic UART Service](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/libraries/bluetooth/services/nus.html) (NUS): service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, RX characteristic `6E400002-…` (blew writes to it) and TX characteristic `6E400003-…` (the device notifies on it). Connects like `connect`; with no device option at all it uses the connected device, or else scans for devices advertising NUS and picks the strongest (or the one `-p` picks). Writes are split into pieces that fit one ATT packet (the negotiated MTU minus 3), and writes without response wait for the device to be ready rather than being dropped.

Bytes pass unchanged in both directions: no line-ending translation and no added newline. What arrives from the device is written to stdout as it comes, without a timestamp or newline; with `--out kv`, each notification is a `ts=… rx=<hex>` line instead. Bridge events (`connected`, `disconnected`, `reconnecting`, `dropped`, the pty path, TCP clients) go to stderr as `nus <event>: <detail>` lines.

The local endpoint is one of:

| Endpoint | Description |
|----------|-------------|
| standard input/output | The default. Each read from stdin goes to the device; the session ends at end of input plus `--duration` seconds, so `echo hi \| blew nus -n dev` prints the reply. |
| `-s, --send <text>` | Send this text instead of reading stdin (repeatable). Escapes `\n \r \t \0 \\ \xHH` are decoded, so `-s 'ping\n'` sends a line in any shell. |
| `--file <path>` | Send the file's bytes instead of reading stdin. |
| `--pty` | Open a pseudo-terminal in raw mode and print its path (e.g. `/dev/ttys012`). Programs that expect a serial port (`screen`, `cu -l`, `picocom`, `minicom`) open it as they would a USB-serial adapter, and may close and reopen it while the bridge runs. |
| `-l, --listen <port>` | Listen for TCP on `127.0.0.1:<port>` and bridge one client at a time (`nc localhost <port>`); the next client is accepted after the current one disconnects. `--bind <addr>` listens on another address; there is no authentication, so blew warns when it is not a loopback address. |

| Flag | Description |
|------|-------------|
| `-e, --expect <text>` | Succeed as soon as this text (same escapes as `--send`) has arrived, even split across notifications; exit with code 4 (timeout) if it has not arrived `--duration` seconds after the input ends. Works with stdin, `--send` and `--file`. |
| `-d, --duration <sec>` | Seconds to keep listening after the input ends. Default 1; with `--expect`, the deadline for the expected text, default 5. At most a year. |
| `--reconnect` | When the device disconnects, report it, reconnect to that same device (by its identifier, whatever else now matches the targeting options) and keep the endpoint (pty or TCP listener) open. Input not yet written when the link was lost (the rest of `--send`, `--file` or stdin, or what a pty or TCP client typed meanwhile) is written after the reconnect, starting with the piece whose write was under way, so the device may receive that piece twice. Only writes with response (`-r`) are confirmed by the device: without response, pieces handed to Bluetooth just before the link was lost can be lost, so use `-r` when every byte must arrive. A TCP client's bytes not yet written when it disconnects are dropped, so they never reach the device on behalf of the next client. Without `--reconnect`, a disconnect ends the command with exit code 5 (3 when Bluetooth is turned off or blew loses Bluetooth permission), and the error gives a lower bound on the input bytes not sent; so does a subscribe or write failure while the device is still connected, with or without it. |
| `-r, --with-response` / `-w, --without-response` | Write type for RX. Default: without response when RX supports it. |

Each write to the device must complete within the operation timeout (`-t`, default 5 s); a write the device never acknowledges, or a write without response that never gets the device's flow-control credit, ends the command with exit code 4.

blew holds about 64 KiB of local input that the device has not taken yet (64 KiB plus one read of at most 4 KiB); while that much is waiting it stops reading, so a pipe waits and a pty or TCP client's writes block, instead of blew's memory growing. `--file` reads the whole file into memory first.

A pty or TCP bridge runs until `Ctrl-C` (or until the device disconnects, without `--reconnect`). If the local program is not reading, or no TCP client is connected, bytes from the device that do not fit the pty or socket buffer are dropped, as on a serial line: the first loss of each run is reported as `nus dropped: <n> bytes from the device: …`, and when the bridge ends a last `dropped` event gives the total. Notifications that arrive faster than blew passes them on (stdout piped to a slow reader) wait in a buffer of 1024; beyond that the oldest are dropped, reported as `nus dropped: <n> notifications from the device: …` at the first loss of a session and with the session's total when it ends. A `--expect` match never spans dropped notifications: the expected bytes count only when they arrived without a drop among them.

In the REPL and `exec`, standard input belongs to blew, so `nus` there sends only `--send`/`--file` bytes, or just listens for `--duration` seconds; `--pty` and `--listen` block the prompt until `Ctrl-C`.

**Examples:**
```sh
% blew nus -n erxos                                    # interactive line terminal (Ctrl-D, then 1 s, to end)
% blew nus -n erxos -s 'hello\n' -e 'hello\n'          # scripted echo test; exit 0 when the echo arrives
% blew nus -s 'status\r\n' -d 3 > reply.txt            # strongest NUS device; capture 3 s of reply
% blew nus -n erxos --file firmware.txt -w             # stream a file without response
% blew nus -n erxos --pty --reconnect                  # then: screen /dev/ttys012 115200
% blew nus -n erxos -l 7000 &  nc localhost 7000       # TCP bridge
% blew exec "connect -n erxos; nus -s 'ping\n' -e ping; nus -s 'pong\n' -e pong"
```

---

## Interactive REPL

Run `blew` with no arguments (or with global options but no subcommand) to start the interactive REPL:

```sh
% blew
% blew -v           # Start verbose REPL
```

The REPL provides:
- **Line editing** — cursor movement, Ctrl-A/E, Ctrl-W, etc.
- **Persistent history** — saved to `~/.config/blew/history` across sessions
- **Tab completion** — commands, known UUIDs after GATT discovery, and format names

When standard input is not a terminal, the REPL runs it as a script, the way `exec` runs one: one command per line, without a prompt, banner or line editing, until end of input. The first failing command ends the run with its exit code; a line that is not valid UTF-8 exits with code 6, and an unreadable standard input with code 5. A script neither reads nor writes the history file.

```sh
% printf 'gatt info 2A19\n' | blew
```

### REPL commands

| Command | Description |
|---------|-------------|
| `scan [options]` | Scan for devices |
| `connect [<id>]` | Connect to a device |
| `disconnect` | Disconnect |
| `status` | Show connection status (at `-vv`, also how many scan results were dropped because blew fell behind a scan) |
| `gatt svcs\|tree\|chars\|desc\|info` | GATT inspection |
| `read [-f <fmt>] <uuid>` | Read a characteristic |
| `write [-f <fmt>] [-r\|-w] <uuid> <data>` | Write to a characteristic |
| `sub [-f <fmt>] [-d <s>] [-c <n>] <uuid>` | Subscribe to notifications (Ctrl-C to stop) |
| `sub [-b] [-f <fmt>] [-d <s>] [-c <n>] <uuid>` | Subscribe in background; prompt remains available |
| `sub stop [<uuid>]` | Stop one or all background subscriptions |
| `sub status` | List active background subscriptions |
| `nus [-s <text>] [--file <f>] [-e <text>] [-d <s>] [--pty] [-l <port>]` | Nordic UART Service bridge (see `nus`) |
| `periph adv [-n <n>] [-S <uuid>] [--config <f>]` | Start advertising as a virtual peripheral |
| `periph clone [--save <f>]` | Clone a real device's GATT |
| `periph stop` | Stop advertising |
| `periph set [-f <fmt>] <uuid> <val>` | Update a characteristic value |
| `periph notify [-f <fmt>] <uuid> <val>` | Push a notification to subscribers |
| `periph status` | Show peripheral advertising state |
| `help` | Show available commands |
| `quit` / `exit` | Exit the REPL |

**Example session:**
```
blew> scan -t 3 -n Thingy
ID                                    NAME    RSSI  Signal    Services
-------------------------------------------------------------------------------------------
F3C2A1B0-1234-5678-ABCD-000000000001  Thingy  -58   ████████  180F (Battery Service), 180A (Device Information)

blew> connect F3C2A1B0-1234-5678-ABCD-000000000001

blew> gatt tree
Service 180F  Battery Service
└── 2A19  Battery Level  [read, notify]

Service 180A  Device Information
└── 2A29  Manufacturer Name String  [read]

blew> read -f uint8 2A19
87

blew> sub -f uint8 -c 5 2A19
87
86
86
85
85

blew> quit
```

---

## Script execution (`exec`)

The `exec` subcommand runs a semicolon-separated sequence of commands in a single process, sharing one connection lifecycle. Commands are parsed identically to the REPL: an argument in single or double quotes may hold spaces and `;` (`write -f utf8 fff1 'a;b'` writes `a;b`); a quote runs to the next quote of the same kind, without escapes. A quote that is never closed is an error (exit code 6), and nothing in the script runs. Options follow these rules in `exec` and the REPL: an option the command does not take, an argument given to a command that takes none (`disconnect x`, `periph status x`), an option that takes a value but has none, a value given to a flag (`--watch=1`), and a single-value option given twice are errors too (exit code 6). An option that takes a value takes the next argument whatever it looks like, so `sub -n -b 2A19` subscribes on a device whose name contains `-b` and does not start a background subscription; `--name=value` gives the value in one argument. Short flags combine (`gatt tree -dr`), and an option that takes a value may end the group (`scan -wR -70`). The first command that requires a connection triggers an automatic connect; subsequent commands reuse it.

```sh
% blew exec "connect -n Thingy; gatt tree; read -f uint8 2A19"
```

**Flags:**

| Flag | Description |
|------|-------------|
| `-k, --keep-going` | Continue after a command error; exit with the first non-zero code seen. Ctrl-C still stops the script, with exit code 130. |
| `--dry-run` | Print parsed steps without executing them. |

**Additional commands available in exec and REPL:**

| Command | Description |
|---------|-------------|
| `sleep <seconds>` | Pause for the given number of seconds. `0` means infinite (until Ctrl-C). |

**Examples:**
```sh
# Connect by name, read a value
% blew exec "connect -n Thingy; read -f uint8 2A19"

# Wait 2 seconds between operations
% blew exec "connect -n Thingy; sleep 2; read -f uint8 2A19"

# Keep going after errors
% blew exec -k "read fff1; read fff9"

# Preview what would run
% blew exec --dry-run "connect -n Thingy; gatt tree; read -f uint8 2A19"
```

---

## Output and logging

### stdout vs stderr

| Stream | Content |
|--------|---------|
| stdout | Command results — tables, values, notification lines |
| stderr | Operational messages (errors, verbose info, debug) |

### Text from devices

Names, values and other text that come from a device, a config file or an argument are untrusted: a device name could carry ANSI or OSC escape sequences that recolor the terminal, set its title or move the cursor. In text output and in every line on stderr, blew writes C0 and C1 control characters, the line and paragraph separators and the invisible format characters (bidirectional overrides, zero-width space and the others listed under [Key-value output](#key-value-output---out-kv)) as escape sequences of the same syntax: `\n`, `\t`, `\x1b`, `\u202e`. Backslash itself is left as is in text output. What `nus` relays to stdout is the device's bytes, unchanged; `-f raw` and `-f hex` print a value as hex digits, which need no escaping. A `-f utf8` value that is not valid UTF-8 is printed as hex. Escaping every format character also escapes the tag characters of subdivision flags and the left-to-right and right-to-left marks in names that use them.

Table columns are measured in terminal columns: East Asian wide and fullwidth characters and emoji take two, combining marks none, so CJK names and names with emoji stay aligned and no name is cut short. Scripts whose clusters a terminal draws wider than one column per character (Devanagari vowel signs, for example) can still misalign.

### Log format (stderr)

Errors are always printed:
```
Error: timeout waiting for connection
```

With `-v`, informational messages are also shown:
```
connecting to F3C2A1B0-...
connected to F3C2A1B0-...
```

With `-vv`, debug-level messages are added:
```
[debug] discovered service 180F
[debug] discovered characteristic 2A19
```

### Key-value output (`--out kv`)

Pass `-o kv` to get machine-parseable output. Each record is one line of space-separated `key=value` pairs. Easy to process with `awk`, `grep`, or any log parser:

```
id=F3C2A1B0-... name=Thingy rssi=-58 services=180F,180A
char=2A19 name="Battery Level" value=57 fmt=uint8
ts=2026-02-21T12:34:56.789Z char=fff1 value=deadbeef
```

The `name=` field is included when the UUID is a known Bluetooth SIG UUID. It is omitted for custom or vendor UUIDs.

The syntax, exactly:

- A record is `key=value` pairs separated by one space and ended by a newline. A value can never contain a raw newline, so one record is always one line.
- Keys are lowercase letters, digits and `_`, never quoted.
- A value is written bare when it is non-empty and contains no whitespace (space, or any other Unicode whitespace such as U+00A0 or U+3000), `=`, `"`, `\` or escaped character (below). Whitespace other than newline, carriage return and tab is kept as is inside the quotes. Otherwise it is written in double quotes, with `\` as `\\` and `"` as `\"`.
- Escaped characters, inside the quotes: newline `\n`, carriage return `\r`, tab `\t`, other characters below U+0080 (C0 controls, DEL) as `\xHH`, and C1 controls (U+0080 to U+009F), the line and paragraph separators (U+2028, U+2029) and the invisible format characters (Unicode category Cf: bidirectional overrides and isolates, zero-width space, soft hyphen, byte order mark, tag characters) as `\uHHHH`, or `\UHHHHHHHH` above U+FFFF. Zero-width joiner and non-joiner (U+200D, U+200C) are kept, so emoji sequences stay intact. Hex digits are lowercase.

This is a subset of Go's string-literal syntax: `strconv.Unquote` in Go reads a quoted value back, quotes included. A device name `x` newline `connected=yes` is printed as `name="x\nconnected=yes"`.

A characteristic whose decoded value has several fields (`gatt tree -r`, `gatt chars -r`) has one `value=` holding the fields as `<label>: <value>` joined by ` | `, the same fields text output prints one per line.

```sh
% blew -o kv sub -n "Thingy" -d 60 fff1 | awk -F'value=' '{print $2}'
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `2` | Not found / no matching device |
| `3` | Bluetooth unavailable or permission denied |
| `4` | Timeout |
| `5` | Operation failed (connect / GATT / read / write / subscribe, or the REPL cannot read or write its terminal or standard input) |
| `6` | Invalid arguments: an unknown option or subcommand, a missing argument, an extra argument (`write fff1 01 02`, `scan Thingy`; the error shows the command's usage), or an option value blew cannot use (an unknown `-f` format, a `-c` that is not a whole number of at least 1, an invalid `-t`) |
| `130` | Interrupted by Ctrl-C (SIGINT) |
| `143` | Terminated by SIGTERM |

`--help` and `--version` exit with code 0. A usage error exits with code 6: on the command line it prints the error and the command's usage to stderr, in `exec` and the REPL the error alone. The code follows the kind of failure, whatever the command: Bluetooth that is off, not permitted or not supported when a command starts gives 3, also from `scan` and from the scan that connects a command automatically, at once rather than after `-t`.

Ctrl-C stops the running command: it stops scanning, subscribing or advertising, prints what it has (`scan -w` prints its final table, `periph` prints "Stopped advertising."), and blew exits with code 130. In the REPL, Ctrl-C stops the running command and returns to the prompt. SIGTERM ends blew in any mode with code 143. Before exiting on either signal, blew stops advertising, disconnects, saves the REPL history and gives the terminal back in its normal mode. When standard output is not a terminal, each line is written as soon as it is printed, so `blew -o kv sub ... >> log` delivers each record at once.

---

### `periph` — Peripheral (GATT server) mode

`periph` turns the Mac into a virtual BLE peripheral that nearby devices can connect to, read/write, and subscribe to.

> **CoreBluetooth peripheral limitations:** Only the local device name and service UUIDs can be advertised. Manufacturer data and other ADV payload fields are not settable from the peripheral API. ADV interval, TX power, and connection parameters are OS-controlled.
>
> **Advertised name vs hostname:** macOS always uses the computer hostname as the GAP (Generic Access Profile) device name. iOS scanners that have previously connected to the Mac will show the cached GAP name (hostname) in their device list, not the advertising name set via `-n`. The advertising name is still present in the raw advertisement data (`kCBAdvDataLocalName`) and is visible in tools like LightBlue under "Advertisement Data" after tapping the device.
>
> Most standard Bluetooth SIG service UUIDs work in short form (e.g. `180D`, `1809`, `181A`). However, services that macOS itself exposes as a peripheral are blocked in short form — `CBPeripheralManager` rejects `1800` (Generic Access), `1801` (Generic Attribute), `1805` (Current Time), `180A` (Device Information), `180F` (Battery), `1812` (HID), and `181E` (Bond Management) with "The specified UUID is not allowed for this operation." The full 128-bit Bluetooth Base UUID form (e.g. `0000180F-0000-1000-8000-00805F9B34FB`) bypasses the check but registers as a raw 128-bit UUID, so centrals will not recognise it as the standard service.

#### `periph adv` — Advertise and host a GATT server

```
blew periph adv [-n <name>] [-S <uuid>] [--config <file>]
```

Starts advertising, prints what it advertises, and runs until interrupted (Ctrl-C), which stops advertising and exits with code 130. Events (reads, writes, subscriptions) are logged to stdout. If Bluetooth is turned off or access is revoked while it advertises, advertising ends, the services are gone, and `periph adv` exits with code 3 ("Bluetooth unavailable: Bluetooth is powered off"). If starting up times out or is interrupted, nothing is left advertising, even when CoreBluetooth confirms the start afterwards.

The GATT server answers a remote central the way ATT specifies. A read at an offset past the end of the value is answered with an Invalid Offset error; at the end, with an empty value. A long (prepared) write is assembled from its fragments in order: a write at offset n keeps the first n bytes of the value and replaces the rest. A write at an offset past the end of the value is rejected with Invalid Offset, and one that would make the value longer than 512 bytes (the ATT maximum) with Invalid Attribute Value Length; a rejected request changes nothing. A `writeRequest` event shows the whole value after the write.

| Flag | Description |
|------|-------------|
| `-n, --name <name>` | Advertised device name. Defaults to `blew`. |
| `-S, --service <uuid>` | Service UUID to advertise, repeatable. |
| `-c, --config <file>` | JSON config file defining services and characteristics. |

**Config file format:**

```json
{
  "name": "My Device",
  "services": [
    {
      "uuid": "180F",
      "primary": true,
      "characteristics": [
        {
          "uuid": "2A19",
          "properties": ["read", "notify"],
          "value": "55",
          "format": "uint8"
        }
      ]
    }
  ]
}
```

`properties` may contain: `read`, `write`, `writeWithoutResponse`, `notify`, `indicate`.
`format` accepts the same values as `--format` in `read`/`write`: `hex` (default), `utf8`, `uint8`, `uint16le`, `uint32le`, `float32le`, `base64`, `raw`. Any other `format` is an error (exit code 6), with or without a `value`.

A UUID, in the config file, in `-S` and in `periph set`/`periph notify`, is 4 hex digits (`180F`), 8 hex digits (`0000180F`) or a 128-bit UUID written 8-4-4-4-12 (`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`), in either case. Spellings of one UUID are interchangeable: a characteristic configured as `00002A19-0000-1000-8000-00805F9B34FB` is set with `periph set 2A19 ...`. Anything else, such as `0x180F` or `180G`, is an error naming the offending value (exit code 6):

```
Error: Invalid config: services[0].uuid: invalid UUID "180G": expected 4 or 8 hex digits, or a 128-bit UUID such as 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
```

A characteristic cannot list descriptors. CoreBluetooth creates the Client Characteristic Configuration (`2902`) and Extended Properties (`2900`) descriptors itself from `properties`, and the only other descriptors it hosts, `2901` and `2904`, need values the config format does not carry. A config that lists any descriptor is rejected with exit code 6, and so is one that names a characteristic UUID twice, in any spelling, even in different services.

**Examples:**

```sh
# Advertise a name + service UUID (scanner-visible, no GATT characteristics)
% blew periph adv -n "My Sensor" -S 180F

# Multiple service UUIDs
% blew periph adv -n "My Sensor" -S 180F -S 180A

# Full GATT server from a config file
% blew periph adv --config device.json

# Config file with name override
% blew periph adv -n "Override Name" --config device.json
```

Example config files are provided in the [`Examples/`](Examples/) directory:

| File | Description |
|------|-------------|
| `health-thermometer.json` | Health Thermometer (`1809`) — indicate temperature measurement (2A1C), read temperature type (2A1D), read/write/notify measurement interval (2A21) |
| `environmental-sensing.json` | Environmental Sensing (`181A`) — read/notify temperature (2A6E), humidity (2A6F), and pressure (2A6D) |
| `blood-pressure.json` | Blood Pressure (`1810`) — indicate measurement (2A35), read feature flags (2A49) |
| `custom-sensor.json` | Fully custom vendor service with 128-bit UUIDs — read/notify value, read/write config register, write-only command endpoint |

**Output (text mode):**

```
Advertising "My Sensor" [180F (Battery Service)]
  Service 180F (Battery Service)
  +-- 2A19 (Battery Level) [read, notify]

[12:34:56] central A1B2C3D4 connected
[12:34:56] read 2A19 (Battery Level) by A1B2C3D4
[12:34:57] subscribe 2A19 (Battery Level) by A1B2C3D4
[12:35:01] write 2A19 (Battery Level) by A1B2C3D4 <- 2a
^C
Stopped advertising.
```

**Output (kv mode):**

```
event=connected ts=12:34:56 central=A1B2C3D4-...
event=read ts=12:34:56 central=A1B2C3D4-... char=2A19
event=subscribe ts=12:34:57 central=A1B2C3D4-... char=2A19
event=write ts=12:35:01 central=A1B2C3D4-... char=2A19 value=2a
```

#### `periph clone` — Clone a real device

```
blew periph clone [-n <name>] [-i <id>] [--save <file>]
```

Connects to a target device, discovers its full GATT tree, reads all readable characteristic values, disconnects, then starts advertising as a clone.

| Flag | Description |
|------|-------------|
| `-n, --name` | Target device name filter. |
| `-i, --id` | Target device identifier. |
| `-o, --save <file>` | Save the cloned GATT structure to a JSON config file for later reuse. The path is checked before blew connects: a directory, or a path whose directory is missing or read-only, fails with exit code 6. The file is replaced whole. If writing the file then fails, clone stops with exit code 5 and does not advertise. |

**Clone scope:**
- Cloned: advertised name, service UUIDs, full GATT structure, initial characteristic values (for readable characteristics).
- Not cloned: manufacturer data, service data in ADV payload, ADV timing.

**Examples:**

```sh
% blew periph clone -n "Heart Rate Monitor"
% blew periph clone -i F3C2A1B0-... --save hr-monitor.json
```

#### REPL-only periph commands

In REPL and `exec` mode, `periph adv` and `periph clone` run in two phases. The startup phase (configure + start advertising) is synchronous and confirms the peripheral came up. Once advertising is confirmed, the event loop runs as a background task and the prompt is returned immediately. This makes `periph stop`, `periph set`, and `periph notify` usable in the same session:

| Command | Description |
|---------|-------------|
| `periph stop` | Stop advertising and cancel the background event task. |
| `periph set [-f <fmt>] <char> <val>` | Update a characteristic's stored value. |
| `periph notify [-f <fmt>] <char> <val>` | Update value and push a notification to all subscribers. When the Bluetooth transmit queue is full, the notification waits and is sent in order once there is room; at most 64 wait, and a notification past that is an error (exit 5) that leaves the value unchanged. With no central subscribed, only the value is updated, and the message says so. |
| `periph status` | Show advertising state, service/characteristic counts, subscriber count. |

```
blew> periph adv --config device.json
Advertising "My Device" [180F]
Advertising in background. Use 'periph stop' to stop.
blew> periph notify -f uint8 2A19 42
blew> periph stop
Stopped advertising.
```

In `exec` mode the same non-blocking behaviour applies, enabling scripts like:

```sh
% blew exec "periph adv -n 'My Device' --config device.json; periph set 2A19 ff; periph notify 2A19 ff"
```

---

## MCP Server Mode

`blew mcp` starts a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio, exposing all BLE operations as individual MCP tools. AI agents (Cursor, Claude Desktop, etc.) can discover and invoke these tools to interact with BLE devices programmatically.

The server is stateful: BLE connections and peripheral state persist across tool calls, just like the REPL. Tool results are returned as structured JSON (`structuredContent`), giving agents typed access to scan results, GATT data, read values, and more.

### Agent configuration

**Cursor** (`.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "blew": {
      "command": "/path/to/blew",
      "args": ["mcp"]
    }
  }
}
```

**Claude Desktop** (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "blew": {
      "command": "/path/to/blew",
      "args": ["mcp"]
    }
  }
}
```

### Available tools

| Tool | Description |
|------|-------------|
| `ble_scan` | Scan for nearby BLE devices |
| `ble_connect` | Connect to a device by ID, name, or filters |
| `ble_disconnect` | Disconnect from current device |
| `ble_status` | Show connection status |
| `ble_gatt_services` | List GATT services |
| `ble_gatt_tree` | Full GATT tree with optional values |
| `ble_gatt_chars` | List characteristics of a service |
| `ble_gatt_descriptors` | List descriptors of a characteristic |
| `ble_gatt_info` | Look up Bluetooth SIG characteristic spec (no device needed) |
| `ble_read` | Read a characteristic value |
| `ble_write` | Write to a characteristic |
| `ble_subscribe` | Collect notifications (returns batch) |
| `ble_periph_advertise` | Start advertising as a peripheral |
| `ble_periph_clone` | Clone a real device's GATT structure |
| `ble_periph_stop` | Stop advertising |
| `ble_periph_set` | Update a peripheral characteristic value |
| `ble_periph_notify` | Update value and notify subscribers |
| `ble_periph_status` | Show peripheral state |
| `ble_nus` | Send text over the Nordic UART Service and collect the reply, optionally waiting for an expected text |

All tools that interact with a remote device accept optional targeting parameters (`name`, `device_id`, `service`, `manufacturer`, `rssi_min`, `pick`) and auto-connect if not already connected. A connected device that does not match the parameters given is replaced by the named device (see [Device targeting options](#device-targeting-options)); `device_id` is an identifier or a fragment of one, never a name. A call that disconnected the connected device to connect to another adds `deviceSwitches` to its structured result, `[{"from": "<old-id>", "to": "<new-id>"}]`, whether or not that connect or the call then succeeded; when the call has no other result, it is the only field. The switches of a cancelled call, which gets no response, come with the result of the next call to reply after it, all in the order the calls ran. With `pick`, `ble_scan` returns only the device that strategy picks.

Global options given before `mcp` apply to every tool call: `blew -t 30 mcp` gives each BLE operation a 30-second timeout.

### Calls, arguments and time limits

- **One call at a time.** Tool calls never overlap: a call that arrives while another runs waits for it to return, so two calls do not switch the device under each other. Calls sent without waiting for the previous reply may start in either order; send a call after the reply to the one it depends on.
- **Arguments are checked against the tool's input schema** before the call runs. An argument the tool does not declare, a value of the wrong JSON type (`"duration": "5"` instead of `5`), a value outside the listed `enum`, `minimum` or `maximum`, or a missing required argument fails the call with exit code 6 and the reason; nothing is ignored.
- **Durations.** `ble_subscribe` collects for `duration` seconds, 10 when the call gives none, and stops earlier once `count` notifications (no limit by default) have arrived. `ble_subscribe` and `ble_nus` accept a `duration`, and `ble_scan` a `timeout`, of at most 300 seconds.
- **Every call has a time budget**: its own duration (the scan `timeout`, the subscribe or NUS `duration`; zero for the other tools) plus 60 seconds for connecting and setup, or plus four times `-t` when that is longer. The budget counts from when the call starts, not while it waits its turn. A call still running when its budget runs out is stopped and fails with exit code 4, with whatever output the command returned (the notifications a subscription received so far; a scan stopped this way returns no devices).
- **Subscriptions run in the foreground.** `ble_subscribe` always returns its notifications with the call; there is no background subscription over MCP. Its result's `dropped` field counts the notifications dropped because more than 1024 came before blew collected them (see `sub`); it is 0 when none were. A `ble_nus` result has the same `dropped` field, beside `received` and `receivedHex`: the notifications from the device, over every reconnect of the call, dropped because they came faster than blew collected them, so `received` is incomplete when it is not 0 (see `nus`).
- **Cancellation.** When the client cancels a call (`notifications/cancelled`), the call stops and the server sends no response for it; a cancelled call that was still waiting its turn never starts.
- **SIGINT** (`kill -INT`) stops the call that is running, which fails with exit code 130; the server keeps serving. A SIGINT while no call runs ends the server with exit code 130, and SIGTERM ends it with 143.

### Example structured output

A `ble_scan` call returns:

```json
{
  "type": "devices",
  "devices": [
    {
      "id": "A1B2C3D4-...",
      "name": "Heart Rate Sensor",
      "rssi": -55,
      "serviceUUIDs": ["180D"],
      "serviceDisplayNames": ["Heart Rate"]
    }
  ]
}
```

A `ble_read` call returns:

```json
{
  "type": "readValue",
  "readValue": {
    "char": "2A19",
    "name": "Battery Level",
    "value": "85",
    "format": "uint8"
  }
}
```

---

## Recipes

### Find a device in a crowded environment
```sh
% blew -t 10 scan -n "Sensor" -S 180F -R -65
```

### Capture sensor data to a file
```sh
% blew -o kv sub -n "Sensor" -f uint16le -d 300 fff1 >> sensor.log
```

### Quick GATT audit in one line
```sh
% blew gatt tree -n "Thingy" -d
```

### Inspect device info characteristics with values
```sh
% blew gatt chars -n "Thingy" -r 180A
```

### Read with scripting
```sh
% value=$(blew read -n "Thingy" -f uint8 2A19)
% echo "Battery: ${value}%"
```

### Use `--pick only` to guard against accidental multi-match
```sh
% blew read -n "Thingy" -p only -f uint8 2A19
# Errors out if more than one "Thingy" is nearby
```