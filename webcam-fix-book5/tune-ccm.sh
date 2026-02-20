#!/bin/bash
# tune-ccm.sh — Interactive CCM tuning tool for IPU7 cameras
# Cycles through color correction presets with live qcam preview.
#
# Usage: ./tune-ccm.sh [sensor]
#   sensor: ov02e10 (default) or ov02c10
#
# Requires: qcam (libcamera-tools), sudo access to write tuning files

set -e

SENSOR="${1:-ov02e10}"

# Find the tuning file location
TUNING_FILE=""
for dir in /usr/local/share/libcamera/ipa/simple \
           /usr/share/libcamera/ipa/simple; do
    if [[ -d "$dir" ]]; then
        TUNING_FILE="$dir/${SENSOR}.yaml"
        break
    fi
done

if [[ -z "$TUNING_FILE" ]]; then
    echo "ERROR: Could not find libcamera IPA data directory."
    echo "Make sure libcamera is installed."
    exit 1
fi

if ! command -v qcam >/dev/null 2>&1; then
    echo "ERROR: qcam not found. Install libcamera-tools first."
    echo "  Arch:   sudo pacman -S libcamera-tools"
    echo "  Fedora: sudo dnf install libcamera-tools"
    exit 1
fi

# Export IPA path in case it's a source build
for dir in /usr/local/lib/*/libcamera/ipa /usr/local/lib/libcamera/ipa \
           /usr/lib/*/libcamera/ipa /usr/lib/libcamera/ipa; do
    if [[ -d "$dir" ]]; then
        export LIBCAMERA_IPA_MODULE_PATH="$dir"
        break
    fi
done

# Back up the current tuning file
BACKUP=""
if [[ -f "$TUNING_FILE" ]]; then
    BACKUP="${TUNING_FILE}.bak.$$"
    sudo cp "$TUNING_FILE" "$BACKUP"
fi

cleanup() {
    # Kill qcam if we started it
    if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
        kill "$QCAM_PID" 2>/dev/null
        wait "$QCAM_PID" 2>/dev/null || true
    fi
    # Restore backup if user didn't explicitly save (Ctrl+C, error, etc.)
    if [[ $SELECTED -lt 0 && -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo cp "$BACKUP" "$TUNING_FILE"
        sudo rm -f "$BACKUP"
        echo ""
        echo "  Interrupted — restored original tuning file."
    fi
}
trap cleanup EXIT INT TERM

# ─── CCM Presets ───────────────────────────────────────────────
# Each preset: NAME|DESCRIPTION|YAML_CONTENT
# Rows must sum to 1.0 to preserve neutral greys.
PRESETS=(
"No CCM (baseline)|No color correction — raw debayer + AWB only. Image will be desaturated/grayscale.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Adjust:
  - Agc:
..."

"Identity CCM|Identity matrix — CCM enabled but no color change. Tests CCM pipeline overhead.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.0, 0.0, 0.0,
                 0.0, 1.0, 0.0,
                 0.0, 0.0, 1.0 ]
  - Adjust:
  - Agc:
..."

"Symmetric light boost|Equal 10% saturation boost on all channels. Mild color enhancement.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.1, -0.05, -0.05,
                -0.05,  1.1, -0.05,
                -0.05, -0.05,  1.1 ]
  - Adjust:
  - Agc:
..."

"Symmetric medium boost|Equal 20% saturation boost. Stronger color.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.2, -0.1, -0.1,
                -0.1,  1.2, -0.1,
                -0.1, -0.1,  1.2 ]
  - Adjust:
  - Agc:
..."

"Symmetric strong boost|Equal 40% saturation boost. Very vivid colors.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.4, -0.2, -0.2,
                -0.2,  1.4, -0.2,
                -0.2, -0.2,  1.4 ]
  - Adjust:
  - Agc:
..."

"Green boost (anti-purple) light|Boosts green 20% more than R/B. Counters purple/magenta cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.05, -0.025, -0.025,
                -0.1,   1.3,   -0.2,
                -0.025, -0.025,  1.05 ]
  - Adjust:
  - Agc:
..."

"Green boost (anti-purple) medium|Boosts green 40% more than R/B. Stronger purple correction.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.0,  0.0,  0.0,
                -0.2,  1.4, -0.2,
                 0.0,  0.0,  1.0 ]
  - Adjust:
  - Agc:
..."

"Green boost (anti-purple) strong|Boosts green significantly. For strong purple bias.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 0.95,  0.025, 0.025,
                -0.25,  1.5,  -0.25,
                 0.025, 0.025, 0.95 ]
  - Adjust:
  - Agc:
..."

"Red reduce + green boost|Reduces red, boosts green. For warm/magenta cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 0.9,  0.05, 0.05,
                -0.15, 1.35,-0.2,
                 0.0, -0.05, 1.05 ]
  - Adjust:
  - Agc:
..."

"Arch Wiki (OV02C10 reference)|Original matrix from Arch Wiki. Tuned for OV02C10, may cause purple on OV02E10.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 1.05, -0.02, -0.01,
                -0.03,  0.92, -0.03,
                -0.01, -0.02,  1.05 ]
  - Adjust:
  - Agc:
..."
)

# ─── Main loop ─────────────────────────────────────────────────
TOTAL=${#PRESETS[@]}
CURRENT=0
SELECTED=-1
QCAM_PID=""

echo "=============================================="
echo "  IPU7 Camera CCM Tuning Tool"
echo "=============================================="
echo ""
echo "  Sensor:  $SENSOR"
echo "  File:    $TUNING_FILE"
echo "  Presets: $TOTAL"
echo ""
echo "  Controls:"
echo "    Enter / n  →  Next preset"
echo "    p          →  Previous preset"
echo "    s          →  Save current preset and exit"
echo "    q          →  Quit without saving (restores backup)"
echo "    number     →  Jump to preset (1-${TOTAL})"
echo ""
echo "  qcam will restart for each preset (takes ~1 second)."
echo "  Position the qcam window where you can see it."
echo ""
read -r -p "Press Enter to start..." _

apply_preset() {
    local idx=$1
    local entry="${PRESETS[$idx]}"
    # Extract fields using parameter expansion (read only handles one line)
    local name="${entry%%|*}"
    local rest="${entry#*|}"
    local desc="${rest%%|*}"
    local yaml="${rest#*|}"

    echo ""
    echo "──────────────────────────────────────────────"
    echo "  [$((idx+1))/$TOTAL] $name"
    echo "  $desc"
    echo "──────────────────────────────────────────────"

    # Kill existing qcam first (must release camera before restarting)
    if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
        kill "$QCAM_PID" 2>/dev/null
        wait "$QCAM_PID" 2>/dev/null || true
        sleep 0.5  # let camera device settle after close
    fi

    # Write tuning file
    echo "$yaml" | sudo tee "$TUNING_FILE" > /dev/null
    sync  # ensure file is flushed to disk before qcam reads it

    # Launch qcam in background (stderr visible for debugging)
    qcam &
    QCAM_PID=$!

    # Give qcam time to open window and start streaming
    sleep 3
}

apply_preset $CURRENT

while true; do
    echo ""
    read -r -p "  [$((CURRENT+1))/${TOTAL}] Next(Enter/n) Prev(p) Save(s) Quit(q) Jump(1-${TOTAL}): " choice

    case "$choice" in
        ""| n | N)
            CURRENT=$(( (CURRENT + 1) % TOTAL ))
            apply_preset $CURRENT
            ;;
        p | P)
            CURRENT=$(( (CURRENT - 1 + TOTAL) % TOTAL ))
            apply_preset $CURRENT
            ;;
        s | S)
            SELECTED=$CURRENT
            break
            ;;
        q | Q)
            break
            ;;
        [0-9]*)
            if [[ "$choice" -ge 1 && "$choice" -le $TOTAL ]] 2>/dev/null; then
                CURRENT=$((choice - 1))
                apply_preset $CURRENT
            else
                echo "  Invalid number. Enter 1-${TOTAL}."
            fi
            ;;
        *)
            echo "  Unknown command: $choice"
            ;;
    esac
done

# Kill qcam
if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
    kill "$QCAM_PID" 2>/dev/null
    wait "$QCAM_PID" 2>/dev/null || true
fi

echo ""
if [[ $SELECTED -ge 0 ]]; then
    name="${PRESETS[$SELECTED]%%|*}"
    echo "=============================================="
    echo "  Saved: $name"
    echo "  File:  $TUNING_FILE"
    echo "=============================================="
    echo ""
    echo "  Restart PipeWire to apply for all apps:"
    echo "    systemctl --user restart pipewire wireplumber"
    # Remove backup
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo rm -f "$BACKUP"
    fi
else
    # Restore backup
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo cp "$BACKUP" "$TUNING_FILE"
        sudo rm -f "$BACKUP"
        echo "  Restored original tuning file."
    fi
    echo "  Exited without saving."
fi
