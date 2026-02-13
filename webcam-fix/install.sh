#!/bin/bash
# install.sh
# Samsung Galaxy Book4 Ultra webcam fix for Ubuntu 24.04
# Tested on kernel 6.17.0-14-generic (HWE) with IPU6 Meteor Lake / OV02C10
#
# Root cause: IVSC (Intel Visual Sensing Controller) kernel modules don't
# auto-load, breaking the camera initialization chain. Additionally, the
# userspace camera HAL and v4l2 relay service need to be installed.
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
echo "[1/8] Verifying hardware..."
if ! lspci -d 8086:7d19 2>/dev/null | grep -q .; then
    echo "ERROR: Intel IPU6 Meteor Lake (8086:7d19) not found."
    echo "       This script is designed for Samsung Galaxy Book4 Ultra."
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
echo "[2/8] Checking kernel modules..."
MISSING_MODS=()
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    modpath=$(find /lib/modules/$(uname -r) -name "${mod//-/_}.ko*" -o -name "${mod}.ko*" 2>/dev/null | head -1)
    if [[ -z "$modpath" ]]; then
        # Try underscore variant
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

# Load and persist IVSC modules
echo ""
echo "[3/8] Loading IVSC kernel modules..."
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    if ! lsmod | grep -q "$(echo $mod | tr '-' '_')"; then
        sudo modprobe "$mod"
        echo "  Loaded: $mod"
    else
        echo "  Already loaded: $mod"
    fi
done

echo -e "mei-vsc\nmei-vsc-hw\nivsc-ace\nivsc-csi" | sudo tee /etc/modules-load.d/ivsc.conf > /dev/null
echo "  ✓ IVSC modules will load automatically at boot"

# Re-probe sensor
echo ""
echo "[4/8] Re-probing camera sensor..."
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
echo "[5/8] Installing camera HAL and relay service..."
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

# Configure v4l2loopback
echo ""
echo "[6/8] Configuring v4l2loopback and v4l2-relayd..."

# Reload v4l2loopback with correct name
sudo modprobe -r v4l2loopback 2>/dev/null || true
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"

DEVICE_NAME=$(cat /sys/devices/virtual/video4linux/video0/name 2>/dev/null || echo "NONE")
if [[ "$DEVICE_NAME" == "Intel MIPI Camera" ]]; then
    echo "  ✓ v4l2loopback device: $DEVICE_NAME"
else
    echo "  ⚠ Expected 'Intel MIPI Camera', got '$DEVICE_NAME'"
fi

# Write v4l2-relayd config
sudo tee /etc/v4l2-relayd > /dev/null << 'EOF'
VIDEOSRC=icamerasrc buffer-count=7
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
EOF
echo "  ✓ v4l2-relayd configured for IPU6"

# Start relay service
sudo systemctl reset-failed v4l2-relayd 2>/dev/null || true
sudo systemctl enable v4l2-relayd 2>/dev/null || true
sudo systemctl restart v4l2-relayd
sleep 3

# Step 7: WirePlumber override for PipeWire device classification
echo ""
echo "[7/8] Fixing PipeWire device classification..."
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo tee /etc/wireplumber/wireplumber.conf.d/50-v4l2-ipu6-camera.conf > /dev/null << 'WPEOF'
monitor.v4l2.rules = [
  {
    matches = [
      {
        api.v4l2.cap.card = "Intel MIPI Camera"
      }
    ]
    actions = {
      update-props = {
        device.capabilities = ":video_capture:"
      }
    }
  }
]
WPEOF
systemctl --user restart wireplumber 2>/dev/null || true
sleep 2
if wpctl status 2>/dev/null | grep -A10 "^Video" | grep -qi "MIPI\|Intel.*V4L2"; then
    echo "  ✓ PipeWire now exposes camera as Source node"
else
    echo "  ⚠ WirePlumber config written. May need logout/login to take effect."
fi

# Verify
echo ""
echo "[8/8] Verifying webcam..."

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
    if ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -update 1 -y /tmp/webcam_test.jpg 2>/dev/null; then
        SIZE=$(stat -c%s /tmp/webcam_test.jpg 2>/dev/null || echo 0)
        if [[ "$SIZE" -gt 1000 ]]; then
            CAPTURE_OK=true
            echo "  ✓ Webcam capture successful (${SIZE} bytes, 1280x720)"
        fi
    fi
fi

echo ""
echo "=============================================="
if $CAPTURE_OK; then
    echo "  ✅ SUCCESS — Webcam is working!"
    echo ""
    echo "  Device: /dev/video0 (Intel MIPI Camera)"
    echo "  Format: NV12, 1280x720, 30fps"
    echo ""
    echo "  Test:   mpv av://v4l2:/dev/video0 --profile=low-latency"
    echo ""
    echo "  Works with: Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC, Cheese"
    echo "  Note: GNOME Snapshot may segfault on KDE — that's a GTK4 bug, not a camera issue"
elif $SERVICE_OK; then
    echo "  ⚠ Service running but capture failed."
    echo "  Try rebooting and testing again."
else
    echo "  ⚠ Setup complete but service not running."
    echo "  A reboot is needed for modules to load in correct order."
fi
echo ""
echo "  Configuration files created:"
echo "    /etc/modules-load.d/ivsc.conf"
echo "    /etc/v4l2-relayd"
echo "    /etc/wireplumber/wireplumber.conf.d/50-v4l2-ipu6-camera.conf"
echo "=============================================="
