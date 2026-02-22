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

    # Determine which patch to use
    local major minor
    major=$(echo "$ver_clean" | cut -d. -f1)
    minor=$(echo "$ver_clean" | cut -d. -f2)

    if [[ "$major" -eq 0 && "$minor" -le 5 ]]; then
        PATCH_FILE="$SCRIPT_DIR/bayer-fix-v0.5.patch"
        PATCH_VERSION="v0.5"
    else
        PATCH_FILE="$SCRIPT_DIR/bayer-fix-v0.6.patch"
        PATCH_VERSION="v0.6+"
    fi
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

    info "Applying bayer order fix (${PATCH_VERSION})..."

    if [[ "$PATCH_VERSION" == "v0.5" ]]; then
        # v0.5.x: Replace the simple one-liner
        # Find: V4L2PixelFormat videoFormat = video->toV4L2PixelFormat(pipeConfig->captureFormat);
        # Replace with unconditional bayer computation
        python3 - "$simple_cpp" << 'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Pattern 1: Replace the video format line (consume original comment too)
old_pattern = r'\t/\* Configure the video node\. \*/\n\tV4L2PixelFormat videoFormat = video->toV4L2PixelFormat\(pipeConfig->captureFormat\);'
new_code = r'''\t/* Configure the video node, always accounting for Bayer pattern changes from transforms. */
\tV4L2PixelFormat videoFormat;
\tBayerFormat cfgBayer = BayerFormat::fromPixelFormat(pipeConfig->captureFormat);
\tif (cfgBayer.isValid()) {
\t\t/*
\t\t * Always recalculate the Bayer order based on the sensor transform.
\t\t * Some sensors (e.g. OV02E10) set V4L2_CTRL_FLAG_MODIFY_LAYOUT on
\t\t * flip controls but never update the media bus format code, so we
\t\t * cannot rely on format.code != pipeConfig->code to detect changes.
\t\t */
\t\tcfgBayer.order = data->sensor_->bayerOrder(config->combinedTransform());
\t\tvideoFormat = cfgBayer.toV4L2PixelFormat();
\t} else {
\t\tvideoFormat = video->toV4L2PixelFormat(pipeConfig->captureFormat);
\t}'''

result, count = re.subn(old_pattern, new_code, content)
if count == 0:
    # Try without the comment (some versions differ)
    old_pattern2 = r'\tV4L2PixelFormat videoFormat = video->toV4L2PixelFormat\(pipeConfig->captureFormat\);'
    new_code2 = '''\t/* Configure the video node, always accounting for Bayer pattern changes from transforms. */
\tV4L2PixelFormat videoFormat;
\tBayerFormat cfgBayer = BayerFormat::fromPixelFormat(pipeConfig->captureFormat);
\tif (cfgBayer.isValid()) {
\t\tcfgBayer.order = data->sensor_->bayerOrder(config->combinedTransform());
\t\tvideoFormat = cfgBayer.toV4L2PixelFormat();
\t} else {
\t\tvideoFormat = video->toV4L2PixelFormat(pipeConfig->captureFormat);
\t}'''
    result, count = re.subn(old_pattern2, new_code2, result if count > 0 else content, count=1)

if count == 0:
    print("ERROR: Could not find video format pattern to patch (hunk 1)", file=sys.stderr)
    sys.exit(1)

# Pattern 2: Replace inputCfg.pixelFormat
old_input = r'inputCfg\.pixelFormat = pipeConfig->captureFormat;'
new_input = 'inputCfg.pixelFormat = videoFormat.toPixelFormat();'
result, count2 = re.subn(old_input, new_input, result, count=1)

if count2 == 0:
    print("WARNING: Could not find inputCfg.pixelFormat pattern (hunk 2) — may already be patched", file=sys.stderr)

with open(filepath, 'w') as f:
    f.write(result)

print(f"Patched {count} + {count2} locations in {filepath}")
PYEOF

    else
        # v0.6+: Replace the conditional block with unconditional
        python3 - "$simple_cpp" << 'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Pattern 1: Find the conditional bayer order block and make it unconditional
# Match the entire if/else block
old_pattern = (
    r'(/\* Configure the video node.*?\*/\n)'
    r'(\s+)V4L2PixelFormat videoFormat;\n'
    r'\s+if \(format\.code == pipeConfig->code\) \{\n'
    r'\s+videoFormat = video->toV4L2PixelFormat\(pipeConfig->captureFormat\);\n'
    r'\s+\} else \{\n'
    r'(?:\s+/\*.*?\*/\n)?'  # optional comment block
    r'(?:\s+\*.*?\n)*'      # continuation of comment
    r'\s+BayerFormat cfgBayer = BayerFormat::fromPixelFormat\(pipeConfig->captureFormat\);\n'
    r'\s+cfgBayer\.order = data->sensor_->bayerOrder\(config->combinedTransform\(\)\);\n'
    r'\s+videoFormat = cfgBayer\.toV4L2PixelFormat\(\);\n'
    r'\s+\}'
)

new_code = (
    r'/* Configure the video node, always accounting for Bayer pattern changes from transforms. */\n'
    r'\2V4L2PixelFormat videoFormat;\n'
    r'\2BayerFormat cfgBayer = BayerFormat::fromPixelFormat(pipeConfig->captureFormat);\n'
    r'\2if (cfgBayer.isValid()) {\n'
    r'\2\t/*\n'
    r'\2\t * Always recalculate the Bayer order based on the sensor transform.\n'
    r'\2\t * Some sensors (e.g. OV02E10) set V4L2_CTRL_FLAG_MODIFY_LAYOUT on\n'
    r'\2\t * flip controls but never update the media bus format code, so we\n'
    r'\2\t * cannot rely on format.code != pipeConfig->code to detect changes.\n'
    r'\2\t */\n'
    r'\2\tcfgBayer.order = data->sensor_->bayerOrder(config->combinedTransform());\n'
    r'\2\tvideoFormat = cfgBayer.toV4L2PixelFormat();\n'
    r'\2} else {\n'
    r'\2\tvideoFormat = video->toV4L2PixelFormat(pipeConfig->captureFormat);\n'
    r'\2}'
)

result, count = re.subn(old_pattern, new_code, content, flags=re.DOTALL)

if count == 0:
    # Simpler fallback: just look for the key conditional
    print("Trying simplified pattern match...", file=sys.stderr)

    old_simple = r'if \(format\.code == pipeConfig->code\) \{'
    if re.search(old_simple, content):
        # Found the conditional — do line-by-line replacement
        lines = content.split('\n')
        new_lines = []
        i = 0
        patched = False
        while i < len(lines):
            line = lines[i]
            # Look for the start of the conditional block
            if not patched and 'format.code == pipeConfig->code' in line:
                # Get indentation
                indent = re.match(r'^(\s*)', line).group(1)

                # Find the closing brace of the else block
                brace_depth = 0
                j = i
                while j < len(lines):
                    brace_depth += lines[j].count('{') - lines[j].count('}')
                    if brace_depth == 0:
                        break
                    j += 1

                # Replace the entire if/else block plus preceding lines
                # Walk back to remove:
                #   - "V4L2PixelFormat videoFormat;" line (we replace it)
                #   - Any comment block above it (we replace it)
                remove_count = 0
                # Check for "V4L2PixelFormat videoFormat;" on the line before the if
                if i > 0 and 'V4L2PixelFormat videoFormat;' in lines[i-1]:
                    remove_count += 1
                    # Check for comment block above the variable declaration
                    check_idx = i - 1 - remove_count
                    if check_idx >= 0 and ('*/' in lines[check_idx] or '/*' in lines[check_idx]):
                        # Single-line or multi-line comment ending here
                        remove_count += 1
                        while check_idx - (remove_count - 1) >= 0:
                            test_line = lines[i - 1 - remove_count]
                            if '/*' in test_line:
                                break
                            remove_count += 1
                if remove_count > 0:
                    new_lines = new_lines[:-remove_count]

                new_lines.append(f'{indent}/* Configure the video node, always accounting for Bayer pattern changes from transforms. */')
                new_lines.append(f'{indent}V4L2PixelFormat videoFormat;')
                new_lines.append(f'{indent}BayerFormat cfgBayer = BayerFormat::fromPixelFormat(pipeConfig->captureFormat);')
                new_lines.append(f'{indent}if (cfgBayer.isValid()) {{')
                new_lines.append(f'{indent}\t/*')
                new_lines.append(f'{indent}\t * Always recalculate the Bayer order based on the sensor transform.')
                new_lines.append(f'{indent}\t * Some sensors (e.g. OV02E10) set V4L2_CTRL_FLAG_MODIFY_LAYOUT on')
                new_lines.append(f'{indent}\t * flip controls but never update the media bus format code, so we')
                new_lines.append(f'{indent}\t * cannot rely on format.code != pipeConfig->code to detect changes.')
                new_lines.append(f'{indent}\t */')
                new_lines.append(f'{indent}\tcfgBayer.order = data->sensor_->bayerOrder(config->combinedTransform());')
                new_lines.append(f'{indent}\tvideoFormat = cfgBayer.toV4L2PixelFormat();')
                new_lines.append(f'{indent}}} else {{')
                new_lines.append(f'{indent}\tvideoFormat = video->toV4L2PixelFormat(pipeConfig->captureFormat);')
                new_lines.append(f'{indent}}}')

                i = j + 1
                patched = True
                count = 1
                continue

            new_lines.append(line)
            i += 1

        if patched:
            result = '\n'.join(new_lines)
        else:
            print("ERROR: Found conditional but could not replace it", file=sys.stderr)
            sys.exit(1)
    else:
        # Check if already patched
        if 'cfgBayer.isValid()' in content and 'bayerOrder' in content:
            print("Source appears to already be patched (cfgBayer.isValid + bayerOrder found)", file=sys.stderr)
            result = content
            count = 1
        else:
            print("ERROR: Could not find the conditional bayer order block to patch", file=sys.stderr)
            print("The libcamera source may have a different structure than expected.", file=sys.stderr)
            sys.exit(1)

# Pattern 2: Replace inputCfg.pixelFormat if not already done
old_input = r'inputCfg\.pixelFormat = pipeConfig->captureFormat;'
new_input = 'inputCfg.pixelFormat = videoFormat.toPixelFormat();'
result, count2 = re.subn(old_input, new_input, result, count=1)

if count2 == 0:
    if 'videoFormat.toPixelFormat()' in result:
        print("inputCfg.pixelFormat already uses videoFormat — OK", file=sys.stderr)
        count2 = 1
    else:
        print("WARNING: Could not find inputCfg.pixelFormat pattern (hunk 2)", file=sys.stderr)

with open(filepath, 'w') as f:
    f.write(result)

print(f"Patched {count} + {count2} locations in {filepath}")
PYEOF
    fi

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
ok "Patch version: $PATCH_VERSION"

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
if grep -q 'cfgBayer.isValid()' "$BUILD_DIR/libcamera/src/libcamera/pipeline/simple/simple.cpp"; then
    ok "Patch verified — unconditional bayer order computation present."
else
    die "Patch verification failed — cfgBayer.isValid() not found in patched source."
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
