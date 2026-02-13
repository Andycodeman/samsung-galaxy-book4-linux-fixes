#!/bin/bash
# Dynamically find the I2C bus for MAX98390 and create devices.
# Works across Galaxy Book4 Pro/Pro 360/Ultra/Book5 models.

ACTION="${1:-start}"

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

BUS=$(find_i2c_bus)
if [ -z "$BUS" ]; then
    echo "max98390-hda: No MAX98390 ACPI device found on I2C bus" >&2
    exit 0  # Not an error - hardware just isn't present
fi

SYSFS="/sys/bus/i2c/devices/i2c-${BUS}"

case "$ACTION" in
    start)
        # ACPI already created a device at the first address (0x38).
        # Create devices for the remaining 3 amplifiers.
        for addr in 0x39 0x3c 0x3d; do
            echo "max98390-hda $addr" > "$SYSFS/new_device" 2>/dev/null || true
        done
        ;;
    stop)
        for addr in 0x3d 0x3c 0x39; do
            echo "$addr" > "$SYSFS/delete_device" 2>/dev/null || true
        done
        ;;
esac
