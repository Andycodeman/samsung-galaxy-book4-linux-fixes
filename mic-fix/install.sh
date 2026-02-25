#!/bin/bash
set -e

# =============================================================================
# SOF Firmware Installer — Samsung Galaxy Book4/Book5 Internal Microphone Fix
# =============================================================================
# Updates Intel SOF (Sound Open Firmware) and sets dsp_driver=3 to enable
# the internal DMIC (digital microphone) on Galaxy Book4 (Meteor Lake) and
# Galaxy Book5 (Lunar Lake) laptops running Linux.
#
# The stock linux-firmware package on Ubuntu 24.04 ships SOF v2023.12.1 which
# is too old for reliable DMIC support on these platforms. This installer
# pulls v2025.12.1+ from the upstream linux-firmware repository.
#
# Usage: sudo bash install.sh [--force]
# =============================================================================

FORCE=false
[ "$1" = "--force" ] && FORCE=true

FW_BASE="/lib/firmware/intel"
SOF_IPC4_DIR="${FW_BASE}/sof-ipc4"
SOF_IPC4_LIB_DIR="${FW_BASE}/sof-ipc4-lib"
SOF_ACE_TPLG_DIR="${FW_BASE}/sof-ace-tplg"
SOF_LEGACY_DIR="${FW_BASE}/sof"
SOF_LEGACY_TPLG_DIR="${FW_BASE}/sof-tplg"

MODPROBE_CONF="/etc/modprobe.d/sof-dsp-driver.conf"
LINUX_FW_REPO="https://gitlab.com/kernel-firmware/linux-firmware.git"

echo "=== SOF Firmware Installer (Internal Mic Fix) ==="
echo "Samsung Galaxy Book4 / Book5"
echo ""

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

# Detect package manager
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_INSTALL="dnf install -y"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
    PKG_INSTALL="pacman -S --noconfirm"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_INSTALL="apt-get install -y"
else
    PKG_MGR="unknown"
    PKG_INSTALL=""
fi

# Check prerequisites: git is needed for firmware download
if ! command -v git >/dev/null 2>&1; then
    echo "Installing git (needed to download firmware)..."
    if [ -n "$PKG_INSTALL" ]; then
        $PKG_INSTALL git >/dev/null 2>&1 || {
            echo "ERROR: Failed to install git. Install manually." >&2
            exit 1
        }
    else
        echo "ERROR: git not installed. Please install it manually." >&2
        exit 1
    fi
fi

# ─── Hardware Detection ─────────────────────────────────────────────────────

# Detect Intel HDA audio controller
HDA_PCI=$(lspci -D -d ::0403 2>/dev/null | grep -i intel | head -1)
if [ -z "$HDA_PCI" ]; then
    HDA_PCI=$(lspci -D -d ::0401 2>/dev/null | grep -i intel | head -1)
fi

if [ -z "$HDA_PCI" ]; then
    if $FORCE; then
        echo "WARNING: No Intel HDA audio controller detected — installing anyway (--force)"
    else
        echo "ERROR: No Intel HDA audio controller detected." >&2
        echo "This fix is for Samsung Galaxy Book4/Book5 laptops with Intel audio." >&2
        echo "Use --force to install anyway." >&2
        exit 1
    fi
fi

# Detect platform: Meteor Lake (Book4) or Lunar Lake (Book5)
PLATFORM=""
if lspci -nn 2>/dev/null | grep -qi "Meteor Lake"; then
    PLATFORM="mtl"
    echo "Detected: Meteor Lake (Galaxy Book4 family)"
elif lspci -nn 2>/dev/null | grep -qi "Lunar Lake"; then
    PLATFORM="lnl"
    echo "Detected: Lunar Lake (Galaxy Book5 family)"
elif dmesg 2>/dev/null | grep -qi "sof-audio-pci-intel-mtl"; then
    PLATFORM="mtl"
    echo "Detected: Meteor Lake via SOF driver (Galaxy Book4 family)"
elif dmesg 2>/dev/null | grep -qi "sof-audio-pci-intel-lnl"; then
    PLATFORM="lnl"
    echo "Detected: Lunar Lake via SOF driver (Galaxy Book5 family)"
else
    if $FORCE; then
        echo "WARNING: Could not detect Meteor Lake or Lunar Lake platform"
        echo "         Installing all SOF firmware anyway (--force)"
    else
        echo "ERROR: Could not detect a supported Intel audio platform." >&2
        echo "Supported: Meteor Lake (Book4), Lunar Lake (Book5)." >&2
        echo "Use --force to install anyway." >&2
        exit 1
    fi
fi

# Check Samsung vendor
if [ -f /sys/class/dmi/id/sys_vendor ]; then
    VENDOR=$(cat /sys/class/dmi/id/sys_vendor)
    if ! echo "$VENDOR" | grep -qi samsung; then
        if $FORCE; then
            echo "WARNING: System vendor is '${VENDOR}', not Samsung — installing anyway (--force)"
        else
            echo "ERROR: System vendor is '${VENDOR}', not Samsung." >&2
            echo "This fix is intended for Samsung Galaxy Book4/Book5 laptops." >&2
            echo "Use --force to install anyway." >&2
            exit 1
        fi
    fi
fi

# ─── Check Current State ────────────────────────────────────────────────────

# Check if dsp_driver is already set
CURRENT_DSP=""
if grep -rq "dsp_driver=" /etc/modprobe.d/ 2>/dev/null; then
    CURRENT_DSP=$(grep -rh "dsp_driver=" /etc/modprobe.d/ 2>/dev/null | grep -oP 'dsp_driver=\K[0-9]+' | tail -1)
fi

# Check current firmware version from dmesg
CURRENT_FW_VER=$(dmesg 2>/dev/null | grep -oP 'Booted firmware version: \K[0-9.]+' | tail -1)
if [ -n "$CURRENT_FW_VER" ]; then
    echo "Current SOF firmware version: ${CURRENT_FW_VER}"
fi

if [ "$CURRENT_DSP" = "3" ]; then
    echo "Current dsp_driver: 3 (SOF) — already set"
else
    echo "Current dsp_driver: ${CURRENT_DSP:-not set (default)}"
fi

# Check if DMIC is already working
DMIC_COUNT=$(arecord -l 2>/dev/null | grep -ci "dmic\|digital mic" || true)
if [ "$DMIC_COUNT" -gt 0 ]; then
    echo ""
    echo "NOTE: Internal mic (DMIC) already appears in arecord -l."
    echo "      You may not need this fix. Proceeding anyway."
    echo ""
fi

# ─── Download Firmware ───────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

echo ""
echo "Downloading latest SOF firmware from linux-firmware repository..."
echo "(This may take a minute — sparse checkout of firmware files only)"

cd "$TMPDIR"
git init -q linux-firmware
cd linux-firmware
git remote add origin "$LINUX_FW_REPO"

# Sparse checkout: only pull the SOF firmware directories we need
git sparse-checkout init
git sparse-checkout set \
    "intel/sof-ipc4" \
    "intel/sof-ipc4-lib" \
    "intel/sof-ace-tplg" \
    "intel/sof" \
    "intel/sof-tplg" \
    "WHENCE"

echo "Fetching firmware files (depth=1 for speed)..."
git fetch --depth=1 -q origin main
git checkout -q FETCH_HEAD

# Verify we got firmware files
if [ ! -d "intel/sof-ipc4" ]; then
    echo "ERROR: Failed to download firmware files." >&2
    exit 1
fi

# Get the firmware version tag if possible
FW_COMMIT=$(git log -1 --format="%h %s" 2>/dev/null || echo "unknown")
echo "Firmware source: ${FW_COMMIT}"

# ─── Backup Existing Firmware ────────────────────────────────────────────────

echo ""
echo "Backing up existing firmware..."

backup_dir() {
    local src="$1"
    local bak="${src}.bak-mic-fix"
    if [ -d "$src" ] && [ ! -d "$bak" ]; then
        echo "  Backup: ${src} → ${bak}"
        cp -a "$src" "$bak"
    elif [ -d "$bak" ]; then
        echo "  Backup already exists: ${bak} (skipping)"
    fi
}

backup_dir "$SOF_IPC4_DIR"
backup_dir "$SOF_IPC4_LIB_DIR"
backup_dir "$SOF_ACE_TPLG_DIR"
backup_dir "$SOF_LEGACY_DIR"
backup_dir "$SOF_LEGACY_TPLG_DIR"

# ─── Install New Firmware ────────────────────────────────────────────────────

echo ""
echo "Installing updated SOF firmware..."

install_fw_dir() {
    local src="$1"
    local dst="$2"
    if [ -d "$src" ]; then
        # Merge new files into existing directory (don't delete old files
        # that may be needed by other platforms)
        cp -a "$src"/* "$dst"/ 2>/dev/null || true
        echo "  Updated: ${dst}"
    fi
}

mkdir -p "$SOF_IPC4_DIR" "$SOF_ACE_TPLG_DIR" "$SOF_LEGACY_DIR" "$SOF_LEGACY_TPLG_DIR"

install_fw_dir "intel/sof-ipc4" "$SOF_IPC4_DIR"
[ -d "intel/sof-ipc4-lib" ] && {
    mkdir -p "$SOF_IPC4_LIB_DIR"
    install_fw_dir "intel/sof-ipc4-lib" "$SOF_IPC4_LIB_DIR"
}
install_fw_dir "intel/sof-ace-tplg" "$SOF_ACE_TPLG_DIR"
install_fw_dir "intel/sof" "$SOF_LEGACY_DIR"
install_fw_dir "intel/sof-tplg" "$SOF_LEGACY_TPLG_DIR"

# ─── Configure dsp_driver=3 ─────────────────────────────────────────────────

echo ""
echo "Configuring dsp_driver=3 (SOF mode)..."

# Remove any existing dsp_driver settings in other files to avoid conflicts
for conf in /etc/modprobe.d/*.conf; do
    [ -f "$conf" ] || continue
    [ "$conf" = "$MODPROBE_CONF" ] && continue
    if grep -q "snd-intel-dspcfg.*dsp_driver" "$conf" 2>/dev/null; then
        echo "  Removing dsp_driver from: ${conf}"
        sed -i '/snd-intel-dspcfg.*dsp_driver/d' "$conf"
    fi
done

# Write our config
cat > "$MODPROBE_CONF" << 'EOF'
# SOF DSP driver for Samsung Galaxy Book4/Book5 internal mic (DMIC)
# Installed by mic-fix/install.sh — do not edit manually
# dsp_driver=3 selects SOF (Sound Open Firmware)
# To revert: sudo bash mic-fix/uninstall.sh
options snd-intel-dspcfg dsp_driver=3
EOF

echo "  Created: ${MODPROBE_CONF}"

# ─── Rebuild initramfs ──────────────────────────────────────────────────────

echo ""
echo "Rebuilding initramfs to include updated firmware..."

if command -v update-initramfs >/dev/null 2>&1; then
    # Ubuntu/Debian
    update-initramfs -u -k all 2>&1 | tail -2
elif command -v dracut >/dev/null 2>&1; then
    # Fedora/RHEL
    dracut --force --regenerate-all 2>&1 | tail -2
elif command -v mkinitcpio >/dev/null 2>&1; then
    # Arch
    mkinitcpio -P 2>&1 | tail -2
else
    echo "WARNING: Could not detect initramfs tool."
    echo "         You may need to rebuild your initramfs manually."
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "=== Installation complete ==="
echo ""
echo "Reboot now, then check:"
echo "  1. Speakers — play something"
echo "  2. Mic — arecord -l (should show a DMIC device)"
echo "  3. If anything breaks: sudo dmesg | grep -i sof | head -20"
echo ""
echo "To revert if SOF doesn't work:"
echo "  sudo bash $(cd "$(dirname "$0")" && pwd)/uninstall.sh"
echo ""
