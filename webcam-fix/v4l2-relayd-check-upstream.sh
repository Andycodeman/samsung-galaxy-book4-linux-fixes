#!/bin/bash
# Check if the running kernel has native IPU6 webcam support.
# When the kernel + libcamera handle the full pipeline natively,
# this script auto-removes the v4l2-relayd workaround.
#
# On the boot where upstream is first detected:
#   - Camera may already work (relay loaded earlier in boot)
#   - This script removes relay service, watchdog, configs
#   - Next reboot uses native libcamera pipeline instead
#
# What "native support" means for the IPU6 webcam:
#   1. IVSC modules auto-load via ACPI aliases (no /etc/modules-load.d/ hack)
#   2. libcamera has a working IPU6 pipeline handler
#   3. PipeWire exposes the camera via libcamera SPA plugin (no v4l2-relayd)

UPSTREAM_READY=true

log() { echo "v4l2-relayd-check: $*"; }

# --- Check 1: IVSC modules have proper ACPI aliases ---
# Currently, mei-vsc doesn't auto-load because it lacks modalias entries
# matching the ACPI hardware IDs (e.g., INTC10CF for Meteor Lake IVSC).
# When upstream fixes this, modinfo will show the alias.
if ! modinfo mei_vsc 2>/dev/null | grep -q "alias:.*acpi"; then
    UPSTREAM_READY=false
    log "mei-vsc: missing ACPI modalias (IVSC won't auto-load)"
fi

# --- Check 2: libcamera IPU6 pipeline handler exists ---
# When libcamera supports IPU6 natively, it ships a pipeline handler .so.
# Check standard library paths for it.
IPU6_HANDLER=""
for dir in /usr/lib/*/libcamera /usr/lib/libcamera /usr/local/lib/*/libcamera /usr/local/lib/libcamera; do
    if ls "${dir}/"*ipu6* 2>/dev/null | grep -q .; then
        IPU6_HANDLER="found"
        break
    fi
done
if [ -z "$IPU6_HANDLER" ]; then
    UPSTREAM_READY=false
    log "libcamera: IPU6 pipeline handler not found"
fi

# --- Check 3: libcamera can actually enumerate the camera ---
# The pipeline handler existing isn't enough — it must work with this
# kernel version and detect the OV02C10 sensor. Use cam -l if available,
# otherwise check the libcamera SPA plugin's device list.
CAMERA_ENUMERATED=false
if command -v cam &>/dev/null; then
    if LIBCAMERA_LOG_LEVELS="*:ERROR" cam -l 2>/dev/null | grep -qi "ipu6\|ov02c10\|OVTI02C1"; then
        CAMERA_ENUMERATED=true
    fi
fi
# Fallback: check if PipeWire's libcamera SPA plugin sees the camera
# (requires pw-cli, works in system context)
if ! $CAMERA_ENUMERATED && command -v pw-cli &>/dev/null; then
    if pw-cli list-objects 2>/dev/null | grep -qi "libcamera.*ipu6\|libcamera.*ov02c10"; then
        CAMERA_ENUMERATED=true
    fi
fi
if ! $CAMERA_ENUMERATED; then
    UPSTREAM_READY=false
    log "libcamera: cannot enumerate IPU6 camera (pipeline handler may not work with this kernel)"
fi

if ! $UPSTREAM_READY; then
    log "upstream not available yet in $(uname -r) — v4l2-relayd workaround still needed"
    exit 0
fi

# --- All checks passed: native support is in this kernel ---
log "=== NATIVE SUPPORT DETECTED in $(uname -r) ==="
log "Auto-removing v4l2-relayd workaround..."

# Stop relay and watchdog
systemctl stop v4l2-relayd@default 2>/dev/null || true
systemctl stop v4l2-relayd-watchdog.timer 2>/dev/null || true
systemctl disable v4l2-relayd 2>/dev/null || true
systemctl disable v4l2-relayd-watchdog.timer 2>/dev/null || true

# Disable this check service too (remove ourselves)
systemctl disable v4l2-relayd-check-upstream.service 2>/dev/null || true

# Remove relay config and overrides
rm -f /etc/v4l2-relayd.d/default.conf
rm -rf /etc/systemd/system/v4l2-relayd@default.service.d
rm -f /etc/modprobe.d/v4l2loopback.conf

# Remove IVSC manual loading config (native aliases handle it now)
rm -f /etc/modules-load.d/ivsc.conf
rm -f /etc/modprobe.d/ivsc-camera.conf

# Remove IVSC entries from initramfs
if [ -f /etc/initramfs-tools/modules ]; then
    for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
        sed -i "/^${mod}$/d" /etc/initramfs-tools/modules
    done
    log "Rebuilding initramfs..."
    update-initramfs -u 2>/dev/null || true
fi

# Remove udev rules (IPU6 nodes are handled properly by libcamera now)
rm -f /etc/udev/rules.d/90-hide-ipu6-v4l2.rules
udevadm control --reload-rules 2>/dev/null || true

# Remove resolution detection script and runtime env
rm -f /usr/local/sbin/v4l2-relayd-detect-resolution.sh
rm -f /run/v4l2-relayd-resolution.env

# Remove watchdog files
rm -f /usr/local/sbin/v4l2-relayd-watchdog.sh
rm -f /etc/systemd/system/v4l2-relayd-watchdog.service
rm -f /etc/systemd/system/v4l2-relayd-watchdog.timer
rm -rf /run/v4l2-relayd-watchdog

# Remove this check script and service
rm -f /etc/systemd/system/v4l2-relayd-check-upstream.service
rm -f /usr/local/sbin/v4l2-relayd-check-upstream.sh

systemctl daemon-reload

log "Done. Native libcamera pipeline will take over on next reboot."
log "Camera may need a logout/login or reboot to appear in apps via PipeWire."
