#!/bin/bash
# install.sh
# Samsung Galaxy Book5 webcam fix for Arch and Fedora
# For Lunar Lake (IPU7) with OV02C10 sensor
#
# Root cause: IPU7 on Lunar Lake requires the intel_cvs (Computer Vision
# Subsystem) kernel module to power the camera sensor, but this module is
# not yet in-tree. Intel provides it via DKMS from their vision-drivers
# repo. The userspace pipeline uses libcamera (not the IPU6 camera HAL).
#
# Pipeline: IPU7 -> OV02C10 -> libcamera -> PipeWire (pipewire-libcamera)
# No v4l2loopback or relay needed — libcamera talks to PipeWire directly.
#
# EXPERIMENTAL: This has NOT been tested on Samsung Galaxy Book5 hardware.
# Confirmed working on Dell XPS 13 9350 and Lenovo X1 Carbon Gen13 (same
# OV02C10 sensor on Lunar Lake). One Book5 360 user on Fedora 42 reports
# it working in browsers.
#
# For full documentation, see: README.md
#
# Usage: ./install.sh [--force]

set -e

VISION_DRIVER_VER="1.0.0"
VISION_DRIVER_REPO="https://github.com/intel/vision-drivers"
VISION_DRIVER_BRANCH="main"
SRC_DIR="/usr/src/vision-driver-${VISION_DRIVER_VER}"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

echo "=============================================="
echo "  Samsung Galaxy Book5 Webcam Fix"
echo "  Arch / Fedora — Lunar Lake (IPU7)"
echo ""
echo "  *** EXPERIMENTAL — USE AT YOUR OWN RISK ***"
echo "=============================================="
echo ""

# ──────────────────────────────────────────────
# [1/10] Root check
# ──────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# ──────────────────────────────────────────────
# [2/10] Distro detection
# ──────────────────────────────────────────────
echo "[2/10] Detecting distro..."
if command -v pacman >/dev/null 2>&1; then
    DISTRO="arch"
    echo "  ✓ Arch-based distro detected"
elif command -v dnf >/dev/null 2>&1; then
    DISTRO="fedora"
    echo "  ✓ Fedora detected"
elif command -v apt >/dev/null 2>&1; then
    echo "ERROR: Ubuntu / apt-based distros are not supported by this script."
    echo ""
    echo "       The IPU7 + libcamera pipeline requires packages not yet available"
    echo "       in Ubuntu PPAs. Arch and Fedora have libcamera 0.6+ in their repos."
    echo ""
    echo "       If you have a Galaxy Book4 (Meteor Lake / IPU6), use the webcam-fix/"
    echo "       directory instead — that one supports Ubuntu."
    exit 1
else
    echo "ERROR: Unsupported distro. This script requires pacman (Arch) or dnf (Fedora)."
    exit 1
fi

# ──────────────────────────────────────────────
# [3/10] Hardware detection
# ──────────────────────────────────────────────
echo ""
echo "[3/10] Verifying hardware..."

# Check for Lunar Lake IPU7
IPU7_FOUND=false
if lspci -d 8086:645d 2>/dev/null | grep -q . || \
   lspci -d 8086:6457 2>/dev/null | grep -q .; then
    IPU7_FOUND=true
fi

if ! $IPU7_FOUND; then
    # Check if this is a Meteor Lake system (IPU6) — point them to webcam-fix/
    if lspci -d 8086:7d19 2>/dev/null | grep -q .; then
        echo "ERROR: This system has Intel IPU6 (Meteor Lake), not IPU7 (Lunar Lake)."
        echo ""
        echo "       This webcam fix is for Lunar Lake systems (Galaxy Book5 models)."
        echo "       For Meteor Lake (Galaxy Book4), use the webcam-fix/ directory instead:"
        echo "       cd ../webcam-fix && ./install.sh"
        exit 1
    fi

    if $FORCE; then
        echo "  ⚠ No IPU7 detected — installing anyway (--force)"
    else
        echo "ERROR: Intel IPU7 Lunar Lake (8086:645d or 8086:6457) not found."
        echo "       This script is designed for Samsung Galaxy Book5 laptops with"
        echo "       Intel Lunar Lake processors."
        echo ""
        echo "       Use --force to install anyway on unsupported hardware."
        exit 1
    fi
else
    echo "  ✓ Found IPU7 Lunar Lake"
fi

# Check for OV02C10 sensor
if cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02C1"; then
    echo "  ✓ Found OV02C10 sensor (OVTI02C1)"
elif $FORCE; then
    echo "  ⚠ OV02C10 sensor not found in ACPI — continuing anyway (--force)"
else
    echo "  ⚠ OV02C10 sensor (OVTI02C1) not found in ACPI."
    echo "    This may be normal if the CVS module isn't loaded yet."
    echo "    Continuing with installation..."
fi

# ──────────────────────────────────────────────
# [4/10] Kernel version check
# ──────────────────────────────────────────────
echo ""
echo "[4/10] Checking kernel version..."
KVER=$(uname -r)
KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)

if [[ "$KMAJOR" -lt 6 ]] || { [[ "$KMAJOR" -eq 6 ]] && [[ "$KMINOR" -lt 18 ]]; }; then
    echo "ERROR: Kernel ${KVER} is too old. IPU7 webcam support requires kernel 6.18+."
    echo ""
    echo "       Kernel 6.18 includes in-tree IPU7, USBIO, and OV02C10 drivers."
    if [[ "$DISTRO" == "arch" ]]; then
        echo "       Update your kernel: sudo pacman -Syu"
    else
        echo "       Update your kernel: sudo dnf upgrade --refresh"
    fi
    exit 1
fi
echo "  ✓ Kernel ${KVER} (>= 6.18 required)"

# ──────────────────────────────────────────────
# [5/10] Install distro packages
# ──────────────────────────────────────────────
echo ""
echo "[5/10] Installing required packages..."

if [[ "$DISTRO" == "arch" ]]; then
    # Check what's missing
    PKGS_NEEDED=()
    for pkg in libcamera libcamera-ipa pipewire-libcamera linux-firmware; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            PKGS_NEEDED+=("$pkg")
        fi
    done

    if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
        echo "  Installing: ${PKGS_NEEDED[*]}"
        sudo pacman -S --needed --noconfirm "${PKGS_NEEDED[@]}"
        echo "  ✓ Packages installed"
    else
        echo "  ✓ All packages already installed"
    fi

    # Ensure DKMS prerequisites are available
    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        sudo pacman -S --needed --noconfirm dkms linux-headers
    fi

elif [[ "$DISTRO" == "fedora" ]]; then
    PKGS_NEEDED=()
    for pkg in libcamera pipewire-plugin-libcamera linux-firmware; do
        if ! rpm -q "$pkg" &>/dev/null; then
            PKGS_NEEDED+=("$pkg")
        fi
    done

    if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
        echo "  Installing: ${PKGS_NEEDED[*]}"
        sudo dnf install -y "${PKGS_NEEDED[@]}"
        echo "  ✓ Packages installed"
    else
        echo "  ✓ All packages already installed"
    fi

    # Ensure DKMS prerequisites are available
    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        sudo dnf install -y dkms kernel-devel
    fi
fi

# ──────────────────────────────────────────────
# [6/10] Build intel-vision-drivers via DKMS
# ──────────────────────────────────────────────
echo ""
echo "[6/10] Installing intel_cvs module via DKMS..."

# Check if already installed and working
if dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "installed"; then
    echo "  ✓ vision-driver/${VISION_DRIVER_VER} already installed via DKMS"
else
    # Download tarball (no git dependency)
    TMPDIR=$(mktemp -d)
    TARBALL="${TMPDIR}/vision-drivers.tar.gz"
    echo "  Downloading intel/vision-drivers from GitHub..."
    if ! curl -sL "${VISION_DRIVER_REPO}/archive/refs/heads/${VISION_DRIVER_BRANCH}.tar.gz" -o "$TARBALL"; then
        echo "ERROR: Failed to download vision-drivers from GitHub."
        echo "       Check your internet connection and try again."
        rm -rf "$TMPDIR"
        exit 1
    fi

    # Extract
    tar xzf "$TARBALL" -C "$TMPDIR"
    EXTRACTED_DIR=$(ls -d "${TMPDIR}"/vision-drivers-* 2>/dev/null | head -1)
    if [[ -z "$EXTRACTED_DIR" ]] || [[ ! -d "$EXTRACTED_DIR" ]]; then
        echo "ERROR: Failed to extract vision-drivers tarball."
        rm -rf "$TMPDIR"
        exit 1
    fi

    # Remove old DKMS version if present
    if dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "vision-driver"; then
        echo "  Removing existing DKMS module..."
        sudo dkms remove "vision-driver/${VISION_DRIVER_VER}" --all 2>/dev/null || true
    fi

    # Copy source to DKMS tree
    sudo rm -rf "$SRC_DIR"
    sudo mkdir -p "$SRC_DIR"
    sudo cp -a "$EXTRACTED_DIR"/* "$SRC_DIR/"

    # Ensure dkms.conf exists
    if [[ ! -f "$SRC_DIR/dkms.conf" ]]; then
        # Create a minimal dkms.conf if the repo doesn't include one
        sudo tee "$SRC_DIR/dkms.conf" > /dev/null << EOF
PACKAGE_NAME="vision-driver"
PACKAGE_VERSION="${VISION_DRIVER_VER}"
BUILT_MODULE_NAME[0]="intel_cvs"
BUILT_MODULE_LOCATION[0]="backport-include/cvs/"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
EOF
    fi

    # Secure Boot handling for Fedora
    if [[ "$DISTRO" == "fedora" ]] && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        MOK_KEY="/etc/pki/akmods/private/private_key.priv"
        MOK_CERT="/etc/pki/akmods/certs/public_key.der"

        if [[ ! -f "$MOK_KEY" ]] || [[ ! -f "$MOK_CERT" ]]; then
            echo "  Generating MOK key for Secure Boot module signing..."
            sudo dnf install -y kmodtool akmods mokutil openssl >/dev/null 2>&1 || true
            sudo kmodgenca -a 2>/dev/null || true
        fi

        if [[ -f "$MOK_KEY" ]] && [[ -f "$MOK_CERT" ]]; then
            echo "  Configuring DKMS to sign modules with Fedora akmods MOK key..."
            sudo mkdir -p /etc/dkms
            if ! grep -q "mok_signing_key" /etc/dkms/framework.conf 2>/dev/null; then
                sudo tee -a /etc/dkms/framework.conf > /dev/null << SIGNEOF

# Added by Book5 webcam fix installer for Secure Boot module signing
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
SIGNEOF
            fi

            if ! mokutil --test-key "$MOK_CERT" 2>/dev/null | grep -q "is already enrolled"; then
                echo ""
                echo "  >>> Secure Boot: You need to enroll the MOK key. <<<"
                echo "  >>> Run: sudo mokutil --import ${MOK_CERT}        <<<"
                echo "  >>> Then reboot and follow the MOK enrollment prompt. <<<"
                echo ""
                sudo mokutil --import "$MOK_CERT" 2>/dev/null || true
            fi
        fi
    fi

    # Register, build, install
    echo "  Building DKMS module (this may take a moment)..."
    sudo dkms add "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null || true
    sudo dkms build "vision-driver/${VISION_DRIVER_VER}"
    sudo dkms install "vision-driver/${VISION_DRIVER_VER}"

    rm -rf "$TMPDIR"
    echo "  ✓ vision-driver/${VISION_DRIVER_VER} installed via DKMS"
fi

# ──────────────────────────────────────────────
# [7/10] Module load configuration
# ──────────────────────────────────────────────
echo ""
echo "[7/10] Configuring module loading..."

# Load intel_cvs at boot
sudo tee /etc/modules-load.d/intel-cvs.conf > /dev/null << 'EOF'
# Intel Computer Vision Subsystem — required for IPU7 camera on Lunar Lake
intel_cvs
EOF
echo "  ✓ Created /etc/modules-load.d/intel-cvs.conf"

# Ensure intel_cvs loads before ov02c10 sensor
sudo tee /etc/modprobe.d/intel-cvs-camera.conf > /dev/null << 'EOF'
# Ensure intel_cvs is loaded before the camera sensor probes.
# Without this, ov02c10 may fail to bind on boot.
softdep ov02c10 pre: intel_cvs
EOF
echo "  ✓ Created /etc/modprobe.d/intel-cvs-camera.conf"

# ──────────────────────────────────────────────
# [8/10] libcamera IPA module path
# ──────────────────────────────────────────────
echo ""
echo "[8/10] Configuring libcamera environment..."

# Determine IPA path based on distro
if [[ "$DISTRO" == "arch" ]]; then
    IPA_PATH="/usr/lib/libcamera/ipa"
elif [[ "$DISTRO" == "fedora" ]]; then
    # Fedora uses lib64
    if [[ -d "/usr/lib64/libcamera/ipa" ]]; then
        IPA_PATH="/usr/lib64/libcamera/ipa"
    else
        IPA_PATH="/usr/lib/libcamera/ipa"
    fi
fi

# systemd user environment
sudo mkdir -p /etc/environment.d
sudo tee /etc/environment.d/libcamera-ipa.conf > /dev/null << EOF
LIBCAMERA_IPA_MODULE_PATH=${IPA_PATH}
EOF
echo "  ✓ Created /etc/environment.d/libcamera-ipa.conf"

# Non-systemd shell sessions
sudo tee /etc/profile.d/libcamera-ipa.sh > /dev/null << EOF
export LIBCAMERA_IPA_MODULE_PATH=${IPA_PATH}
EOF
echo "  ✓ Created /etc/profile.d/libcamera-ipa.sh"

# ──────────────────────────────────────────────
# [9/10] Load modules and test
# ──────────────────────────────────────────────
echo ""
echo "[9/10] Loading modules and testing..."

# Try to load intel_cvs now
if ! lsmod | grep -q "intel_cvs"; then
    if sudo modprobe intel_cvs 2>/dev/null; then
        echo "  ✓ intel_cvs module loaded"
    else
        echo "  ⚠ Could not load intel_cvs now — will load after reboot"
    fi
else
    echo "  ✓ intel_cvs module already loaded"
fi

# Export IPA path for current session test
export LIBCAMERA_IPA_MODULE_PATH="${IPA_PATH}"

# Test with cam -l if available
if command -v cam >/dev/null 2>&1; then
    echo "  Testing with cam -l..."
    CAM_OUTPUT=$(cam -l 2>&1 || true)
    if echo "$CAM_OUTPUT" | grep -qi "ov02c10\|Camera\|sensor"; then
        echo "  ✓ libcamera detects camera!"
        echo "$CAM_OUTPUT" | head -5 | sed 's/^/    /'
    else
        echo "  ⚠ libcamera does not see the camera yet (may need reboot)"
    fi
else
    echo "  ⚠ cam (libcamera-tools) not installed — skipping live test"
    if [[ "$DISTRO" == "arch" ]]; then
        echo "    Optional: sudo pacman -S libcamera-tools"
    fi
fi

# ──────────────────────────────────────────────
# [10/10] Summary
# ──────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  Installation complete — reboot required"
echo "=============================================="
echo ""
echo "  *** EXPERIMENTAL — This has not been verified on Samsung Galaxy Book5. ***"
echo ""
echo "  After rebooting, test with:"
echo "    cam -l                      # List cameras (libcamera)"
echo "    cam -c1 --capture=10        # Capture 10 frames"
echo "    mpv av://v4l2:/dev/video0   # Live preview (if V4L2 device appears)"
echo ""
echo "  The camera should appear automatically in Firefox, Chromium, and other"
echo "  apps that use PipeWire for camera access. No v4l2loopback needed."
echo ""
echo "  Known issues:"
echo "    - Green tint: IPU7 calibration profiles may not exist for your sensor."
echo "      This is a libcamera tuning issue, not a driver bug."
echo "    - If PipeWire doesn't see the camera, try: systemctl --user restart pipewire"
echo ""
echo "  Configuration files created:"
echo "    /etc/modules-load.d/intel-cvs.conf"
echo "    /etc/modprobe.d/intel-cvs-camera.conf"
echo "    /etc/environment.d/libcamera-ipa.conf"
echo "    /etc/profile.d/libcamera-ipa.sh"
echo "    ${SRC_DIR}/ (DKMS source)"
echo ""
echo "  To uninstall: ./uninstall.sh"
echo "=============================================="
