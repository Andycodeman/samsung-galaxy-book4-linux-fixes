#!/bin/bash
# install.sh
# Samsung Galaxy Book4 Ultra webcam fix for Ubuntu 24.04
# Tested on kernel 6.17.0-14-generic (HWE) with IPU6 Meteor Lake / OV02C10
#
# Root cause: IVSC (Intel Visual Sensing Controller) kernel modules don't
# auto-load, breaking the camera initialization chain. Additionally, the
# userspace camera HAL and v4l2 relay service need to be installed.
#
# The IVSC modules must be loaded in the initramfs (before udev probes the
# OV02C10 sensor via ACPI), otherwise the sensor hits -EPROBE_DEFER repeatedly
# and the CSI-2 link starts in an unstable state causing intermittent black
# frames ("Frame sync error" in dmesg).
#
# For full documentation, see: README.md
#
# Usage: ./install.sh

set -e

echo "=============================================="
echo "  Samsung Galaxy Book4 Ultra Webcam Fix"
echo "  Ubuntu 24.04 / Kernel 6.17+ / Meteor Lake"
echo "=============================================="
echo ""

# Check for root
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# Verify hardware
echo "[1/13] Verifying hardware..."
if ! lspci -d 8086:7d19 2>/dev/null | grep -q .; then
    # Check if this is a Lunar Lake system (IPU7) — different driver, not supported
    if lspci 2>/dev/null | grep -qi "Lunar Lake.*IPU\|Intel.*IPU.*7" || \
       lspci -d 8086:645d 2>/dev/null | grep -q . || \
       lspci -d 8086:6457 2>/dev/null | grep -q .; then
        echo "ERROR: This system has Intel IPU7 (Lunar Lake), not IPU6 (Meteor Lake)."
        echo ""
        echo "       This webcam fix is for Meteor Lake systems only (Galaxy Book4 models)."
        echo "       Lunar Lake (Galaxy Book5 models) uses a different camera driver (IPU7)"
        echo "       that is not yet supported by this script."
        echo ""
        echo "       Lunar Lake webcam support requires different kernel drivers and a"
        echo "       different camera HAL. Check the Intel IPU6/IPU7 driver repos for updates:"
        echo "       https://github.com/intel/ipu6-drivers"
    else
        echo "ERROR: Intel IPU6 Meteor Lake (8086:7d19) not found."
        echo "       This script is designed for Samsung Galaxy Book4 laptops with"
        echo "       Intel Meteor Lake processors."
    fi
    exit 1
fi
if ! cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02C1"; then
    echo "ERROR: OV02C10 sensor (OVTI02C1) not found in ACPI."
    exit 1
fi
if ! ls /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin* &>/dev/null; then
    echo "ERROR: IVSC firmware for OV02C10 not found."
    echo "       Expected: /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin.zst"
    exit 1
fi
echo "  ✓ Found IPU6 Meteor Lake and OV02C10 sensor"
echo "  ✓ IVSC firmware present"

# Check kernel module availability
echo ""
echo "[2/13] Checking kernel modules..."
MISSING_MODS=()
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    modpath=$(find /lib/modules/$(uname -r) -name "${mod//-/_}.ko*" -o -name "${mod}.ko*" 2>/dev/null | head -1)
    if [[ -z "$modpath" ]]; then
        modpath=$(find /lib/modules/$(uname -r) -name "$(echo $mod | tr '-' '_').ko*" 2>/dev/null | head -1)
    fi
    if [[ -z "$modpath" ]]; then
        MISSING_MODS+=("$mod")
    fi
done

if [[ ${#MISSING_MODS[@]} -gt 0 ]]; then
    echo "ERROR: Missing kernel modules: ${MISSING_MODS[*]}"
    echo "       Try: sudo apt install linux-modules-ipu6-generic-hwe-24.04"
    exit 1
fi
echo "  ✓ All required kernel modules found"

# Load and persist IVSC modules with correct boot ordering
echo ""
echo "[3/13] Loading IVSC kernel modules..."
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    if ! lsmod | grep -q "$(echo $mod | tr '-' '_')"; then
        sudo modprobe "$mod"
        echo "  Loaded: $mod"
    else
        echo "  Already loaded: $mod"
    fi
done

# Ensure IVSC modules load at boot (before ov02c10 sensor probes)
echo -e "mei-vsc\nmei-vsc-hw\nivsc-ace\nivsc-csi" | sudo tee /etc/modules-load.d/ivsc.conf > /dev/null

# Add softdep so ov02c10 waits for IVSC modules to load first
sudo tee /etc/modprobe.d/ivsc-camera.conf > /dev/null << 'EOF'
# Ensure IVSC modules are loaded before the camera sensor probes.
# Without this, ov02c10 hits -EPROBE_DEFER and may fail to bind,
# resulting in black frames (CSI Frame sync errors).
softdep ov02c10 pre: mei-vsc mei-vsc-hw ivsc-ace ivsc-csi
EOF
echo "  ✓ IVSC modules will load automatically at boot"
echo "  ✓ Module soft-dependency configured (IVSC loads before sensor)"

# Add IVSC modules to initramfs so they load before udev probes the sensor
echo ""
echo "[4/13] Adding IVSC modules to initramfs..."
INITRAMFS_CHANGED=false
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    if ! grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null; then
        echo "$mod" | sudo tee -a /etc/initramfs-tools/modules > /dev/null
        INITRAMFS_CHANGED=true
    fi
done

if $INITRAMFS_CHANGED; then
    echo "  Rebuilding initramfs (this may take a moment)..."
    sudo update-initramfs -u
    echo "  ✓ IVSC modules added to initramfs"
else
    echo "  ✓ IVSC modules already in initramfs"
fi

# Re-probe sensor
echo ""
echo "[5/13] Re-probing camera sensor..."
sudo modprobe -r ov02c10 2>/dev/null || true
sleep 1
sudo modprobe ov02c10
sleep 2

PROBE_OK=false
if journalctl -b -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -q "ov02c10.*entity"; then
    PROBE_OK=true
    echo "  ✓ OV02C10 sensor probed successfully"
elif journalctl -b -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -q "failed to check hwcfg: -517"; then
    echo "  ⚠ Sensor still deferring. Will likely resolve after reboot."
else
    echo "  ⚠ Sensor status unclear. Continuing setup..."
fi

# Install packages
echo ""
echo "[6/13] Installing camera HAL and relay service..."
NEED_INSTALL=false

if ! dpkg -l libcamhal-ipu6epmtl 2>/dev/null | grep -q "^ii"; then
    NEED_INSTALL=true
fi
if ! dpkg -l v4l2-relayd 2>/dev/null | grep -q "^ii"; then
    NEED_INSTALL=true
fi

if $NEED_INSTALL; then
    # Check if PPA is already added
    if ! grep -rq "oem-solutions-group/intel-ipu6" /etc/apt/sources.list.d/ 2>/dev/null; then
        echo "  Adding Intel IPU6 PPA..."
        sudo add-apt-repository -y ppa:oem-solutions-group/intel-ipu6
    fi
    sudo apt update -qq
    sudo apt install -y libcamhal-ipu6epmtl v4l2-relayd
    echo "  ✓ Installed libcamhal-ipu6epmtl and v4l2-relayd"
else
    echo "  ✓ Packages already installed"
fi

# Configure v4l2loopback and v4l2-relayd
echo ""
echo "[7/13] Configuring v4l2loopback and v4l2-relayd..."

# Write persistent v4l2loopback config (overrides any package defaults)
sudo tee /etc/modprobe.d/v4l2loopback.conf > /dev/null << 'EOF'
options v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"
EOF

# Remove conflicting config from v4l2-relayd package if present
if [[ -f /etc/modprobe.d/v4l2-relayd.conf ]]; then
    sudo rm -f /etc/modprobe.d/v4l2-relayd.conf
fi

# Reload v4l2loopback with correct name
sudo modprobe -r v4l2loopback 2>/dev/null || true
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"

DEVICE_NAME=$(cat /sys/devices/virtual/video4linux/video0/name 2>/dev/null || echo "NONE")
if [[ "$DEVICE_NAME" == "Intel MIPI Camera" ]]; then
    echo "  ✓ v4l2loopback device: $DEVICE_NAME"
else
    echo "  ⚠ Expected 'Intel MIPI Camera', got '$DEVICE_NAME'"
fi

# Write v4l2-relayd config to the correct path
# The v4l2-relayd@default.service reads: /etc/default/v4l2-relayd then /etc/v4l2-relayd.d/default.conf
sudo mkdir -p /etc/v4l2-relayd.d
sudo tee /etc/v4l2-relayd.d/default.conf > /dev/null << 'EOF'
VIDEOSRC=icamerasrc buffer-count=7 ! videoconvert
FORMAT=YUY2
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
EOF
echo "  ✓ v4l2-relayd configured for IPU6"

# Install resolution auto-detection script
# The camera HAL may change its default resolution across updates (e.g.
# 720p → 1080p). Instead of hardcoding WIDTH/HEIGHT, we probe icamerasrc
# at service startup to detect the native resolution.
sudo install -m 755 "$SCRIPT_DIR/v4l2-relayd-detect-resolution.sh" /usr/local/sbin/v4l2-relayd-detect-resolution.sh
echo "  ✓ Resolution auto-detection script installed"

# Harden v4l2-relayd with auto-restart and resolution auto-detection
echo ""
echo "[8/13] Hardening v4l2-relayd service..."
sudo mkdir -p /etc/systemd/system/v4l2-relayd@default.service.d
sudo tee /etc/systemd/system/v4l2-relayd@default.service.d/override.conf > /dev/null << 'EOF'
[Unit]
# Rate-limit restarts: max 10 attempts in 60 seconds
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
# Auto-detect camera resolution before starting the relay.
# The HAL may change its default resolution across updates (e.g. 720p → 1080p),
# so we probe icamerasrc at startup instead of hardcoding WIDTH/HEIGHT.
ExecStartPre=/usr/local/sbin/v4l2-relayd-detect-resolution.sh
EnvironmentFile=-/run/v4l2-relayd-resolution.env

# After the relay connects, re-trigger udev on the loopback device and
# restart the user's WirePlumber so it re-discovers the device as
# VIDEO_CAPTURE (v4l2loopback with exclusive_caps=1 only advertises
# capture once a producer is attached).
ExecStartPost=/bin/sh -c 'sleep 2; udevadm trigger --action=change /dev/video0 2>/dev/null; sleep 1; for uid in $(loginctl list-users --no-legend 2>/dev/null | awk "{print \\$1}"); do su - "#$uid" -c "systemctl --user restart wireplumber" 2>/dev/null || true; done'

# Fast auto-restart on failure (covers transient CSI frame sync errors).
Restart=always
RestartSec=2
EOF
sudo systemctl daemon-reload

# Start relay service
sudo systemctl reset-failed v4l2-relayd 2>/dev/null || true
sudo systemctl enable v4l2-relayd 2>/dev/null || true
sudo systemctl restart v4l2-relayd
sleep 3
echo "  ✓ v4l2-relayd hardened with auto-restart and sensor re-probe"

# Hide raw IPU6 ISYS video nodes from applications
echo ""
echo "[9/13] Hiding raw IPU6 video nodes..."
sudo tee /etc/udev/rules.d/90-hide-ipu6-v4l2.rules > /dev/null << 'EOF'
# Hide Intel IPU6 ISYS raw capture nodes from user-space applications.
# These ~48 /dev/video* nodes are internal to the IPU6 pipeline and unusable
# by apps directly. Exposing them causes crashes in Zoom, Cheese, and other
# apps that enumerate all video devices.
# TAG-="uaccess" prevents PipeWire/WirePlumber from creating nodes for them.
# MODE="0000" blocks direct access (libcamera handles the permission errors gracefully).
SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 ISYS Capture*", MODE="0000", TAG-="uaccess"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux
echo "  ✓ IPU6 raw nodes hidden from applications"

# PipeWire device classification is handled by the udev re-trigger in the
# v4l2-relayd ExecStartPost (step 8).  With exclusive_caps=1, v4l2loopback
# only advertises VIDEO_CAPTURE after the relay connects.  The udev change
# event makes WirePlumber re-query the device at that point.
# (device.capabilities is read-only in PipeWire — WirePlumber rules cannot
# override it; only a kernel-level cap change + udev event works.)
echo ""
echo "[10/13] Verifying PipeWire device classification..."
systemctl --user restart wireplumber 2>/dev/null || true
sleep 2
if wpctl status 2>/dev/null | grep -A10 "^Video" | grep -qi "MIPI\|Intel.*V4L2"; then
    echo "  ✓ PipeWire exposes camera as Source node"
else
    echo "  ⚠ WirePlumber may need a logout/login to pick up the camera."
    echo "    (The ExecStartPost udev trigger will handle this automatically on boot.)"
fi

# Install watchdog for blank frame auto-recovery
echo ""
echo "[11/13] Installing relay health watchdog..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo install -m 755 "$SCRIPT_DIR/v4l2-relayd-watchdog.sh" /usr/local/sbin/v4l2-relayd-watchdog.sh
sudo install -m 644 "$SCRIPT_DIR/v4l2-relayd-watchdog.service" /etc/systemd/system/v4l2-relayd-watchdog.service
sudo install -m 644 "$SCRIPT_DIR/v4l2-relayd-watchdog.timer" /etc/systemd/system/v4l2-relayd-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now v4l2-relayd-watchdog.timer
echo "  ✓ Watchdog timer enabled (checks every 3 minutes, auto-recovers after 3 failures)"

# Install upstream detection service
echo ""
echo "[12/13] Installing upstream detection service..."
sudo install -m 755 "$SCRIPT_DIR/v4l2-relayd-check-upstream.sh" /usr/local/sbin/v4l2-relayd-check-upstream.sh
sudo install -m 644 "$SCRIPT_DIR/v4l2-relayd-check-upstream.service" /etc/systemd/system/v4l2-relayd-check-upstream.service
sudo systemctl daemon-reload
sudo systemctl enable v4l2-relayd-check-upstream.service
echo "  ✓ Upstream detection enabled (auto-removes workaround when native support lands)"

# Verify
echo ""
echo "[13/13] Verifying webcam..."

SERVICE_OK=false
CAPTURE_OK=false

if systemctl is-active --quiet v4l2-relayd; then
    SERVICE_OK=true
    echo "  ✓ v4l2-relayd service is running"
else
    echo "  ✗ v4l2-relayd failed to start"
    echo "    Check: journalctl -u v4l2-relayd --no-pager | tail -20"
fi

if $SERVICE_OK; then
    if timeout 5 ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -update 1 -y /tmp/webcam_test.jpg 2>/dev/null; then
        SIZE=$(stat -c%s /tmp/webcam_test.jpg 2>/dev/null || echo 0)
        if [[ "$SIZE" -gt 10000 ]]; then
            CAPTURE_OK=true
            echo "  ✓ Webcam capture successful (${SIZE} bytes)"
        fi
    fi
fi

echo ""
echo "=============================================="
if $CAPTURE_OK; then
    echo "  ✅ SUCCESS — Webcam is working!"
    echo ""
    echo "  Device: /dev/video0 (Intel MIPI Camera)"
    echo "  Format: YUY2, auto-detected resolution, 30fps"
    echo ""
    echo "  Test:   mpv av://v4l2:/dev/video0 --profile=low-latency"
    echo ""
    echo "  Works with: Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC, GNOME Camera"
    echo ""
    echo "  Note: Cheese has a known bug (SIGSEGV in libgstvideoconvertscale.so)"
    echo "        Use GNOME Camera (snapshot) or any other app instead."
elif $SERVICE_OK; then
    echo "  ⚠ Service running but capture failed."
    echo "  A reboot is needed for the IVSC modules to load from initramfs."
    echo "  This is normal on first install — reboot and the camera will work."
else
    echo "  ⚠ Setup complete but service not running."
    echo "  A reboot is needed for modules to load in correct order."
fi
echo ""
echo "  Configuration files created:"
echo "    /etc/modules-load.d/ivsc.conf"
echo "    /etc/modprobe.d/ivsc-camera.conf"
echo "    /etc/modprobe.d/v4l2loopback.conf"
echo "    /etc/v4l2-relayd.d/default.conf"
echo "    /etc/udev/rules.d/90-hide-ipu6-v4l2.rules"
echo "    /etc/initramfs-tools/modules (IVSC entries)"
echo "    /etc/systemd/system/v4l2-relayd@default.service.d/override.conf"
echo "    /usr/local/sbin/v4l2-relayd-detect-resolution.sh"
echo "    /usr/local/sbin/v4l2-relayd-watchdog.sh"
echo "    /etc/systemd/system/v4l2-relayd-watchdog.service"
echo "    /etc/systemd/system/v4l2-relayd-watchdog.timer"
echo "    /usr/local/sbin/v4l2-relayd-check-upstream.sh"
echo "    /etc/systemd/system/v4l2-relayd-check-upstream.service"
echo "=============================================="
