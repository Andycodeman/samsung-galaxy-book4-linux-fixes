#!/bin/bash
# Uninstall the Galaxy Book4 webcam fix
# Removes all config files, packages, and PPA added by install.sh

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
echo "[1/9] Stopping v4l2-relayd service..."
sudo systemctl stop v4l2-relayd@default 2>/dev/null || true
sudo systemctl stop v4l2-relayd 2>/dev/null || true
sudo systemctl disable v4l2-relayd 2>/dev/null || true

# Remove config files
echo "[2/9] Removing configuration files..."
sudo rm -f /etc/modules-load.d/ivsc.conf
sudo rm -f /etc/modprobe.d/ivsc-camera.conf
sudo rm -f /etc/modprobe.d/v4l2loopback.conf
sudo rm -f /etc/v4l2-relayd.d/default.conf
sudo rm -f /etc/udev/rules.d/90-hide-ipu6-v4l2.rules
# Clean up WirePlumber rule (older versions of install.sh created this; no longer needed)
sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-v4l2-ipu6-camera.conf
# Clean up legacy config path (older versions of install.sh wrote here)
sudo rm -f /etc/v4l2-relayd
echo "  ✓ Configuration files removed"

# Remove v4l2-relayd systemd override
echo "[3/9] Removing systemd overrides..."
sudo rm -rf /etc/systemd/system/v4l2-relayd@default.service.d
sudo systemctl daemon-reload
echo "  ✓ Systemd overrides removed"

# Remove watchdog (legacy) and resolution detection
echo "[4/9] Removing watchdog and resolution detection..."
sudo systemctl stop v4l2-relayd-watchdog.timer 2>/dev/null || true
sudo systemctl disable v4l2-relayd-watchdog.timer 2>/dev/null || true
sudo systemctl stop v4l2-relayd-watchdog.service 2>/dev/null || true
sudo rm -f /usr/local/sbin/v4l2-relayd-watchdog.sh
sudo rm -f /usr/local/sbin/v4l2-relayd-detect-resolution.sh
sudo rm -f /run/v4l2-relayd-resolution.env
sudo rm -f /etc/systemd/system/v4l2-relayd-watchdog.service
sudo rm -f /etc/systemd/system/v4l2-relayd-watchdog.timer
sudo rm -rf /run/v4l2-relayd-watchdog
sudo systemctl daemon-reload
echo "  ✓ Watchdog removed"

# Remove upstream detection service
echo "[5/9] Removing upstream detection service..."
sudo systemctl stop v4l2-relayd-check-upstream.service 2>/dev/null || true
sudo systemctl disable v4l2-relayd-check-upstream.service 2>/dev/null || true
sudo rm -f /usr/local/sbin/v4l2-relayd-check-upstream.sh
sudo rm -f /etc/systemd/system/v4l2-relayd-check-upstream.service
sudo systemctl daemon-reload
echo "  ✓ Upstream detection service removed"

# Remove IVSC modules from initramfs and rebuild
echo "[6/9] Removing IVSC modules from initramfs..."
if [[ -f /etc/initramfs-tools/modules ]]; then
    INITRAMFS_CHANGED=false
    for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
        if grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null; then
            sudo sed -i "/^${mod}$/d" /etc/initramfs-tools/modules
            INITRAMFS_CHANGED=true
        fi
    done
    if $INITRAMFS_CHANGED; then
        echo "  Rebuilding initramfs..."
        sudo update-initramfs -u
        echo "  ✓ IVSC modules removed from initramfs"
    else
        echo "  ✓ IVSC modules not in initramfs (nothing to remove)"
    fi
else
    echo "  ✓ No initramfs modules file found"
fi

# Reload udev rules
sudo udevadm control --reload-rules 2>/dev/null || true

# Remove packages
echo "[7/9] Removing packages..."
sudo apt remove -y libcamhal-ipu6epmtl v4l2-relayd 2>/dev/null || true
sudo apt autoremove -y 2>/dev/null || true

# Remove PPA
echo "[8/9] Removing Intel IPU6 PPA..."
sudo add-apt-repository -y --remove ppa:oem-solutions-group/intel-ipu6 2>/dev/null || true

# Restart WirePlumber to pick up removed config
echo "[9/9] Restarting WirePlumber..."
systemctl --user restart wireplumber 2>/dev/null || true

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo "  Reboot to fully restore the original state."
echo "=============================================="
