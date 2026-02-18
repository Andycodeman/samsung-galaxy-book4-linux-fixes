#!/bin/bash
# install.sh
# Samsung Galaxy Book5 webcam fix for Arch, Fedora, and Ubuntu (with custom libcamera)
# For Lunar Lake (IPU7) with OV02C10 or OV02E10 sensor
#
# Root cause: IPU7 on Lunar Lake requires the intel_cvs (Computer Vision
# Subsystem) kernel module to power the camera sensor, but this module is
# not yet in-tree. Intel provides it via DKMS from their vision-drivers
# repo. Additionally, LJCA (Lunar Lake Joint Controller for Accessories)
# GPIO/USB modules must be loaded before the vision driver and sensor.
# The userspace pipeline uses libcamera (not the IPU6 camera HAL).
#
# Pipeline: LJCA -> intel_cvs -> OV02C10/OV02E10 -> libcamera -> PipeWire
# No v4l2loopback or relay needed — libcamera talks to PipeWire directly.
#
# EXPERIMENTAL: Confirmed working on Galaxy Book5 360 (Fedora 42 + Ubuntu
# 24.04), Dell XPS 13 9350 (Arch), and Lenovo X1 Carbon Gen13 (Fedora 42).
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
echo "  Arch / Fedora / Ubuntu — Lunar Lake (IPU7)"
echo ""
echo "  *** EXPERIMENTAL — USE AT YOUR OWN RISK ***"
echo "=============================================="
echo ""

# ──────────────────────────────────────────────
# [1/12] Root check
# ──────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# ──────────────────────────────────────────────
# [2/12] Distro detection
# ──────────────────────────────────────────────
echo "[2/12] Detecting distro..."
if command -v pacman >/dev/null 2>&1; then
    DISTRO="arch"
    echo "  ✓ Arch-based distro detected"
elif command -v dnf >/dev/null 2>&1; then
    DISTRO="fedora"
    echo "  ✓ Fedora detected"
elif command -v apt >/dev/null 2>&1; then
    DISTRO="ubuntu"
    # Ubuntu doesn't ship libcamera 0.6+ (needed for IPU7) in its repos.
    # But users who build libcamera from source can still use this script.
    # Note: cam --version doesn't exist in all libcamera versions (e.g. 0.7.0).
    # Use the libcamera.so symlink version instead.
    LIBCAMERA_VER=$(ls -l /usr/local/lib/*/libcamera.so.* /usr/local/lib/libcamera.so.* /usr/lib/*/libcamera.so.* /usr/lib/libcamera.so.* 2>/dev/null \
        | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -z "$LIBCAMERA_VER" ]]; then
        echo "ERROR: Ubuntu detected but libcamera is not installed."
        echo ""
        echo "       Ubuntu's repos ship libcamera 0.2.x which does NOT support IPU7."
        echo "       You need libcamera 0.6+ built from source."
        echo ""
        echo "       Build instructions: https://libcamera.org/getting-started.html"
        echo "       Reference: https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera"
        echo ""
        echo "       If you have a Galaxy Book4 (Meteor Lake / IPU6), use the webcam-fix/"
        echo "       directory instead — that one supports Ubuntu natively."
        exit 1
    fi
    LIBCAMERA_MAJOR=$(echo "$LIBCAMERA_VER" | cut -d. -f1)
    LIBCAMERA_MINOR=$(echo "$LIBCAMERA_VER" | cut -d. -f2)
    if [[ "$LIBCAMERA_MAJOR" -eq 0 ]] && [[ "$LIBCAMERA_MINOR" -lt 6 ]]; then
        echo "ERROR: libcamera ${LIBCAMERA_VER} is too old. IPU7 requires libcamera 0.6+."
        echo ""
        echo "       Ubuntu's repos ship an older version. You need to build 0.6+ from source."
        echo "       Build instructions: https://libcamera.org/getting-started.html"
        exit 1
    fi
    echo "  ✓ Ubuntu detected with libcamera ${LIBCAMERA_VER} (>= 0.6 required)"
    echo "  ⚠ Ubuntu support is experimental — libcamera was not installed from repos"
else
    echo "ERROR: Unsupported distro. This script requires pacman (Arch), dnf (Fedora), or apt (Ubuntu)."
    exit 1
fi

# ──────────────────────────────────────────────
# [3/12] Hardware detection
# ──────────────────────────────────────────────
echo ""
echo "[3/12] Verifying hardware..."

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

# Check for OV02C10 or OV02E10 sensor
SENSOR=""
if cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02C1"; then
    SENSOR="ov02c10"
    echo "  ✓ Found OV02C10 sensor (OVTI02C1)"
elif cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02E1"; then
    SENSOR="ov02e10"
    echo "  ✓ Found OV02E10 sensor (OVTI02E1)"
elif $FORCE; then
    echo "  ⚠ No OV02C10/OV02E10 sensor found in ACPI — continuing anyway (--force)"
else
    echo "  ⚠ No OV02C10 (OVTI02C1) or OV02E10 (OVTI02E1) sensor found in ACPI."
    echo "    This may be normal if the CVS module isn't loaded yet."
    echo "    Continuing with installation..."
fi

# ──────────────────────────────────────────────
# [4/12] Kernel version check
# ──────────────────────────────────────────────
echo ""
echo "[4/12] Checking kernel version..."
KVER=$(uname -r)
KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)

if [[ "$KMAJOR" -lt 6 ]] || { [[ "$KMAJOR" -eq 6 ]] && [[ "$KMINOR" -lt 18 ]]; }; then
    echo "ERROR: Kernel ${KVER} is too old. IPU7 webcam support requires kernel 6.18+."
    echo ""
    echo "       Kernel 6.18 includes in-tree IPU7, USBIO, and OV02C10 drivers."
    if [[ "$DISTRO" == "arch" ]]; then
        echo "       Update your kernel: sudo pacman -Syu"
    elif [[ "$DISTRO" == "fedora" ]]; then
        echo "       Update your kernel: sudo dnf upgrade --refresh"
    else
        echo "       Ubuntu 24.04 ships kernel 6.17. You need to compile 6.18+ from source"
        echo "       or install a mainline kernel build."
    fi
    exit 1
fi
echo "  ✓ Kernel ${KVER} (>= 6.18 required)"

# ──────────────────────────────────────────────
# [5/12] Install distro packages
# ──────────────────────────────────────────────
echo ""
echo "[5/12] Installing required packages..."

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

elif [[ "$DISTRO" == "ubuntu" ]]; then
    # On Ubuntu, libcamera was already verified in step 2 (built from source).
    # We only install DKMS prerequisites — do NOT install libcamera from apt
    # (it's too old and would conflict with the source build).
    echo "  ✓ libcamera already installed (from source)"

    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        sudo apt install -y dkms linux-headers-$(uname -r)
    fi

    # Check for pipewire-libcamera SPA plugin
    if ! find /usr/lib /usr/local/lib -path "*/spa-*/libcamera*" -name "*.so" 2>/dev/null | grep -q .; then
        echo "  ⚠ pipewire-libcamera SPA plugin not found."
        echo "    PipeWire apps (Firefox, Zoom, etc.) may not see the camera."
        echo "    You may need to build the PipeWire libcamera plugin from source,"
        echo "    or use cam/qcam for direct libcamera access."
    else
        echo "  ✓ PipeWire libcamera plugin found"
    fi
fi

# ──────────────────────────────────────────────
# [6/12] Build intel-vision-drivers via DKMS
# ──────────────────────────────────────────────
echo ""
echo "[6/12] Installing intel_cvs module via DKMS..."

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
# [7/12] Module load configuration
# ──────────────────────────────────────────────
echo ""
echo "[7/12] Configuring module loading..."

# The full module chain for IPU7 camera on Lunar Lake:
# usb_ljca -> gpio_ljca -> intel_cvs -> ov02c10/ov02e10
# LJCA (Lunar Lake Joint Controller for Accessories) provides GPIO/USB
# control needed by the vision subsystem to power the sensor.
sudo tee /etc/modules-load.d/intel-ipu7-camera.conf > /dev/null << 'EOF'
# IPU7 camera module chain for Lunar Lake
# LJCA provides GPIO/USB control for the vision subsystem
usb_ljca
gpio_ljca
# Intel Computer Vision Subsystem — powers the camera sensor
intel_cvs
EOF
echo "  ✓ Created /etc/modules-load.d/intel-ipu7-camera.conf"

# Determine which sensor module name to use for softdep
SENSOR_MOD="${SENSOR:-ov02c10}"

# Ensure correct load order: LJCA -> intel_cvs -> sensor
sudo tee /etc/modprobe.d/intel-ipu7-camera.conf > /dev/null << EOF
# Ensure LJCA and intel_cvs are loaded before the camera sensor probes.
# Without this, the sensor may fail to bind on boot.
# LJCA (GPIO/USB) -> intel_cvs (CVS) -> sensor
softdep intel_cvs pre: usb_ljca gpio_ljca
softdep ${SENSOR_MOD} pre: intel_cvs usb_ljca gpio_ljca
EOF
echo "  ✓ Created /etc/modprobe.d/intel-ipu7-camera.conf"

# ──────────────────────────────────────────────
# [8/12] libcamera IPA module path
# ──────────────────────────────────────────────
echo ""
echo "[8/12] Configuring libcamera environment..."

# Determine IPA path based on distro
if [[ "$DISTRO" == "fedora" ]]; then
    # Fedora uses lib64
    if [[ -d "/usr/lib64/libcamera/ipa" ]]; then
        IPA_PATH="/usr/lib64/libcamera/ipa"
    else
        IPA_PATH="/usr/lib/libcamera/ipa"
    fi
elif [[ "$DISTRO" == "ubuntu" ]]; then
    # Source builds typically install to /usr/local/lib
    if [[ -d "/usr/local/lib/libcamera/ipa" ]]; then
        IPA_PATH="/usr/local/lib/libcamera/ipa"
    elif [[ -d "/usr/local/lib/x86_64-linux-gnu/libcamera/ipa" ]]; then
        IPA_PATH="/usr/local/lib/x86_64-linux-gnu/libcamera/ipa"
    else
        IPA_PATH="/usr/lib/libcamera/ipa"
    fi
else
    # Arch and other
    IPA_PATH="/usr/lib/libcamera/ipa"
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
# [9/12] Hide raw IPU7 video nodes
# ──────────────────────────────────────────────
echo ""
echo "[9/12] Hiding raw IPU7 video nodes from applications..."
sudo tee /etc/udev/rules.d/90-hide-ipu7-v4l2.rules > /dev/null << 'EOF'
# Hide Intel IPU7 ISYS raw capture nodes from user-space applications.
# These /dev/video* nodes are internal to the IPU7 pipeline and unusable
# by apps directly. Exposing them confuses apps that enumerate all video devices.
# TAG-="uaccess" prevents PipeWire/WirePlumber from creating nodes for them.
# MODE="0000" blocks direct access (libcamera handles the raw nodes internally).
SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU7 ISYS Capture*", MODE="0000", TAG-="uaccess"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux 2>/dev/null || true
echo "  ✓ Created /etc/udev/rules.d/90-hide-ipu7-v4l2.rules"

# ──────────────────────────────────────────────
# [10/12] Load modules and test
# ──────────────────────────────────────────────
echo ""
echo "[10/12] Loading modules and testing..."

# Try to load LJCA and intel_cvs now
for mod in usb_ljca gpio_ljca; do
    if ! lsmod | grep -q "$(echo $mod | tr '-' '_')"; then
        sudo modprobe "$mod" 2>/dev/null || true
    fi
done
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
    if echo "$CAM_OUTPUT" | grep -qi "ov02c10\|ov02e10\|Camera\|sensor"; then
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
# [12/12] Summary
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
echo "    - Vertically flipped image: Some setups show an upside-down preview."
echo "      This is a sensor orientation / libcamera tuning issue."
echo "    - Firefox may conflict with other libcamera apps (qcam). If the camera"
echo "      stops working, try rebooting."
echo "    - If PipeWire doesn't see the camera, try: systemctl --user restart pipewire"
echo ""
echo "  Configuration files created:"
echo "    /etc/modules-load.d/intel-ipu7-camera.conf"
echo "    /etc/modprobe.d/intel-ipu7-camera.conf"
echo "    /etc/udev/rules.d/90-hide-ipu7-v4l2.rules"
echo "    /etc/environment.d/libcamera-ipa.conf"
echo "    /etc/profile.d/libcamera-ipa.sh"
echo "    ${SRC_DIR}/ (DKMS source)"
echo ""
echo "  To uninstall: ./uninstall.sh"
echo "=============================================="
