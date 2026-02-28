# blew — macOS BLE CLI Workbench

A macOS command-line tool for debugging and working with Bluetooth Low Energy (BLE) devices. Scan for peripherals, connect, inspect GATT services, read/write characteristics, and stream notifications — all from the terminal.

Works in two modes:

- **Command mode** — run a single command, then exit: `blew [global-options] <command> [command-options]`
- **Interactive REPL** — run `blew` with no command for a readline-style shell with history and tab completion

> Requires macOS 13 or later and Bluetooth permission.

---

## Installation

Build from source with Swift:

```bash
git clone --recurse-submodules <repo-url>
swift build -c release
cp .build/release/blew /usr/local/bin/blew
```

`--recurse-submodules` is required — the Bluetooth SIG name and characteristic databases are included as git submodules under `Vendor/`. The Swift build generates all data files automatically from the submodule data.

On first run, macOS will prompt for Bluetooth permission. Grant it in **System Settings → Privacy & Security → Bluetooth**.

---

## Quick start

```bash
# Scan for nearby devices
blew scan

# Print the GATT tree of a device (connects automatically)
blew -n "Thingy" gatt tree

# Read a characteristic (battery level)
blew -n "Thingy" read -f uint8 2A19

# Subscribe to notifications for 10 seconds
blew -n "Thingy" sub -d 10 fff1

# Run a multi-step procedure in one invocation
blew -n "Thingy" -x "gatt tree; read -f uint8 2A19"

# Start the interactive REPL
blew
```

---

## Global options

These options apply to all commands and must be placed **before** the subcommand name:

```bash
blew [global-options] <command> [command-options]
```

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Increase log verbosity. Repeatable: `-vv` for debug-level detail. |
| `-o, --out <format>` | Output format for results: `text` (default, human-readable) or `kv` (key=value, one record per line — easier to parse). |
| `-t, --timeout <sec>` | Timeout in seconds for BLE operations. |
| `-h, --help` | Show help and exit. |
| `--version` | Show version and exit. |

## Device targeting options

Commands that connect to a device (`scan`, `connect`, `gatt`, `read`, `write`, `sub`, `periph clone`) accept these options to identify the target. Pass them after the subcommand name.

Use `--id` to target an explicit device, or combine selectors to let blew find a match automatically.

| Flag | Description |
|------|-------------|
| `-i, --id <device-id>` | Target a specific device by its identifier. |
| `-n, --name <substring>` | Filter by device name (substring match). |
| `-S, --service <uuid>` | Filter by advertised service UUID. Repeatable. |
| `-m, --manufacturer <id>` | Filter by manufacturer ID. |
| `-R, --rssi-min <dBm>` | Minimum RSSI threshold (e.g. `-R -70`). |
| `-p, --pick <strategy>` | How to pick when multiple devices match: `strongest` (default, highest RSSI), `first` (first seen), `only` (error if multiple match). |

---

## Commands

### `scan` — Scan for BLE devices

```
blew scan [-n <name>] [-S <uuid>] [-R <dBm>] [-i <id>] [-m <id>] [-p <strategy>] [-w]
```

Scans for advertising BLE peripherals and prints a table of discovered devices. Timeout defaults to 5 seconds.

**Flags:**

| Flag | Description |
|------|-------------|
| `-n, --name` | Filter results by device name substring. |
| `-S, --service` | Filter by advertised service UUID. Repeatable. |
| `-R, --rssi-min` | Minimum RSSI threshold (e.g. `-R -70`). |
| `-i, --id` | Show only the device with this identifier. |
| `-m, --manufacturer` | Filter by manufacturer ID. |
| `-p, --pick` | Pick strategy: `strongest`, `first`, `only`. |
| `-w, --watch` | Continuously scan and show a live-updating device list. Runs until Ctrl-C or `-t` expires. Requires a TTY in text mode; use `-o kv` for piped output. |

**Output columns (text):** ID, Name, RSSI, Signal (visual bar), Services

Standard Bluetooth SIG service UUIDs in the Services column are shown with their human-readable name: e.g. `180F (Battery Service), 180A (Device Information)`.

**Examples:**
```bash
blew scan                          # Scan for 5 seconds
blew -t 10 scan                    # Scan for 10 seconds
blew scan -w                       # Continuously scan until Ctrl-C
blew -t 30 scan -w                 # Watch for 30 seconds then stop
blew scan -n "Heart" -w            # Watch for Heart Rate devices
blew scan -S 180D -R -65           # Heart Rate service, RSSI ≥ -65 dBm
blew -o kv scan                    # Machine-readable output
blew -o kv scan -w                 # Stream device updates (piping-friendly)
```

---

### `connect` — Connect to a device

```
blew connect [-n <name>] [-S <uuid>] [-i <id>] [<device-id>]
```

Explicitly connects to a BLE device and exits. Useful for testing connectivity or pre-warming a connection in `exec` scripts. The device can be specified by positional argument, `--id`, or device-targeting selectors (the tool will scan briefly to resolve them).

For `gatt`, `read`, `write`, and `sub` you do not need to run `connect` first — those commands connect automatically using the same device-targeting options.

The connection is automatically closed on exit.

**Examples:**
```bash
blew connect F3C2A1B0-...          # Test connectivity to an explicit ID
blew connect -n "Thingy"           # Test connectivity by name
blew connect -S 180F               # Connect to device advertising Battery Service
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
| `-r, --read` | Read and display values for all readable characteristics inline. Well-known Bluetooth SIG characteristics are decoded to their natural type (e.g. battery level as an integer, manufacturer name as a string); others are shown as hex. |

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

With `-o kv`, one record per field is emitted (for scripting).

**Examples:**
```bash
blew gatt tree -n "Thingy"
blew gatt tree -n "Thingy" -d        # Include descriptors
blew gatt tree -n "Thingy" -r        # Read values for readable characteristics
blew gatt tree -n "Thingy" -dr       # Descriptors + values
blew gatt chars -n "Thingy" 180F
blew gatt chars -n "Thingy" -r 180A  # Read values for Device Information
blew gatt desc -n "Thingy" 2A19
```

---

### `read` — Read a characteristic value

```
blew read [-n <name>] [-i <id>] [-f <format>] <char-uuid>
```

Reads the value of a characteristic and prints it in the requested format. Connects automatically if no connection is active.

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Output format (see table below). Default: `hex`. |

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
```bash
blew read -n "Thingy" -f uint8 2A19     # Battery level as integer
blew read -n "Thingy" -f utf8 2A29      # Manufacturer name string
blew read -n "Thingy" fff1              # Raw characteristic as hex
```

---

### `write` — Write to a characteristic

```
blew write [-n <name>] [-i <id>] [-f <format>] [-r|-w] <char-uuid> <data>
```

Writes data to a characteristic. Connects automatically if no connection is active. Write mode (with or without response) is auto-selected based on the characteristic's properties unless overridden.

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Data format (same values as `read`). Default: `hex`. |
| `-r, --with-response` | Force write-with-response. |
| `-w, --without-response` | Force write-without-response. |

**Examples:**
```bash
blew write -n "Thingy" fff1 "deadbeef"           # Write hex bytes
blew write -n "Thingy" -f uint8 -r 2A06 1        # Write uint8 with response
blew write -n "Thingy" -f utf8 fff2 "hello"      # Write a UTF-8 string
```

---

### `sub` — Subscribe to notifications or indications

```
blew sub [-n <name>] [-i <id>] [-f <format>] [-d <sec>] [-c <count>] [-b] <char-uuid>
```

Subscribes to a characteristic and streams received values to stdout, one event per line. Connects automatically if no connection is active. Stops on `Ctrl-C`, or when a duration/count limit is reached.

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Value format (same values as `read`). Default: `hex`. |
| `-d, --duration <sec>` | Stop after this many seconds. |
| `-c, --count <n>` | Stop after receiving this many notifications. |
| `-b, --bg` | Run in background (REPL and `exec` mode only). Returns the prompt immediately; notifications are printed as they arrive. Use `sub stop` to cancel. |

With `--out kv`, each line includes `ts=`, `char=`, and `value=` fields.

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
```bash
blew sub -n "Thingy" fff1                        # Stream indefinitely (Ctrl-C to stop)
blew sub -n "Thingy" -f uint16le -d 30 fff1      # 30-second capture as uint16
blew -o kv sub -n "Thingy" -c 100 2A37           # Capture 100 events, kv output
blew -o kv sub -n "Thingy" fff1 >> data.log      # Append to a log file
```

---

## Interactive REPL

Run `blew` with no arguments (or with global options but no subcommand) to start the interactive REPL:

```bash
blew
blew -v           # Start verbose REPL
```

The REPL provides:
- **Line editing** — cursor movement, Ctrl-A/E, Ctrl-W, etc.
- **Persistent history** — saved to `~/.config/blew/history` across sessions
- **Tab completion** — commands, known UUIDs after GATT discovery, and format names

### REPL commands

| Command | Description |
|---------|-------------|
| `scan [options]` | Scan for devices |
| `connect [<id>]` | Connect to a device |
| `disconnect` | Disconnect |
| `status` | Show connection status |
| `gatt svcs\|tree\|chars\|desc\|info` | GATT inspection |
| `read [-f <fmt>] <uuid>` | Read a characteristic |
| `write [-f <fmt>] [-r\|-w] <uuid> <data>` | Write to a characteristic |
| `sub [-f <fmt>] [-d <s>] [-c <n>] <uuid>` | Subscribe to notifications (Ctrl-C to stop) |
| `sub [-b] [-f <fmt>] [-d <s>] [-c <n>] <uuid>` | Subscribe in background; prompt remains available |
| `sub stop [<uuid>]` | Stop one or all background subscriptions |
| `sub status` | List active background subscriptions |
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

The `exec` subcommand runs a semicolon-separated sequence of commands in a single process, sharing one connection lifecycle. Commands are parsed identically to the REPL. The first command that requires a connection triggers an automatic connect; subsequent commands reuse it.

```bash
blew exec "connect -n Thingy; gatt tree; read -f uint8 2A19"
```

**Flags:**

| Flag | Description |
|------|-------------|
| `-k, --keep-going` | Continue after a command error; exit with the first non-zero code seen. |
| `--dry-run` | Print parsed steps without executing them. |

**Examples:**
```bash
# Connect by name, read a value
blew exec "connect -n Thingy; read -f uint8 2A19"

# Keep going after errors
blew exec -k "read fff1; read fff9"

# Preview what would run
blew exec --dry-run "connect -n Thingy; gatt tree; read -f uint8 2A19"
```

---

## Output and logging

### stdout vs stderr

| Stream | Content |
|--------|---------|
| stdout | Command results — tables, values, notification lines |
| stderr | Operational messages (errors, verbose info, debug) |

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

Pass `-o kv` to get machine-parseable output. Each record is one line of space-separated `key=value` pairs (values containing spaces are quoted). Easy to process with `awk`, `grep`, or any log parser:

```
id=F3C2A1B0-... name=Thingy rssi=-58 services=180F,180A
char=2A19 name="Battery Level" value=57 fmt=uint8
ts=2026-02-21T12:34:56.789Z char=fff1 value=deadbeef
```

The `name=` field is included when the UUID is a known Bluetooth SIG UUID. It is omitted for custom or vendor UUIDs.

```bash
blew -n "Thingy" -o kv sub -d 60 fff1 | awk -F'value=' '{print $2}'
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `2` | Not found / no matching device |
| `3` | Bluetooth unavailable or permission denied |
| `4` | Timeout |
| `5` | Operation failed (connect / GATT / read / write / subscribe) |
| `6` | Invalid arguments |

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

Starts advertising and runs until interrupted (Ctrl-C). Events (reads, writes, subscriptions) are logged to stdout.

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
`format` accepts the same values as `--format` in `read`/`write`: `hex` (default), `utf8`, `uint8`, `uint16le`, `uint32le`, `float32le`, `base64`, `raw`.

**Examples:**

```bash
# Advertise a name + service UUID (scanner-visible, no GATT characteristics)
blew periph adv -n "My Sensor" -S 180F

# Multiple service UUIDs
blew periph adv -n "My Sensor" -S 180F -S 180A

# Full GATT server from a config file
blew periph adv --config device.json

# Config file with name override
blew periph adv -n "Override Name" --config device.json
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
| `-o, --save <file>` | Save the cloned GATT structure to a JSON config file for later reuse. |

**Clone scope:**
- Cloned: advertised name, service UUIDs, full GATT structure, initial characteristic values (for readable characteristics).
- Not cloned: manufacturer data, service data in ADV payload, ADV timing.

**Examples:**

```bash
blew periph clone -n "Heart Rate Monitor"
blew periph clone -i F3C2A1B0-... --save hr-monitor.json
```

#### REPL-only periph commands

In REPL and `exec` mode, `periph adv` and `periph clone` run in two phases. The startup phase (configure + start advertising) is synchronous and confirms the peripheral came up. Once advertising is confirmed, the event loop runs as a background task and the prompt is returned immediately. This makes `periph stop`, `periph set`, and `periph notify` usable in the same session:

| Command | Description |
|---------|-------------|
| `periph stop` | Stop advertising and cancel the background event task. |
| `periph set [-f <fmt>] <char> <val>` | Update a characteristic's stored value. |
| `periph notify [-f <fmt>] <char> <val>` | Update value and push a notification to all subscribers. |
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

```bash
blew exec "periph adv -n 'My Device' --config device.json; periph set 2A19 ff; periph notify 2A19 ff"
```

---

## Recipes

### Find a device in a crowded environment
```bash
blew scan -n "Sensor" -S 180F -R -65 -t 10
```

### Capture sensor data to a file
```bash
blew -o kv sub -n "Sensor" -f uint16le -d 300 fff1 >> sensor.log
```

### Quick GATT audit in one line
```bash
blew gatt tree -n "Thingy" -d
```

### Inspect device info characteristics with values
```bash
blew gatt chars -n "Thingy" -r 180A
```

### Read with scripting
```bash
value=$(blew read -n "Thingy" -f uint8 2A19)
echo "Battery: ${value}%"
```

### Use `--pick only` to guard against accidental multi-match
```bash
blew read -n "Thingy" -p only -f uint8 2A19
# Errors out if more than one "Thingy" is nearby
```

