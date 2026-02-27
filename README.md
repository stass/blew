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

These options apply to all commands and control device targeting, output, and behavior. They must be placed **before** the subcommand name:

```bash
blew [global-options] <command> [command-options]
```

### Output and verbosity

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Increase log verbosity. Repeatable: `-vv` for debug-level detail. |
| `-o, --out <format>` | Output format for results: `text` (default, human-readable) or `kv` (key=value, one record per line — easier to parse). |
| `-t, --timeout <sec>` | Timeout in seconds for BLE operations. |
| `-h, --help` | Show help and exit. |
| `--version` | Show version and exit. |

### Device targeting

Use `--id` to target an explicit device, or combine selectors to let blew find a match automatically.

| Flag | Description |
|------|-------------|
| `-i, --id <device-id>` | Target a specific device by its identifier. |
| `-n, --name <substring>` | Filter by device name (substring match). |
| `-S, --service <uuid>` | Filter by advertised service UUID. Repeatable. |
| `-m, --manufacturer <id>` | Filter by manufacturer ID. |
| `-r, --rssi-min <dBm>` | Minimum RSSI threshold (e.g. `-r -70`). |
| `-p, --pick <strategy>` | How to pick when multiple devices match: `strongest` (default, highest RSSI), `first` (first seen), `only` (error if multiple match). |

### Script execution

| Flag | Description |
|------|-------------|
| `-x, --exec "<commands>"` | Run a semicolon-separated sequence of commands within a single connection lifecycle. |
| `-k, --keep-going` | With `--exec`: continue after a command error; exit with the first non-zero code seen. |
| `--dry-run` | With `--exec`: print parsed steps without executing them. |

---

## Commands

### `scan` — Scan for BLE devices

```
blew [global-options] scan
```

Scans for advertising BLE peripherals and prints a table of discovered devices. Timeout defaults to 5 seconds.

**Relevant global options:** `-t`, `-n`, `-S`, `-m`, `-r`, `-o`, `-v`

**Flags:**

| Flag | Description |
|------|-------------|
| `-w, --watch` | Continuously scan and show a live-updating device list. Runs until Ctrl-C or `-t` expires. Requires a TTY in text mode; use `-o kv` for piped output. |

**Output columns (text):** ID, Name, RSSI, Signal (visual bar), Services

Standard Bluetooth SIG service UUIDs in the Services column are shown with their human-readable name: e.g. `180F (Battery Service), 180A (Device Information)`.

**Examples:**
```bash
blew scan                          # Scan for 5 seconds
blew -t 10 scan                    # Scan for 10 seconds
blew scan --watch                  # Continuously scan until Ctrl-C
blew -t 30 scan --watch            # Watch for 30 seconds then stop
blew -n "Heart" scan --watch       # Watch for Heart Rate devices
blew -S 180D -r -65 scan           # Heart Rate service, RSSI ≥ -65 dBm
blew -o kv scan                    # Machine-readable output
blew -o kv scan --watch            # Stream device updates (piping-friendly)
```

---

### `connect` — Connect to a device

```
blew [global-options] connect [<device-id>]
```

Explicitly connects to a BLE device and exits. Useful for testing connectivity or pre-warming a connection in `--exec` scripts. The device can be specified by positional argument, `--id`, or device-targeting selectors (the tool will scan briefly to resolve them).

For `gatt`, `read`, `write`, and `sub` you do not need to run `connect` first — those commands connect automatically using the same device-targeting options.

The connection is automatically closed on exit.

**Examples:**
```bash
blew connect F3C2A1B0-...          # Test connectivity to an explicit ID
blew -n "Thingy" connect           # Test connectivity by name
blew -S 180F connect               # Connect to device advertising Battery Service
```

---

### `gatt` — Inspect GATT structure

`gatt` connects automatically if no connection is active. Specify the target device with `--id`, `--name`, or other device-targeting options.

All UUID outputs include human-readable names for standard Bluetooth SIG UUIDs. Custom or vendor UUIDs are shown as-is.

#### `gatt svcs` — List services

```
blew [global-options] gatt svcs
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
blew [global-options] gatt tree [-d] [-r]
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
blew [global-options] gatt chars [-r] <service-uuid>
```

Output columns: UUID, Name, Properties.

| Flag | Description |
|------|-------------|
| `-r, --read` | Read and display values for all readable characteristics. Adds a Value column to the table; non-readable characteristics get an empty cell. |

#### `gatt desc` — List descriptors for a characteristic

```
blew [global-options] gatt desc <char-uuid>
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
blew -n "Thingy" gatt tree
blew -n "Thingy" gatt tree -d        # Include descriptors
blew -n "Thingy" gatt tree -r        # Read values for readable characteristics
blew -n "Thingy" gatt tree -dr       # Descriptors + values
blew -n "Thingy" gatt chars 180F
blew -n "Thingy" gatt chars -r 180A  # Read values for Device Information
blew -n "Thingy" gatt desc 2A19
```

---

### `read` — Read a characteristic value

```
blew [global-options] read [-f <format>] <char-uuid>
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
blew -n "Thingy" read -f uint8 2A19     # Battery level as integer
blew -n "Thingy" read -f utf8 2A29      # Manufacturer name string
blew -n "Thingy" read fff1              # Raw characteristic as hex
```

---

### `write` — Write to a characteristic

```
blew [global-options] write [-f <format>] [-r|-w] <char-uuid> <data>
```

Writes data to a characteristic. Connects automatically if no connection is active. Write mode (with or without response) is auto-selected based on the characteristic's properties unless overridden.

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Data format (same values as `read`). Default: `hex`. |
| `-r, --with-response` | Force write-with-response. |
| `-w, --without-response` | Force write-without-response. |

**Examples:**
```bash
blew -n "Thingy" write fff1 "deadbeef"           # Write hex bytes
blew -n "Thingy" write -f uint8 -r 2A06 1        # Write uint8 with response
blew -n "Thingy" write -f utf8 fff2 "hello"      # Write a UTF-8 string
```

---

### `sub` — Subscribe to notifications or indications

```
blew [global-options] sub [-f <format>] [-d <sec>] [-c <count>] [--notify|--indicate] <char-uuid>
```

Subscribes to a characteristic and streams received values to stdout, one event per line. Connects automatically if no connection is active. Stops on `Ctrl-C`, or when a duration/count limit is reached.

| Flag | Description |
|------|-------------|
| `-f, --format <fmt>` | Value format (same values as `read`). Default: `hex`. |
| `-d, --duration <sec>` | Stop after this many seconds. |
| `-c, --count <n>` | Stop after receiving this many notifications. |
| `--notify` | Force notify mode. (Defined; not yet wired through — auto mode is used.) |
| `--indicate` | Force indicate mode. (Defined; not yet wired through — auto mode is used.) |

With `--out kv`, each line includes `ts=`, `char=`, and `value=` fields.

**Examples:**
```bash
blew -n "Thingy" sub fff1                        # Stream indefinitely (Ctrl-C to stop)
blew -n "Thingy" sub -f uint16le -d 30 fff1      # 30-second capture as uint16
blew -n "Thingy" -o kv sub -c 100 2A37           # Capture 100 events, kv output
blew -n "Thingy" -o kv sub fff1 >> data.log      # Append to a log file
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

## Script execution (`--exec`)

The `-x` / `--exec` flag runs a semicolon-separated sequence of commands in a single process, sharing one connection lifecycle. Commands are parsed identically to the REPL. The first command that requires a connection triggers an automatic connect; subsequent commands reuse it.

```bash
blew -n "Thingy" -x "gatt tree; read -f uint8 2A19"
```

**Error handling:**
- By default, execution stops at the first failing command and exits with that command's exit code.
- `--keep-going` continues past errors; exits with the first non-zero code seen.
- `--dry-run` prints the parsed command sequence without executing anything.

```bash
# Keep going after errors, collect exit code
blew -n "Thingy" -k -x "read fff1; read fff9"

# Preview what would run
blew -n "Thingy" --dry-run -x "gatt tree; read -f uint8 2A19"
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

> **CoreBluetooth peripheral limitations:** Only the local device name and service UUIDs can be advertised. Manufacturer data and other ADV payload fields are not settable from the peripheral API. ADV interval, TX power, and connection parameters are OS-controlled. Standard Bluetooth SIG service UUIDs (e.g. `180F`, `180D`) cannot be emulated on macOS: the short form is rejected by `CBPeripheralManager`, and the full 128-bit Bluetooth Base UUID form is accepted but not normalised internally, so clients do not recognise it as the standard service. Use custom 128-bit UUIDs for all peripheral services.

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
| `battery.json` | Battery-like service — readable/notifiable level characteristic, initial value 100% |
| `heart-rate.json` | Heart-rate-like service — notify measurement, read body sensor location, write control point; plus a device-info service |
| `custom-sensor.json` | Vendor sensor — read/notify value, read/write config register, write-only command endpoint |

> **Note:** Standard Bluetooth SIG service UUIDs cannot be emulated on macOS — see the peripheral limitations note above. All example files use custom 128-bit UUIDs.

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
blew [device-targeting-options] periph clone [--save <file>]
```

Connects to a target device, discovers its full GATT tree, reads all readable characteristic values, disconnects, then starts advertising as a clone.

Use the same global device-targeting options (`--id`, `--name`, `--service`, etc.) to specify the target.

| Flag | Description |
|------|-------------|
| `-o, --save <file>` | Save the cloned GATT structure to a JSON config file for later reuse. |

**Clone scope:**
- Cloned: advertised name, service UUIDs, full GATT structure, initial characteristic values (for readable characteristics).
- Not cloned: manufacturer data, service data in ADV payload, ADV timing.

**Examples:**

```bash
blew -n "Heart Rate Monitor" periph clone
blew -i F3C2A1B0-... periph clone --save hr-monitor.json
```

#### REPL-only periph commands

In the REPL and `--exec` mode, additional `periph` subcommands are available after `periph adv` or `periph clone` has been run:

| Command | Description |
|---------|-------------|
| `periph stop` | Stop advertising. |
| `periph set [-f <fmt>] <char> <val>` | Update a characteristic's stored value. |
| `periph notify [-f <fmt>] <char> <val>` | Update value and push a notification to all subscribers. |
| `periph status` | Show advertising state, service/characteristic counts, subscriber count. |

```
blew> periph adv --config device.json
Advertising "My Device" [180F]
[12:34:56] central A1B2C3 connected

blew> periph notify -f uint8 2A19 42
blew> periph stop
```

---

## Recipes

### Find a device in a crowded environment
```bash
blew -n "Sensor" -S 180F -r -65 -t 10 scan
```

### Capture sensor data to a file
```bash
blew -n "Sensor" -o kv sub -f uint16le -d 300 fff1 >> sensor.log
```

### Quick GATT audit in one line
```bash
blew -n "Thingy" gatt tree -d
```

### Inspect device info characteristics with values
```bash
blew -n "Thingy" gatt chars -r 180A
```

### Read with scripting
```bash
value=$(blew -n "Thingy" read -f uint8 2A19)
echo "Battery: ${value}%"
```

### Use `--pick only` to guard against accidental multi-match
```bash
blew -n "Thingy" -p only read -f uint8 2A19
# Errors out if more than one "Thingy" is nearby
```

---

## Roadmap

| Version | Highlights |
|---------|-----------|
| **v1.0** | Scan, connect, GATT tree, read, write, subscribe, `--exec` scripting, interactive REPL, Bluetooth SIG UUID human-readable names, `scan --watch` live updates |
| **v1.5** | RSSI monitoring, improved tab completion, custom/vendor UUID name mappings |
| **v2.0 (current)** | Peripheral mode — `periph adv` GATT server, `periph clone` real device mirroring, interactive REPL peripheral commands |
