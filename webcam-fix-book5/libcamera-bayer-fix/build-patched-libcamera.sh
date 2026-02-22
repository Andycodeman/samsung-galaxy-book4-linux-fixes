#!/bin/bash
# build-patched-libcamera.sh — Build and install patched libcamera with
# unconditional bayer order fix for OV02E10 purple tint.
#
# This script:
#   1. Detects the installed libcamera version
#   2. Installs build dependencies for your distro
#   3. Clones matching libcamera source from git
#   4. Applies the bayer order fix patch
#   5. Builds libcamera
#   6. Installs the patched library (with backup of originals)
#
# The fix makes the Simple pipeline handler ALWAYS recalculate the bayer
# pattern order when sensor transforms (hflip/vflip) are applied, instead
# of only doing so when the sensor reports a changed media bus format code.
# This fixes OV02E10 (and any sensor with the same MODIFY_LAYOUT bug).
#
# Usage: sudo ./build-patched-libcamera.sh
#
# To uninstall: sudo ./build-patched-libcamera.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/libcamera-bayer-fix-build"
BACKUP_DIR="/var/lib/libcamera-bayer-fix-backup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()   { error "$*"; exit 1; }

# ─── Root check ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo)."
fi

REAL_USER="${SUDO_USER:-$USER}"

# ─── Uninstall mode ──────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    echo ""
    echo "=============================================="
    echo "  Uninstall Patched libcamera"
    echo "=============================================="
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        die "No backup found at $BACKUP_DIR — nothing to restore."
    fi

    info "Restoring original libcamera files..."
    while IFS= read -r backup_file; do
        rel_path="${backup_file#$BACKUP_DIR}"
        if [[ -f "$backup_file" ]]; then
            cp -v "$backup_file" "$rel_path"
        fi
    done < <(find "$BACKUP_DIR" -type f)

    ldconfig 2>/dev/null || true
    rm -rf "$BACKUP_DIR"
    ok "Original libcamera restored."
    echo ""
    exit 0
fi

# ─── Detect distro ───────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                DISTRO="debian"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            fedora)
                DISTRO="fedora"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            arch|manjaro|endeavouros)
                DISTRO="arch"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            opensuse*|suse*)
                DISTRO="suse"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            *)
                DISTRO="unknown"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
        esac
    else
        DISTRO="unknown"
        DISTRO_NAME="Unknown"
    fi
}

# ─── Detect installed libcamera version ──────────────────────────────
detect_libcamera_version() {
    LIBCAMERA_VERSION=""
    LIBCAMERA_GIT_TAG=""

    # Try pkg-config first
    if command -v pkg-config &>/dev/null; then
        LIBCAMERA_VERSION=$(pkg-config --modversion libcamera 2>/dev/null || true)
    fi

    # Try dpkg on Debian/Ubuntu
    if [[ -z "$LIBCAMERA_VERSION" ]] && command -v dpkg &>/dev/null; then
        LIBCAMERA_VERSION=$(dpkg -l 'libcamera*' 2>/dev/null | awk '/^ii.*libcamera0/ {print $3}' | head -1 || true)
    fi

    # Try rpm on Fedora
    if [[ -z "$LIBCAMERA_VERSION" ]] && command -v rpm &>/dev/null; then
        LIBCAMERA_VERSION=$(rpm -q --qf '%{VERSION}' libcamera 2>/dev/null || true)
        [[ "$LIBCAMERA_VERSION" == *"not installed"* ]] && LIBCAMERA_VERSION=""
    fi

    # Try pacman on Arch
    if [[ -z "$LIBCAMERA_VERSION" ]] && command -v pacman &>/dev/null; then
        LIBCAMERA_VERSION=$(pacman -Q libcamera 2>/dev/null | awk '{print $2}' || true)
    fi

    if [[ -z "$LIBCAMERA_VERSION" ]]; then
        die "Cannot detect installed libcamera version. Is libcamera installed?"
    fi

    # Extract version number (e.g., "0.6.0" from "0.6.0+53-f4f8b487-dirty" or "0.6.0-1.fc43")
    local ver_clean
    ver_clean=$(echo "$LIBCAMERA_VERSION" | grep -oP '^\d+\.\d+\.\d+' || true)

    if [[ -z "$ver_clean" ]]; then
        # Try alternate format (e.g., "0.6.0")
        ver_clean=$(echo "$LIBCAMERA_VERSION" | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
    fi

    if [[ -z "$ver_clean" ]]; then
        warn "Could not parse version from: $LIBCAMERA_VERSION"
        warn "Will try to build from latest source."
        LIBCAMERA_GIT_TAG="master"
        return
    fi

    LIBCAMERA_VERSION_CLEAN="$ver_clean"

    # Map to git tag
    LIBCAMERA_GIT_TAG="v${ver_clean}"
}

# ─── Install build dependencies ──────────────────────────────────────
install_deps_debian() {
    info "Installing build dependencies (Debian/Ubuntu)..."
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        git \
        meson \
        ninja-build \
        pkg-config \
        python3-yaml \
        python3-ply \
        python3-jinja2 \
        libgnutls28-dev \
        libudev-dev \
        libyaml-dev \
        libevent-dev \
        libgstreamer1.0-dev \
        libgstreamer-plugins-base1.0-dev \
        libdrm-dev \
        libjpeg-dev \
        libsdl2-dev \
        libtiff-dev \
        openssl \
        libssl-dev \
        libdw-dev \
        libunwind-dev \
        cmake
}

install_deps_fedora() {
    info "Installing build dependencies (Fedora)..."
    dnf install -y \
        git \
        meson \
        ninja-build \
        gcc \
        gcc-c++ \
        pkgconfig \
        python3-pyyaml \
        python3-ply \
        python3-jinja2 \
        gnutls-devel \
        systemd-devel \
        libyaml-devel \
        libevent-devel \
        gstreamer1-devel \
        gstreamer1-plugins-base-devel \
        libdrm-devel \
        libjpeg-turbo-devel \
        SDL2-devel \
        libtiff-devel \
        openssl-devel \
        elfutils-devel \
        libunwind-devel \
        cmake
}

install_deps_arch() {
    info "Installing build dependencies (Arch)..."
    pacman -S --noconfirm --needed \
        git \
        meson \
        ninja \
        pkgconf \
        python-yaml \
        python-ply \
        python-jinja \
        gnutls \
        systemd-libs \
        libyaml \
        libevent \
        gstreamer \
        gst-plugins-base \
        libdrm \
        libjpeg-turbo \
        sdl2 \
        libtiff \
        openssl \
        elfutils \
        libunwind \
        cmake
}

install_deps() {
    case "$DISTRO" in
        debian) install_deps_debian ;;
        fedora) install_deps_fedora ;;
        arch)   install_deps_arch ;;
        *)
            warn "Unknown distro '$DISTRO_NAME'. Skipping dependency installation."
            warn "You may need to install build dependencies manually."
            warn "Required: git meson ninja pkg-config python3-yaml python3-ply python3-jinja2"
            warn "          gnutls-dev libudev-dev libyaml-dev libevent-dev gstreamer-dev"
            ;;
    esac
}

# ─── Find libcamera .so files ────────────────────────────────────────
find_libcamera_libs() {
    LIBCAMERA_LIB_DIR=""

    # Check common locations
    for dir in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib /usr/local/lib64 /usr/local/lib; do
        if [[ -f "$dir/libcamera.so" ]] || ls "$dir"/libcamera.so.* &>/dev/null 2>&1; then
            LIBCAMERA_LIB_DIR="$dir"
            break
        fi
    done

    if [[ -z "$LIBCAMERA_LIB_DIR" ]]; then
        # Try ldconfig
        LIBCAMERA_LIB_DIR=$(ldconfig -p 2>/dev/null | grep 'libcamera.so ' | head -1 | sed 's|.*=> \(.*\)/libcamera.so.*|\1|' || true)
    fi

    if [[ -z "$LIBCAMERA_LIB_DIR" ]]; then
        die "Cannot find libcamera.so — is libcamera installed?"
    fi

    # Find IPA module directory
    LIBCAMERA_IPA_DIR=""
    for dir in /usr/lib64/libcamera /usr/lib/x86_64-linux-gnu/libcamera /usr/lib/libcamera /usr/local/lib64/libcamera /usr/local/lib/libcamera; do
        if [[ -d "$dir" ]]; then
            LIBCAMERA_IPA_DIR="$dir"
            break
        fi
    done
}

# ─── Apply patch using sed (more robust than patch files) ────────────
apply_patch_sed() {
    local simple_cpp="$BUILD_DIR/libcamera/src/libcamera/pipeline/simple/simple.cpp"

    if [[ ! -f "$simple_cpp" ]]; then
        die "Cannot find simple.cpp at expected path: $simple_cpp"
    fi

    info "Applying bayer order fix..."

    # NEW APPROACH: Don't touch videoFormat (V4L2 rejects format changes).
    # Instead, only override inputCfg.pixelFormat which goes directly to
    # the SoftISP debayer. The debayer gets its bayer pattern ENTIRELY from
    # inputCfg.pixelFormat — it never queries V4L2.
    #
    # The patch replaces the single line:
    #   inputCfg.pixelFormat = pipeConfig->captureFormat;     (v0.5)
    #   inputCfg.pixelFormat = videoFormat.toPixelFormat();   (v0.6+)
    # with code that computes the correct bayer order based on sensor transform.

    python3 - "$simple_cpp" << 'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# The replacement code: compute corrected bayer order for SoftISP debayer
replacement_block = r'''{
\t\t/*
\t\t * Override the bayer order for the SoftISP debayer based on the
\t\t * actual sensor transform. Some sensors (e.g. OV02E10) set
\t\t * V4L2_CTRL_FLAG_MODIFY_LAYOUT on flip controls but never update
\t\t * the media bus format code. The V4L2 capture format stays as the
\t\t * native bayer order, but the physical pixel data has shifted.
\t\t * We leave the V4L2 format unchanged (driver rejects changes) and
\t\t * only tell the SoftISP debayer the correct pattern.
\t\t */
\t\tBayerFormat inputBayer = BayerFormat::fromPixelFormat(ORIGINAL_EXPR);
\t\tif (inputBayer.isValid()) {
\t\t\tinputBayer.order = data->sensor_->bayerOrder(config->combinedTransform());
\t\t\tinputCfg.pixelFormat = inputBayer.toPixelFormat();
\t\t} else {
\t\t\tinputCfg.pixelFormat = ORIGINAL_EXPR;
\t\t}
\t}'''

patched = False

# Try v0.6+ pattern first: inputCfg.pixelFormat = videoFormat.toPixelFormat();
v06_pattern = r'inputCfg\.pixelFormat\s*=\s*videoFormat\.toPixelFormat\(\)\s*;'
m = re.search(v06_pattern, content)
if m:
    # Get the indentation
    line_start = content.rfind('\n', 0, m.start()) + 1
    indent = re.match(r'^(\s*)', content[line_start:]).group(1)

    block = replacement_block.replace('ORIGINAL_EXPR', 'videoFormat.toPixelFormat()')
    # Fix indentation - use actual indent from source
    block = block.replace('\\t', '\t')
    lines = block.split('\n')
    indented = '\n'.join(indent + line.lstrip('{').rstrip('}') if i > 0 and i < len(lines)-1
                         else line for i, line in enumerate(lines))

    # Actually, let's just do a clean replacement
    new_code = (
        f'/*\n'
        f'{indent} * Override bayer order for SoftISP based on actual sensor transform.\n'
        f'{indent} * OV02E10 sets MODIFY_LAYOUT but never updates format code.\n'
        f'{indent} * V4L2 format stays unchanged; only the debayer input is corrected.\n'
        f'{indent} */\n'
        f'{indent}BayerFormat inputBayer = BayerFormat::fromPixelFormat(videoFormat.toPixelFormat());\n'
        f'{indent}if (inputBayer.isValid()) {{\n'
        f'{indent}\tinputBayer.order = data->sensor_->bayerOrder(config->combinedTransform());\n'
        f'{indent}\tinputCfg.pixelFormat = inputBayer.toPixelFormat();\n'
        f'{indent}}} else {{\n'
        f'{indent}\tinputCfg.pixelFormat = videoFormat.toPixelFormat();\n'
        f'{indent}}}'
    )

    result = content[:m.start()] + new_code + content[m.end():]
    patched = True
    print("Patched v0.6+ inputCfg.pixelFormat with bayer order override")

# Try v0.5 pattern: inputCfg.pixelFormat = pipeConfig->captureFormat;
if not patched:
    v05_pattern = r'inputCfg\.pixelFormat\s*=\s*pipeConfig->captureFormat\s*;'
    m = re.search(v05_pattern, content)
    if m:
        line_start = content.rfind('\n', 0, m.start()) + 1
        indent = re.match(r'^(\s*)', content[line_start:]).group(1)

        new_code = (
            f'/*\n'
            f'{indent} * Override bayer order for SoftISP based on actual sensor transform.\n'
            f'{indent} * OV02E10 sets MODIFY_LAYOUT but never updates format code.\n'
            f'{indent} * V4L2 format stays unchanged; only the debayer input is corrected.\n'
            f'{indent} */\n'
            f'{indent}BayerFormat inputBayer = BayerFormat::fromPixelFormat(pipeConfig->captureFormat);\n'
            f'{indent}if (inputBayer.isValid()) {{\n'
            f'{indent}\tinputBayer.order = data->sensor_->bayerOrder(config->combinedTransform());\n'
            f'{indent}\tinputCfg.pixelFormat = inputBayer.toPixelFormat();\n'
            f'{indent}}} else {{\n'
            f'{indent}\tinputCfg.pixelFormat = pipeConfig->captureFormat;\n'
            f'{indent}}}'
        )

        result = content[:m.start()] + new_code + content[m.end():]
        patched = True
        print("Patched v0.5 inputCfg.pixelFormat with bayer order override")

if not patched:
    # Check if already patched
    if 'inputBayer.order' in content and 'bayerOrder' in content:
        print("Source appears already patched (inputBayer.order + bayerOrder found)")
        result = content
    else:
        print("ERROR: Could not find inputCfg.pixelFormat assignment to patch", file=sys.stderr)
        print("Searched for both v0.5 and v0.6+ patterns.", file=sys.stderr)
        sys.exit(1)

with open(filepath, 'w') as f:
    f.write(result)
PYEOF

    if [[ $? -ne 0 ]]; then
        die "Failed to apply patch. The libcamera source may have an unexpected structure."
    fi

    ok "Patch applied successfully."
}

# ─── Detect meson build options from installed libcamera ─────────────
detect_build_options() {
    MESON_OPTIONS=(
        -Dgstreamer=enabled
        -Dv4l2=true
        -Dqcam=disabled
        -Dcam=disabled
        -Dlc-compliance=disabled
        -Dtest=false
        -Ddocumentation=disabled
    )

    # Check if system uses /usr/lib64 (Fedora) or /usr/lib/x86_64-linux-gnu (Debian)
    if [[ "$LIBCAMERA_LIB_DIR" == */lib64* ]]; then
        MESON_OPTIONS+=(-Dprefix=/usr -Dlibdir=lib64)
    elif [[ "$LIBCAMERA_LIB_DIR" == */x86_64-linux-gnu* ]]; then
        MESON_OPTIONS+=(-Dprefix=/usr -Dlibdir=lib/x86_64-linux-gnu)
    else
        MESON_OPTIONS+=(-Dprefix=/usr)
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────

echo ""
echo "=============================================="
echo "  libcamera Bayer Order Fix Builder"
echo "  (OV02E10 purple tint fix)"
echo "=============================================="
echo ""

# Step 1: Detect environment
info "Detecting environment..."
detect_distro
ok "Distro: $DISTRO_NAME ($DISTRO)"

detect_libcamera_version
ok "libcamera version: $LIBCAMERA_VERSION (tag: $LIBCAMERA_GIT_TAG)"

find_libcamera_libs
ok "Library dir: $LIBCAMERA_LIB_DIR"
[[ -n "${LIBCAMERA_IPA_DIR:-}" ]] && ok "IPA dir: $LIBCAMERA_IPA_DIR"

echo ""

# Step 2: Install build dependencies
info "Installing build dependencies..."
install_deps
ok "Build dependencies installed."
echo ""

# Step 3: Clone source
info "Cloning libcamera source (${LIBCAMERA_GIT_TAG})..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Clone with depth 1 for speed
if ! git clone --depth 1 --branch "$LIBCAMERA_GIT_TAG" \
    https://git.libcamera.org/libcamera/libcamera.git \
    "$BUILD_DIR/libcamera" 2>&1; then

    warn "Could not clone tag $LIBCAMERA_GIT_TAG — trying master..."
    git clone --depth 1 \
        https://git.libcamera.org/libcamera/libcamera.git \
        "$BUILD_DIR/libcamera" 2>&1
    LIBCAMERA_GIT_TAG="master"

    # Re-detect version from source
    if [[ -f "$BUILD_DIR/libcamera/meson.build" ]]; then
        SRC_VER=$(grep "version :" "$BUILD_DIR/libcamera/meson.build" | head -1 | grep -oP "'[\d.]+'") || true
        [[ -n "$SRC_VER" ]] && info "Source version: $SRC_VER"
    fi
fi

ok "Source cloned."
echo ""

# Step 4: Apply patch
apply_patch_sed
echo ""

# Step 5: Verify patch
info "Verifying patch..."
if grep -q 'inputBayer.order' "$BUILD_DIR/libcamera/src/libcamera/pipeline/simple/simple.cpp"; then
    ok "Patch verified — bayer order override for SoftISP debayer present."
else
    die "Patch verification failed — inputBayer.order not found in patched source."
fi
echo ""

# Step 6: Configure and build
info "Configuring build with meson..."
detect_build_options

cd "$BUILD_DIR/libcamera"
meson setup builddir "${MESON_OPTIONS[@]}" 2>&1 | tail -20

info "Building (this may take 5-10 minutes)..."
ninja -C builddir 2>&1 | tail -5

ok "Build completed."
echo ""

# Step 7: Backup originals
info "Backing up original libcamera files..."
mkdir -p "$BACKUP_DIR/$LIBCAMERA_LIB_DIR"

for f in "$LIBCAMERA_LIB_DIR"/libcamera*.so*; do
    if [[ -f "$f" ]]; then
        cp -a "$f" "$BACKUP_DIR/$LIBCAMERA_LIB_DIR/"
    fi
done

# Backup IPA modules too
if [[ -n "${LIBCAMERA_IPA_DIR:-}" && -d "$LIBCAMERA_IPA_DIR" ]]; then
    mkdir -p "$BACKUP_DIR/$LIBCAMERA_IPA_DIR"
    cp -a "$LIBCAMERA_IPA_DIR"/* "$BACKUP_DIR/$LIBCAMERA_IPA_DIR/" 2>/dev/null || true
fi

ok "Originals backed up to $BACKUP_DIR"
echo ""

# Step 8: Install
info "Installing patched libcamera..."
cd "$BUILD_DIR/libcamera"
ninja -C builddir install 2>&1 | tail -10
ldconfig 2>/dev/null || true

ok "Patched libcamera installed."
echo ""

# Step 9: Verify installation
info "Verifying installation..."
INSTALLED_LIB=$(find "$LIBCAMERA_LIB_DIR" -name 'libcamera.so.*' -newer "$BACKUP_DIR" -print -quit 2>/dev/null || true)
if [[ -n "$INSTALLED_LIB" ]]; then
    ok "Verified: $INSTALLED_LIB is newer than backup."
else
    warn "Could not verify installation timestamp. Library may need ldconfig."
fi

# Cleanup build directory
rm -rf "$BUILD_DIR"

echo ""
echo "=============================================="
echo "  Installation Complete!"
echo "=============================================="
echo ""
echo "  The patched libcamera has been installed."
echo "  Original files backed up to: $BACKUP_DIR"
echo ""
echo "  To test: Open a camera app (Firefox, Chrome, qcam)"
echo "           Colors should now be correct (no purple tint)."
echo ""
echo "  To uninstall and restore original:"
echo "    sudo $0 --uninstall"
echo ""
echo "  NOTE: System updates may overwrite the patched library."
echo "  If purple tint returns after an update, re-run this script."
echo ""
