#!/bin/bash
set -e

DKMS_NAME="max98390-hda"
DKMS_VER="1.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VER}"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

echo "=== MAX98390 HDA Speaker Driver Installer ==="
echo "Samsung Galaxy Book4 Ultra (and similar)"
echo ""

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

# Check prerequisites
if ! command -v dkms >/dev/null 2>&1; then
    echo "ERROR: dkms not installed. Run: sudo apt install dkms" >&2
    exit 1
fi

# i2c-tools is needed for dynamic amp detection on boot
if ! command -v i2cget >/dev/null 2>&1; then
    echo "Installing i2c-tools (needed for amplifier detection)..."
    apt-get install -y i2c-tools >/dev/null 2>&1 || {
        echo "ERROR: Failed to install i2c-tools. Run: sudo apt install i2c-tools" >&2
        exit 1
    }
fi

# Check hardware: MAX98390 must be present via ACPI
if ! ls /sys/bus/acpi/devices/MAX98390:* &>/dev/null && \
   ! grep -rq "MAX98390" /sys/bus/i2c/devices/*/name 2>/dev/null; then
    if $FORCE; then
        echo "WARNING: No MAX98390 detected — installing anyway (--force)"
    else
        echo "ERROR: No MAX98390 amplifier detected on this system." >&2
        echo "This driver is for Samsung Galaxy Book4 (and similar) laptops" >&2
        echo "with MAX98390 HDA speaker amplifiers." >&2
        echo "" >&2
        echo "Use --force to install anyway." >&2
        exit 1
    fi
fi

# Remove old version if present
if dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}"; then
    echo "Removing existing DKMS module..."
    dkms remove "${DKMS_NAME}/${DKMS_VER}" --all 2>/dev/null || true
fi

# Copy source to DKMS tree
echo "Installing source to ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}/src"
cp -a "$(dirname "$0")/src/"*.{c,h} "${SRC_DIR}/src/"
cp -a "$(dirname "$0")/src/Makefile" "${SRC_DIR}/src/"
cp -a "$(dirname "$0")/dkms.conf" "${SRC_DIR}/"

# Register, build, and install with DKMS
echo "Building DKMS module..."
dkms add "${DKMS_NAME}/${DKMS_VER}"
dkms build "${DKMS_NAME}/${DKMS_VER}"
dkms install "${DKMS_NAME}/${DKMS_VER}"

# Install helper scripts and systemd services
echo "Installing services..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
install -m 755 "${SCRIPT_DIR}/max98390-hda-i2c-setup.sh" /usr/local/sbin/
install -m 755 "${SCRIPT_DIR}/max98390-hda-check-upstream.sh" /usr/local/sbin/
install -m 644 "${SCRIPT_DIR}/max98390-hda-i2c-setup.service" /etc/systemd/system/
install -m 644 "${SCRIPT_DIR}/max98390-hda-check-upstream.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable max98390-hda-i2c-setup.service
systemctl enable max98390-hda-check-upstream.service

# Module autoload
echo "Configuring module autoload..."
cat > /etc/modules-load.d/max98390-hda.conf << 'EOF'
# MAX98390 HDA speaker amplifier driver (Galaxy Book4)
snd-hda-scodec-max98390
snd-hda-scodec-max98390-i2c
EOF

echo ""
echo "=== Installation complete ==="
echo "The driver will auto-load and auto-rebuild on kernel updates."
echo "Reboot to verify everything works on a fresh boot."
echo ""
echo "To test now (without reboot):"
echo "  sudo systemctl start max98390-hda-i2c-setup.service"
echo "To uninstall:"
echo "  sudo bash $(cd "$(dirname "$0")" && pwd)/uninstall.sh"
