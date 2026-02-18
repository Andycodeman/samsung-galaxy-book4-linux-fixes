#!/bin/bash
# Uninstall the Galaxy Book5 webcam fix
# Removes DKMS module, config files, and environment settings added by install.sh
# Does NOT uninstall distro packages (libcamera, pipewire-libcamera, etc.)

set -e

VISION_DRIVER_VER="1.0.0"
SRC_DIR="/usr/src/vision-driver-${VISION_DRIVER_VER}"

echo "=============================================="
echo "  Samsung Galaxy Book5 Webcam Fix Uninstaller"
echo "=============================================="
echo ""

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# [1/6] Remove DKMS module
echo "[1/6] Removing vision-driver DKMS module..."
if dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "vision-driver"; then
    sudo dkms remove "vision-driver/${VISION_DRIVER_VER}" --all 2>/dev/null || true
    echo "  ✓ DKMS module removed"
else
    echo "  ✓ DKMS module not installed (nothing to remove)"
fi

# [2/6] Remove DKMS source
echo "[2/6] Removing DKMS source directory..."
if [[ -d "$SRC_DIR" ]]; then
    sudo rm -rf "$SRC_DIR"
    echo "  ✓ Removed ${SRC_DIR}"
else
    echo "  ✓ Source directory not present"
fi

# [3/6] Remove modprobe config
echo "[3/6] Removing module configuration..."
sudo rm -f /etc/modprobe.d/intel-ipu7-camera.conf
# Also remove old name from earlier versions of the installer
sudo rm -f /etc/modprobe.d/intel-cvs-camera.conf
echo "  ✓ Module configuration removed"

# [4/6] Remove modules-load config
echo "[4/6] Removing module autoload configuration..."
sudo rm -f /etc/modules-load.d/intel-ipu7-camera.conf
# Also remove old name from earlier versions of the installer
sudo rm -f /etc/modules-load.d/intel-cvs.conf
echo "  ✓ Module autoload configuration removed"

# [5/6] Remove udev rules
echo "[5/6] Removing udev rules..."
sudo rm -f /etc/udev/rules.d/90-hide-ipu7-v4l2.rules
sudo udevadm control --reload-rules 2>/dev/null || true
echo "  ✓ Udev rules removed"

# [6/6] Remove environment configs
echo "[6/6] Removing environment configuration..."
sudo rm -f /etc/environment.d/libcamera-ipa.conf
sudo rm -f /etc/profile.d/libcamera-ipa.sh
echo "  ✓ Removed libcamera environment files"

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo ""
echo "  Note: Distro packages (libcamera, pipewire-libcamera, etc.) were NOT"
echo "  removed — you may need them for other purposes. Remove manually if desired."
echo ""
echo "  Reboot to fully restore the original state."
echo "=============================================="
