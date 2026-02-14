#!/bin/bash
# Dynamically find the I2C bus for MAX98390 and create devices.
# Works across Galaxy Book4 Pro/Pro 360/Ultra/Book5 models.
# Supports both 2-amp (e.g., Book 2 Pro SE) and 4-amp (e.g., Ultra) configurations.

ACTION="${1:-start}"

# Known MAX98390 amplifier addresses across all Samsung Galaxy Book models
ALL_ADDRS="0x38 0x39 0x3c 0x3d"

# Find the I2C adapter that has the ACPI MAX98390 device
find_i2c_bus() {
    local dev_path parent_name bus_num
    for dev in /sys/bus/i2c/devices/*MAX98390*; do
        [ -e "$dev" ] || continue
        dev_path="$(readlink -f "$dev")"
        # Try parent directory basename (handles .../i2c-N/device)
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(echo "$parent_name" | sed -n 's/^i2c-\([0-9]\+\)$/\1/p')"
        if [ -n "$bus_num" ]; then
            echo "$bus_num"
            return 0
        fi
        # Fallback: extract bus number from anywhere in the resolved path
        # Matches the last /i2c-N/ component before the device itself
        bus_num="$(echo "$dev_path" | sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p')"
        if [ -n "$bus_num" ]; then
            echo "$bus_num"
            return 0
        fi
    done
    # Fallback: search ACPI for the I2C controller hosting MAX98390
    for acpi in /sys/bus/acpi/devices/MAX98390:*; do
        [ -e "$acpi/physical_node" ] || continue
        dev_path="$(readlink -f "$acpi/physical_node")"
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(echo "$parent_name" | sed -n 's/^i2c-\([0-9]\+\)$/\1/p')"
        if [ -n "$bus_num" ]; then
            echo "$bus_num"
            return 0
        fi
        bus_num="$(echo "$dev_path" | sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p')"
        if [ -n "$bus_num" ]; then
            echo "$bus_num"
            return 0
        fi
    done
    return 1
}

# Probe which amplifier addresses actually respond on the I2C bus.
# Returns only addresses with real hardware (avoids creating ghost devices
# on 2-amp systems like the Galaxy Book 2 Pro SE).
find_present_addrs() {
    local bus="$1" addr present=""
    for addr in $ALL_ADDRS; do
        # Skip ACPI-created device (0x38) — already bound
        [ "$addr" = "0x38" ] && continue
        # Check if device already exists (driver bound)
        if [ -e "/sys/bus/i2c/devices/${bus}-00${addr#0x}" ]; then
            continue
        fi
        # Probe the address with a read — if the chip is there, it will ACK
        if i2cget -y "$bus" "$addr" 0x00 b >/dev/null 2>&1; then
            present="$present $addr"
        fi
    done
    echo "$present"
}

BUS=$(find_i2c_bus)
if [ -z "$BUS" ]; then
    echo "max98390-hda: No MAX98390 ACPI device found on I2C bus" >&2
    exit 0  # Not an error - hardware just isn't present
fi

SYSFS="/sys/bus/i2c/devices/i2c-${BUS}"

case "$ACTION" in
    start)
        # ACPI already created a device at the first address (0x38).
        # Probe the bus to find which other amplifiers are present.
        ADDRS=$(find_present_addrs "$BUS")
        if [ -z "$ADDRS" ]; then
            echo "max98390-hda: No additional amplifiers found on bus $BUS (1-amp or already bound)"
        else
            count=$(echo "$ADDRS" | wc -w)
            echo "max98390-hda: Found $count additional amplifier(s) on bus $BUS:$ADDRS"
            for addr in $ADDRS; do
                echo "max98390-hda $addr" > "$SYSFS/new_device" 2>/dev/null || true
            done
        fi
        ;;
    stop)
        for addr in 0x3d 0x3c 0x39; do
            echo "$addr" > "$SYSFS/delete_device" 2>/dev/null || true
        done
        ;;
esac
