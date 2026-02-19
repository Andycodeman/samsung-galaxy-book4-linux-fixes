#!/bin/bash
# v4l2-relayd-detect-resolution.sh — Auto-detect icamerasrc native resolution
#
# Called by v4l2-relayd@default.service ExecStartPre to set WIDTH/HEIGHT
# dynamically instead of hardcoding them in the config.
#
# The camera HAL (libcamhal-ipu6epmtl) may change its default output
# resolution across package updates. Previously it defaulted to 1280x720,
# but newer versions default to 1920x1080. Hardcoding causes a silent
# resolution mismatch where videoconvert can't scale, resulting in blank
# frames through the v4l2loopback device.
#
# Installed to /usr/local/sbin/v4l2-relayd-detect-resolution.sh

set -euo pipefail

ENV_FILE="/run/v4l2-relayd-resolution.env"
SHM_KEY="0x0043414d"
DEFAULT_WIDTH=1920
DEFAULT_HEIGHT=1080

# Clean any stale SHM from previous runs
ipcrm -M "$SHM_KEY" 2>/dev/null || true

WIDTH=""
HEIGHT=""

# Probe icamerasrc for its negotiated caps
CAPS=$(GST_DEBUG=3 timeout 8 gst-launch-1.0 icamerasrc buffer-count=7 num-buffers=1 ! fakesink -v 2>&1 \
    | grep -m1 "camerasrc.*caps = " || true)

# Clean SHM from probe
ipcrm -M "$SHM_KEY" 2>/dev/null || true

if [[ -n "$CAPS" ]]; then
    WIDTH=$(echo "$CAPS" | grep -oP 'width=\(int\)\K[0-9]+' || true)
    HEIGHT=$(echo "$CAPS" | grep -oP 'height=\(int\)\K[0-9]+' || true)
fi

WIDTH=${WIDTH:-$DEFAULT_WIDTH}
HEIGHT=${HEIGHT:-$DEFAULT_HEIGHT}

echo "WIDTH=$WIDTH" > "$ENV_FILE"
echo "HEIGHT=$HEIGHT" >> "$ENV_FILE"
echo "Detected resolution: ${WIDTH}x${HEIGHT}" >&2
