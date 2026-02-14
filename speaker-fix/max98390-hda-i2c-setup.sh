#!/bin/bash
# Dynamically find the I2C bus for MAX98390 and create devices.
# Works across Galaxy Book4 Pro/Pro 360/Ultra/Book5 models.
# Supports both 2-amp (e.g., Book 2 Pro SE) and 4-amp (e.g., Ultra) configurations.

ACTION="${1:-start}"

# Known MAX98390 amplifier addresses across all Samsung Galaxy Book models
ALL_ADDRS="0x38 0x39 0x3c 0x3d"

# Find the I2C adapter that has the ACPI MAX98390 device
find_i2c_bus() {
    local acpi_link bus_path
    for dev in /sys/bus/i2c/devices/i2c-MAX98390:00 /sys/bus/i2c/devices/*-MAX98390:00; do
        [ -e "$dev" ] || continue
        # Follow the device to find its parent adapter
        bus_path="$(readlink -f "$dev/..")"
        # Extract adapter number from path (e.g., "i2c-2" -> "2")
        basename "$bus_path" | sed -n 's/^i2c-//p'
        return 0
    done
    # Fallback: search ACPI for the I2C controller hosting MAX98390
    for acpi in /sys/bus/acpi/devices/MAX98390:00; do
        [ -e "$acpi/physical_node" ] || continue
        bus_path="$(readlink -f "$acpi/physical_node/..")"
        basename "$bus_path" | sed -n 's/^i2c-//p'
        return 0
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
