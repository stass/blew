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

`--recurse-submodules` is required — the Bluetooth SIG name database is included as a git submodule at `Vendor/bluetooth-numbers-database`. The Swift build generates the name mapping automatically from the submodule data.

On first run, macOS will prompt for Bluetooth permission. Grant it in **System Settings → Privacy & Security → Bluetooth**.

---

## Quick start

```bash
# Scan for nearby devices
blew scan

# Print the GATT tree of a device (connects automatically)
blew -n "Thingy" gatt tree

# Read a characteristic (battery level)
blew -n "Thingy" read -c 2A19 -F uint8

# Subscribe to notifications for 10 seconds
blew -n "Thingy" sub -c fff1 -D 10

# Run a multi-step procedure in one invocation
blew -n "Thingy" -x "gatt tree; read -c 2A19 -F uint8"

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

**Output columns (text):** ID, Name, RSSI, Signal (visual bar), Services

Standard Bluetooth SIG service UUIDs in the Services column are shown with their human-readable name: e.g. `180F (Battery Service), 180A (Device Information)`.

**Examples:**
```bash
blew scan                          # Scan for 5 seconds
blew -t 10 scan                    # Scan for 10 seconds
blew -n "Heart" scan               # Filter by name
blew -S 180D -r -65 scan           # Heart Rate service, RSSI ≥ -65 dBm
blew -o kv scan                    # Machine-readable output
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
blew [global-options] gatt tree [-d]
```

Prints services and their characteristics with properties (read / write / notify / indicate). Standard UUIDs show their name in parentheses.

```
Service: 180F (Battery Service)
  Char: 2A19 (Battery Level) [read,notify]
    Desc: 2902 (Client Characteristic Configuration)
Service: FFF0
  Char: FFF1 [read,write-without-response,notify]
```

| Flag | Description |
|------|-------------|
| `-d, --descriptors` | Also show descriptors for each characteristic. |

#### `gatt chars` — List characteristics for a service

```
blew [global-options] gatt chars -S <service-uuid>
```

Output columns: UUID, Name, Properties.

| Flag | Description |
|------|-------------|
| `-S, --service <uuid>` | Service UUID to inspect. Required. |

#### `gatt desc` — List descriptors for a characteristic

```
blew [global-options] gatt desc -c <char-uuid>
```

Output columns: UUID, Name.

| Flag | Description |
|------|-------------|
| `-c, --char <uuid>` | Characteristic UUID to inspect. Required. |

**Examples:**
```bash
blew -n "Thingy" gatt tree
blew -n "Thingy" gatt tree -d        # Include descriptors
blew -n "Thingy" gatt chars -S 180F
blew -n "Thingy" gatt desc -c 2A19
```

---

### `read` — Read a characteristic value

```
blew [global-options] read -c <char-uuid> [-F <format>]
```

Reads the value of a characteristic and prints it in the requested format. Connects automatically if no connection is active.

| Flag | Description |
|------|-------------|
| `-c, --char <uuid>` | Characteristic UUID to read. Required. |
| `-F, --format <fmt>` | Output format (see table below). Default: `hex`. |

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
blew -n "Thingy" read -c 2A19 -F uint8     # Battery level as integer
blew -n "Thingy" read -c 2A29 -F utf8      # Manufacturer name string
blew -n "Thingy" read -c fff1              # Raw characteristic as hex
```

---

### `write` — Write to a characteristic

```
blew [global-options] write -c <char-uuid> -d <data> [-F <format>] [-R|-W]
```

Writes data to a characteristic. Connects automatically if no connection is active. Write mode (with or without response) is auto-selected based on the characteristic's properties unless overridden.

| Flag | Description |
|------|-------------|
| `-c, --char <uuid>` | Characteristic UUID to write. Required. |
| `-d, --data <value>` | Data to write. Required. |
| `-F, --format <fmt>` | Data format (same values as `read`). Default: `hex`. |
| `-R, --with-response` | Force write-with-response. |
| `-W, --without-response` | Force write-without-response. |

**Examples:**
```bash
blew -n "Thingy" write -c fff1 -d "deadbeef"         # Write hex bytes
blew -n "Thingy" write -c 2A06 -d 1 -F uint8 -R      # Write uint8 with response
blew -n "Thingy" write -c fff2 -d "hello" -F utf8    # Write a UTF-8 string
```

---

### `sub` — Subscribe to notifications or indications

```
blew [global-options] sub -c <char-uuid> [-F <format>] [-D <sec>] [-C <count>] [--notify|--indicate]
```

Subscribes to a characteristic and streams received values to stdout, one event per line. Connects automatically if no connection is active. Stops on `Ctrl-C`, or when a duration/count limit is reached.

| Flag | Description |
|------|-------------|
| `-c, --char <uuid>` | Characteristic UUID to subscribe to. Required. |
| `-F, --format <fmt>` | Value format (same values as `read`). Default: `hex`. |
| `-D, --duration <sec>` | Stop after this many seconds. |
| `-C, --count <n>` | Stop after receiving this many notifications. |
| `--notify` | Force notify mode. (Defined; not yet wired through — auto mode is used.) |
| `--indicate` | Force indicate mode. (Defined; not yet wired through — auto mode is used.) |

With `--out kv`, each line includes `ts=`, `char=`, and `value=` fields.

**Examples:**
```bash
blew -n "Thingy" sub -c fff1                      # Stream indefinitely (Ctrl-C to stop)
blew -n "Thingy" sub -c fff1 -F uint16le -D 30   # 30-second capture as uint16
blew -n "Thingy" -o kv sub -c 2A37 -C 100        # Capture 100 events, kv output
blew -n "Thingy" -o kv sub -c fff1 >> data.log   # Append to a log file
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
| `gatt svcs\|tree\|chars\|desc` | GATT inspection |
| `read -c <uuid> [-F <fmt>]` | Read a characteristic |
| `write -c <uuid> -d <data> [-F <fmt>]` | Write to a characteristic |
| `sub -c <uuid> [options]` | Subscribe to notifications (Ctrl-C to stop) |
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
Service: 180F (Battery Service)
  Char: 2A19 (Battery Level) [read,notify]
Service: 180A (Device Information)
  Char: 2A29 (Manufacturer Name String) [read]

blew> read -c 2A19 -F uint8
87

blew> sub -c 2A19 -F uint8 -C 5
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
blew -n "Thingy" -x "gatt tree; read -c 2A19 -F uint8"
```

**Error handling:**
- By default, execution stops at the first failing command and exits with that command's exit code.
- `--keep-going` continues past errors; exits with the first non-zero code seen.
- `--dry-run` prints the parsed command sequence without executing anything.

```bash
# Keep going after errors, collect exit code
blew -n "Thingy" -k -x "read -c fff1; read -c fff9"

# Preview what would run
blew -n "Thingy" --dry-run -x "gatt tree; read -c 2A19 -F uint8"
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
blew -n "Thingy" -o kv sub -c fff1 -D 60 | awk -F'value=' '{print $2}'
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

## Recipes

### Find a device in a crowded environment
```bash
blew -n "Sensor" -S 180F -r -65 -t 10 scan
```

### Capture sensor data to a file
```bash
blew -n "Sensor" -o kv sub -c fff1 -F uint16le -D 300 >> sensor.log
```

### Quick GATT audit in one line
```bash
blew -n "Thingy" gatt tree -d
```

### Read with scripting
```bash
value=$(blew -n "Thingy" read -c 2A19 -F uint8)
echo "Battery: ${value}%"
```

### Use `--pick only` to guard against accidental multi-match
```bash
blew -n "Thingy" -p only read -c 2A19 -F uint8
# Errors out if more than one "Thingy" is nearby
```

---

## Roadmap

| Version | Highlights |
|---------|-----------|
| **v1.0 (current)** | Scan, connect, GATT tree, read, write, subscribe, `--exec` scripting, interactive REPL, Bluetooth SIG UUID human-readable names |
| **v1.5** | `scan --watch` live updates, RSSI monitoring, improved tab completion, custom/vendor UUID name mappings |
| **v2.0** | Peripheral/virtual device mode — simulate a BLE peripheral and profiles, clone real devices |
