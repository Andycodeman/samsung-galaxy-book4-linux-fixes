#!/bin/bash
# v4l2-relayd-watchdog.sh — Detect blank frames and auto-recover the relay
#
# Called by v4l2-relayd-watchdog.timer every 3 minutes.
# After 3 consecutive blank-frame detections, restarts the relay with a
# full ISYS unbind/rebind + sensor re-probe to recover the CSI-2 link.
#
# Installed to /usr/local/sbin/v4l2-relayd-watchdog.sh

set -euo pipefail

LOOPBACK_DEV="/dev/video0"
FAIL_DIR="/run/v4l2-relayd-watchdog"
FAIL_COUNT_FILE="$FAIL_DIR/fail_count"
GRACE_SECONDS=30
MAX_FAILURES=3
MIN_JPEG_BYTES=10240  # 10KB — real frames are 15-200KB; blank < 8KB

ISYS_DEVICE="intel_ipu6.isys.40"
ISYS_DRIVER_PATH="/sys/bus/auxiliary/drivers/intel_ipu6_isys.isys"
SHM_KEY="0x0043414d"  # icamerasrc shared memory key

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: $*"; }

# --- Guards ---

# Relay must be active
if ! systemctl is-active --quiet v4l2-relayd@default; then
    log "relay not active, skipping"
    exit 0
fi

# Grace period after relay start — don't check during initialization
ACTIVE_ENTER=$(systemctl show v4l2-relayd@default --property=ActiveEnterTimestamp --value 2>/dev/null)
if [[ -n "$ACTIVE_ENTER" ]]; then
    START_EPOCH=$(date -d "$ACTIVE_ENTER" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    ELAPSED=$(( NOW_EPOCH - START_EPOCH ))
    if (( ELAPSED < GRACE_SECONDS )); then
        log "grace period (${ELAPSED}s < ${GRACE_SECONDS}s since relay start), skipping"
        exit 0
    fi
fi

# Lid closed — camera physically covered, dark frames expected
LID_STATE=$(cat /proc/acpi/button/lid/LID0/state 2>/dev/null || echo "")
if echo "$LID_STATE" | grep -qi "closed"; then
    log "lid closed, skipping"
    exit 0
fi

# Loopback device must exist
if [[ ! -e "$LOOPBACK_DEV" ]]; then
    log "$LOOPBACK_DEV not found, skipping"
    exit 0
fi

# --- Capture a test frame ---

mkdir -p "$FAIL_DIR"
TMPFILE=$(mktemp /tmp/watchdog-frame-XXXXXX.jpg)
trap 'rm -f "$TMPFILE"' EXIT

CAPTURE_OK=false
if timeout 6 ffmpeg -f v4l2 -i "$LOOPBACK_DEV" -frames:v 1 -update 1 -y "$TMPFILE" 2>/dev/null; then
    if [[ -f "$TMPFILE" ]]; then
        FILE_SIZE=$(stat -c%s "$TMPFILE" 2>/dev/null || echo 0)
        if (( FILE_SIZE > MIN_JPEG_BYTES )); then
            CAPTURE_OK=true
        else
            log "frame too small: ${FILE_SIZE} bytes (threshold: ${MIN_JPEG_BYTES})"
        fi
    fi
else
    log "ffmpeg capture failed or timed out"
fi

# --- Track consecutive failures ---

if $CAPTURE_OK; then
    # Reset counter on success
    if [[ -f "$FAIL_COUNT_FILE" ]]; then
        rm -f "$FAIL_COUNT_FILE"
        log "healthy frame captured, fail counter reset"
    fi
    exit 0
fi

# Increment failure count
CURRENT_FAILS=0
if [[ -f "$FAIL_COUNT_FILE" ]]; then
    CURRENT_FAILS=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fi
CURRENT_FAILS=$(( CURRENT_FAILS + 1 ))
echo "$CURRENT_FAILS" > "$FAIL_COUNT_FILE"

log "blank frame detected (failure $CURRENT_FAILS/$MAX_FAILURES)"

# Log CSI errors for context (not a trigger — they also occur during normal operation)
CSI_ERRORS=$(dmesg --time-format iso 2>/dev/null | grep -c "Frame sync error" || echo "?")
log "CSI-2 frame sync errors in dmesg: $CSI_ERRORS"

if (( CURRENT_FAILS < MAX_FAILURES )); then
    exit 0
fi

# --- Recovery ---

log "=== Starting recovery (${MAX_FAILURES} consecutive failures) ==="

# Reset counter before recovery attempt
echo "0" > "$FAIL_COUNT_FILE"

# 1. Stop relay
log "stopping v4l2-relayd..."
systemctl stop v4l2-relayd@default 2>/dev/null || true
sleep 1

# 2. Clean stale SysV shared memory from icamerasrc
if ipcs -m 2>/dev/null | grep -q "$SHM_KEY"; then
    log "cleaning stale SHM segment ($SHM_KEY)"
    ipcrm -M "$SHM_KEY" 2>/dev/null || true
fi

# 3. Unbind IPU6 ISYS to reset the CSI-2 link
#    NOTE: Do NOT unload/reload ov02c10 — modprobe -r with IVSC loaded causes
#    a kernel oops (page fault in v4l2_fwnode_endpoint_alloc_parse due to stale
#    firmware node references). ISYS unbind/rebind alone resets the CSI link.
if [[ -e "$ISYS_DRIVER_PATH/$ISYS_DEVICE" ]]; then
    log "unbinding IPU6 ISYS..."
    echo "$ISYS_DEVICE" > "$ISYS_DRIVER_PATH/unbind" 2>/dev/null || true
    sleep 2
fi

# 4. Rebind IPU6 ISYS
if [[ ! -e "$ISYS_DRIVER_PATH/$ISYS_DEVICE" ]]; then
    log "rebinding IPU6 ISYS..."
    echo "$ISYS_DEVICE" > "$ISYS_DRIVER_PATH/bind" 2>/dev/null || true
    sleep 3
fi

# 6. Start relay (ExecStartPost handles udev trigger + WirePlumber restart)
log "starting v4l2-relayd..."
systemctl start v4l2-relayd@default

log "=== Recovery complete ==="
