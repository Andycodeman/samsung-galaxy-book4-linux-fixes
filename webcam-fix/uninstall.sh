#!/bin/bash
# Uninstall the Galaxy Book4 webcam fix
# Removes config files, packages, and PPA added by install.sh

set -e

echo "=============================================="
echo "  Samsung Galaxy Book4 Webcam Fix Uninstaller"
echo "=============================================="
echo ""

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# Stop the relay service
echo "[1/4] Stopping v4l2-relayd service..."
sudo systemctl stop v4l2-relayd 2>/dev/null || true
sudo systemctl disable v4l2-relayd 2>/dev/null || true

# Remove config files
echo "[2/4] Removing configuration files..."
sudo rm -f /etc/modules-load.d/ivsc.conf
sudo rm -f /etc/v4l2-relayd
sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-v4l2-ipu6-camera.conf

# Remove packages
echo "[3/4] Removing packages..."
sudo apt remove -y libcamhal-ipu6epmtl v4l2-relayd 2>/dev/null || true
sudo apt autoremove -y 2>/dev/null || true

# Remove PPA
echo "[4/4] Removing Intel IPU6 PPA..."
sudo add-apt-repository -y --remove ppa:oem-solutions-group/intel-ipu6 2>/dev/null || true

# Restart WirePlumber to pick up removed config
systemctl --user restart wireplumber 2>/dev/null || true

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo "  Reboot to fully restore the original state."
echo "=============================================="
