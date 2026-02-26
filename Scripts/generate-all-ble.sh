#!/bin/bash
# generate-all-ble.sh <names-data-dir> <sig-dir> <output-dir>
#
# Wrapper that runs both BLE code generation scripts in sequence.
set -e

NAMES_DATA_DIR="$1"
SIG_DIR="$2"
OUTPUT_DIR="$3"

SCRIPTS_DIR="$(dirname "$0")"

ruby "$SCRIPTS_DIR/generate-ble-names.rb" \
    "$NAMES_DATA_DIR" \
    "$OUTPUT_DIR/BLENames.generated.swift"

ruby "$SCRIPTS_DIR/generate-ble-characteristics.rb" \
    "$SIG_DIR" \
    "$OUTPUT_DIR/BLECharacteristics.generated.swift"
