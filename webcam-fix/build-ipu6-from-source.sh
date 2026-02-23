#!/bin/bash
# build-ipu6-from-source.sh
# Build Intel IPU6 camera HAL stack from source for non-Ubuntu distros
#
# This script builds and installs:
#   - ipu6-camera-bins (firmware, libraries, headers)
#   - ipu6-camera-hal (camera HAL library)
#   - icamerasrc (GStreamer plugin)
#
# These are normally available as pre-built packages from Ubuntu's Intel PPA,
# but for Fedora, Arch, and other distros they must be built from source.
#
# Usage: sudo ./build-ipu6-from-source.sh [--uninstall]
#
# The build takes ~2-5 minutes and requires ~500 MB of disk space.
# Build artifacts are placed in /opt/intel/ipu6-build/ for easy cleanup.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/opt/intel/ipu6-build"
BACKUP_DIR="/var/lib/ipu6-hal-backup"
STAMP_FILE="/var/lib/ipu6-hal-backup/.source-build-stamp"

# Intel repos
CAMERA_BINS_REPO="https://github.com/intel/ipu6-camera-bins"
CAMERA_HAL_REPO="https://github.com/intel/ipu6-camera-hal"
ICAMERASRC_REPO="https://github.com/intel/icamerasrc"

echo "=============================================="
echo "  Intel IPU6 Camera HAL — Source Build"
echo "=============================================="
echo ""

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# --- Detect distro ---
detect_distro() {
    if command -v pacman >/dev/null 2>&1; then
        DISTRO="arch"
    elif command -v dnf >/dev/null 2>&1; then
        DISTRO="fedora"
    elif command -v apt >/dev/null 2>&1; then
        DISTRO="debian"
    else
        DISTRO="unknown"
    fi
}
detect_distro

# Determine library directory (Fedora uses lib64)
if [[ "$DISTRO" == "fedora" ]]; then
    LIBDIR="lib64"
else
    LIBDIR="lib"
fi

# Architecture-specific multilib path (for GStreamer plugin)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) MULTIARCH="x86_64-linux-gnu" ;;
    aarch64) MULTIARCH="aarch64-linux-gnu" ;;
    *) MULTIARCH="$ARCH-linux-gnu" ;;
esac

# --- Uninstall mode ---
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Uninstalling source-built IPU6 camera HAL..."
    echo ""

    if [[ ! -f "$STAMP_FILE" ]]; then
        echo "No source build installation found (missing $STAMP_FILE)."
        echo "Nothing to uninstall."
        exit 0
    fi

    # Restore backed-up files if any
    if [[ -d "$BACKUP_DIR/files" ]]; then
        echo "Restoring original files from backup..."
        cp -a "$BACKUP_DIR/files/." / 2>/dev/null || true
        echo "  Done."
    fi

    # Remove installed files
    echo "Removing source-built files..."
    rm -f /usr/lib/$MULTIARCH/gstreamer-1.0/libgsticamerasrc.so 2>/dev/null || true
    rm -f /usr/$LIBDIR/gstreamer-1.0/libgsticamerasrc.so 2>/dev/null || true
    rm -rf /usr/include/libcamhal 2>/dev/null || true
    rm -f /usr/$LIBDIR/libcamhal.so* 2>/dev/null || true
    rm -f /usr/lib/libcamhal.so* 2>/dev/null || true
    rm -f /usr/$LIBDIR/pkgconfig/libcamhal.pc 2>/dev/null || true
    rm -f /usr/lib/pkgconfig/libcamhal.pc 2>/dev/null || true

    # Remove firmware (only if we installed it)
    if [[ -f "$BACKUP_DIR/.firmware-installed" ]]; then
        rm -rf /usr/share/defaults/etc/camera 2>/dev/null || true
    fi

    # Remove build directory
    rm -rf "$BUILD_DIR"

    # Remove backup/stamp
    rm -rf "$BACKUP_DIR"

    ldconfig
    echo ""
    echo "  Source-built IPU6 HAL has been uninstalled."
    exit 0
fi

# --- Build mode ---
echo "This will build and install the Intel IPU6 camera HAL from source."
echo "Build directory: $BUILD_DIR"
echo "Detected distro: $DISTRO"
echo "Library path:    /usr/$LIBDIR"
echo ""

# --- Install build dependencies ---
echo "[1/6] Installing build dependencies..."
case "$DISTRO" in
    fedora)
        dnf install -y --setopt=install_weak_deps=False \
            cmake gcc gcc-c++ make automake autoconf libtool git pkg-config \
            libdrm-devel expat-devel \
            gstreamer1-devel gstreamer1-plugins-base-devel \
            gstreamer1-plugins-bad-free-devel \
            libva-devel
        ;;
    arch)
        pacman -S --needed --noconfirm \
            cmake gcc make automake autoconf libtool git pkg-config \
            libdrm expat \
            gstreamer gst-plugins-base gst-plugins-bad \
            libva
        ;;
    debian)
        apt update -qq
        apt install -y \
            cmake gcc g++ make automake autoconf libtool git pkg-config \
            libdrm-dev libexpat-dev \
            libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
            libgstreamer-plugins-bad1.0-dev \
            libva-dev
        ;;
    *)
        echo "ERROR: Unsupported distro. Please install build dependencies manually:"
        echo "  cmake, gcc, g++, make, automake, autoconf, libtool, git, pkg-config,"
        echo "  libdrm-dev, libexpat-dev, gstreamer-1.0 dev packages, libva-dev"
        exit 1
        ;;
esac
echo "  Done."

# --- Clone repos ---
echo ""
echo "[2/6] Cloning Intel IPU6 repositories..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

git clone --depth 1 "$CAMERA_BINS_REPO" ipu6-camera-bins
git clone --depth 1 "$CAMERA_HAL_REPO" ipu6-camera-hal
git clone --depth 1 -b icamerasrc_slim_api "$ICAMERASRC_REPO" icamerasrc
echo "  Done."

# --- Install camera-bins (firmware + prebuilt libs + headers) ---
echo ""
echo "[3/6] Installing camera firmware and binary libraries..."
mkdir -p "$BACKUP_DIR/files"

cd "$BUILD_DIR/ipu6-camera-bins"

# Detect which IPU6 variant (Meteor Lake = ipu6epmtl)
IPU_VARIANT="ipu6epmtl"

# Install firmware
if [[ -d "ipu6epmtl/lib/firmware" ]]; then
    cp -a ipu6epmtl/lib/firmware/* /lib/firmware/ 2>/dev/null || true
fi

# Install config files
if [[ -d "ipu6epmtl/share/defaults/etc/camera" ]]; then
    mkdir -p /usr/share/defaults/etc/camera
    cp -a ipu6epmtl/share/defaults/etc/camera/* /usr/share/defaults/etc/camera/
    touch "$BACKUP_DIR/.firmware-installed"
fi

# Install prebuilt libraries
for lib in ipu6epmtl/lib/*.so*; do
    [[ -f "$lib" ]] || continue
    cp -a "$lib" /usr/$LIBDIR/
done

# Install headers
if [[ -d "ipu6epmtl/include" ]]; then
    mkdir -p /usr/include/libcamhal
    cp -a ipu6epmtl/include/* /usr/include/libcamhal/
fi

# Install pkgconfig
for pc in ipu6epmtl/lib/pkgconfig/*.pc; do
    [[ -f "$pc" ]] || continue
    mkdir -p /usr/$LIBDIR/pkgconfig
    # Fix paths in pkgconfig files
    sed "s|/usr/lib|/usr/$LIBDIR|g" "$pc" > /usr/$LIBDIR/pkgconfig/$(basename "$pc")
done

ldconfig
echo "  Done."

# --- Build camera-hal ---
echo ""
echo "[4/6] Building camera HAL (this may take a minute)..."
cd "$BUILD_DIR/ipu6-camera-hal"
mkdir -p build && cd build

# Set environment for camera-bins location
export PKG_CONFIG_PATH="/usr/$LIBDIR/pkgconfig:${PKG_CONFIG_PATH:-}"

cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR="/usr/$LIBDIR" \
      -DBUILD_CAMHAL_ADAPTOR=ON \
      -DBUILD_CAMHAL_PLUGIN=ON \
      -DIPU_VERSIONS="ipu6;ipu6ep;ipu6epmtl" \
      -DUSE_PG_LITE_PIPE=ON \
      ..

make -j$(nproc)

# Backup existing HAL library if present (e.g. from distro package)
if [[ -f "/usr/$LIBDIR/libcamhal.so" ]] && [[ ! -L "/usr/$LIBDIR/libcamhal.so" || -f "$(readlink -f /usr/$LIBDIR/libcamhal.so)" ]]; then
    mkdir -p "$BACKUP_DIR/files/usr/$LIBDIR"
    cp -a /usr/$LIBDIR/libcamhal.so* "$BACKUP_DIR/files/usr/$LIBDIR/" 2>/dev/null || true
fi

make install
ldconfig
echo "  Done."

# --- Build icamerasrc GStreamer plugin ---
echo ""
echo "[5/6] Building icamerasrc GStreamer plugin..."
cd "$BUILD_DIR/icamerasrc"

export CHROME_SLIM_CAMHAL=ON
export CAMHAL_HEADERS_INSTALL_DIR=/usr/include/libcamhal

# Run autogen/configure
./autogen.sh
./configure --prefix=/usr --libdir=/usr/$LIBDIR
make -j$(nproc)

# Determine GStreamer plugin directory
GST_PLUGIN_DIR=$(pkg-config --variable=pluginsdir gstreamer-1.0 2>/dev/null || echo "/usr/$LIBDIR/gstreamer-1.0")

# Backup existing plugin if present
if [[ -f "$GST_PLUGIN_DIR/libgsticamerasrc.so" ]]; then
    mkdir -p "$BACKUP_DIR/files/$GST_PLUGIN_DIR"
    cp -a "$GST_PLUGIN_DIR/libgsticamerasrc.so" "$BACKUP_DIR/files/$GST_PLUGIN_DIR/" 2>/dev/null || true
fi

make install

# Verify the plugin is in the right place
if ! [[ -f "$GST_PLUGIN_DIR/libgsticamerasrc.so" ]]; then
    # Some builds install to a different path; copy manually
    BUILT_SO=$(find "$BUILD_DIR/icamerasrc" -name "libgsticamerasrc.so" -path "*/libs/*" 2>/dev/null | head -1)
    if [[ -n "$BUILT_SO" ]]; then
        mkdir -p "$GST_PLUGIN_DIR"
        cp "$BUILT_SO" "$GST_PLUGIN_DIR/"
    fi
fi

ldconfig
echo "  Done."

# --- Mark installation ---
echo ""
echo "[6/6] Verifying installation..."
mkdir -p "$(dirname "$STAMP_FILE")"
echo "Built on $(date -Iseconds) from source" > "$STAMP_FILE"
echo "  DISTRO=$DISTRO" >> "$STAMP_FILE"
echo "  BUILD_DIR=$BUILD_DIR" >> "$STAMP_FILE"

# Verify icamerasrc is usable
if gst-inspect-1.0 icamerasrc >/dev/null 2>&1; then
    echo "  icamerasrc GStreamer plugin: OK"
else
    echo "  WARNING: icamerasrc GStreamer plugin not found by gst-inspect."
    echo "  The plugin may need a GStreamer registry update or a reboot."
    echo "  Try: gst-inspect-1.0 --plugin icamerasrc"
fi

# Verify libcamhal
if ldconfig -p | grep -q libcamhal; then
    echo "  libcamhal library: OK"
else
    echo "  WARNING: libcamhal not found in ldconfig cache."
fi

echo ""
echo "=============================================="
echo "  IPU6 camera HAL built and installed."
echo ""
echo "  Build artifacts: $BUILD_DIR"
echo "  Backup location: $BACKUP_DIR"
echo ""
echo "  To uninstall: sudo $0 --uninstall"
echo "=============================================="
