# Fix: Samsung Galaxy Book4 Webcam on Ubuntu (Intel IPU6 / OV02C10 / Meteor Lake)

> **Meteor Lake (Galaxy Book4) + Ubuntu only.** This fix does **not** support Lunar Lake (Galaxy Book5) — those models use Intel IPU7, which has a completely different camera driver stack. It also requires **Ubuntu or Ubuntu-based distros** (apt, PPA packages, initramfs-tools) — Fedora and Arch are not yet supported. The install script will detect unsupported hardware and show a helpful message. See [Compatibility](#compatibility) below.

**Tested on:** Samsung Galaxy Book4 Ultra, Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic (HWE)
**Date:** February 2026
**Hardware:** Intel IPU6 (Meteor Lake, PCI ID `8086:7d19`), OV02C10 sensor (`OVTI02C1:00`), Intel Visual Sensing Controller (IVSC)

---

## Quick Install

**No git?** Download, install, and reboot in one step:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/webcam-fix && ./install.sh && sudo reboot
```

**Already cloned?**

```bash
./install.sh
sudo reboot
```

To uninstall:

```bash
./uninstall.sh
sudo reboot
```

The webcam works with **Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC**, and most other apps. See [Known App Issues](#known-app-issues) below for Cheese and GNOME Camera.

---

## Known App Issues

### Cheese — Crashes (broken, do not use)

GNOME Cheese crashes with a segfault (`SIGSEGV` in `libgstvideoconvertscale.so`) when receiving frames from the v4l2loopback device. This happens regardless of pixel format (YUY2, I420, NV12, BGRx). It is a bug in Cheese's GStreamer/Clutter rendering pipeline, not a camera driver issue. There is no workaround — Cheese is broken with this camera setup.

### GNOME Camera (snapshot) — May crash on some systems

GNOME Camera may crash on launch (`SIGSEGV` in `gst_video_frame_copy_plane` within `libgstvideofilter.so`). This is caused by a buffer mismatch in snapshot's internal `GstCameraBin` GL video rendering pipeline when it receives frames from the PipeWire V4L2 source node. This crash does **not** affect other apps — they use different video pipelines.

**Workaround** — launch with software GL rendering:

```bash
LIBGL_ALWAYS_SOFTWARE=1 snapshot
```

The performance impact is negligible for a camera preview window. The exact root cause is unconfirmed but may be related to Mesa graphics driver version changes.

### What works

The webcam works correctly with: **Firefox**, **Chromium**, **Zoom**, **Microsoft Teams**, **OBS Studio**, **mpv**, **VLC**, and any other app that accesses the camera through V4L2 or PipeWire without using GStreamer's `GstCameraBin` internally.

Quick test:

```bash
mpv av://v4l2:/dev/video0 --profile=low-latency
```

---

## The Problem

The Samsung Galaxy Book4 Ultra's built-in webcam does not work out of the box on Ubuntu 24.04. The webcam uses Intel's IPU6 (Image Processing Unit 6) on Meteor Lake, with an OmniVision OV02C10 sensor connected through Intel's Visual Sensing Controller (IVSC). While the kernel has all the required drivers, **four separate issues** prevent the camera from working:

1. **IVSC kernel modules don't auto-load** — The MEI VSC (Management Engine Interface - Visual Sensing Controller) modules are present in the kernel but never get loaded at boot, breaking the entire camera initialization chain
2. **IVSC/sensor boot race condition** — Even when IVSC modules are loaded via `modules-load.d`, udev probes the OV02C10 sensor via ACPI before IVSC has finished initializing, causing repeated `-EPROBE_DEFER` and leaving the CSI-2 link unstable (intermittent black frames / "Frame sync error")
3. **Missing userspace camera HAL** — IPU6 outputs raw Bayer sensor data that requires Intel's proprietary camera HAL library to convert into usable video formats
4. **v4l2loopback device name mismatch** — The v4l2-relayd relay service can't find the loopback device because the module loads before its configuration is applied
5. **PipeWire misclassifies the device** — With `exclusive_caps=1`, v4l2loopback initially advertises `VIDEO_OUTPUT` until a producer (v4l2-relayd) attaches. WirePlumber discovers the device before the relay connects and never creates a Source node, making the camera invisible to portal-based apps (GNOME Camera, browser WebRTC, Zoom)
6. **icamerasrc only outputs NV12** — The `icamerasrc` GStreamer element produces NV12 format exclusively, but v4l2-relayd's pipeline expects the input to match the configured output format. Without an explicit `videoconvert` in the input pipeline, GStreamer caps negotiation fails silently and the relay delivers zero frames (black screen)

## How It Manifests

In `dmesg`/`journalctl`, you'll see the OV02C10 sensor fail to probe repeatedly with `-517` (`EPROBE_DEFER`):

```
ov02c10 i2c-OVTI02C1:00: failed to check hwcfg: -517
ov02c10 i2c-OVTI02C1:00: failed to check hwcfg: -517
ov02c10 i2c-OVTI02C1:00: failed to check hwcfg: -517
[... repeats 8 times ...]
```

The IPU6 driver sees the sensor listed in ACPI and claims success:

```
intel-ipu6 0000:00:05.0: Found supported sensor OVTI02C1:00
intel-ipu6 0000:00:05.0: Connected 1 cameras
```

But no usable video device appears. `v4l2-ctl --list-devices` only shows a dummy loopback, and no application can find a webcam.

Even after the IVSC modules are loaded via `modules-load.d`, the camera may work intermittently — the first open shows a black frame with the LED lighting briefly, the second attempt works, and then it fails again. In `dmesg`, you'll see:

```
intel_ipu6_isys.isys intel_ipu6.isys.40: csi2-4 error: Frame sync error
```

This is caused by the sensor probing before IVSC is fully initialized, leaving the CSI-2 link in an unstable state.

---

## Root Cause Analysis

The camera pipeline on Meteor Lake requires a specific initialization sequence:

```
MEI VSC driver → IVSC firmware load → INT3472 GPIO power-on → OV02C10 sensor probe
    ↓                                                              ↓
mei-vsc.ko                                                    ov02c10.ko
mei-vsc-hw.ko                                            (raw Bayer output)
ivsc-ace.ko                                                        ↓
ivsc-csi.ko                                              libcamhal-ipu6epmtl
                                                          (debayering/ISP)
                                                                   ↓
                                                              icamerasrc
                                                          (GStreamer plugin)
                                                                   ↓
                                                            v4l2-relayd
                                                                   ↓
                                                         /dev/video0 (V4L2)
                                                          ↓              ↓
                                              Direct V4L2 apps    PipeWire/WirePlumber
                                              (mpv, ffmpeg, OBS)  (needs WirePlumber rule)
                                                                         ↓
                                                                  Camera portal apps
                                                                  (Cheese, browsers, etc.)
```

The OV02C10 sensor needs the INT3472 discrete GPIO controller to provide power, clocks, and control GPIOs. INT3472 in turn depends on the IVSC (Intel Visual Sensing Controller) firmware being loaded through the MEI bus. Without the `mei-vsc` and `ivsc-*` kernel modules loaded, this entire chain is broken — the sensor driver keeps deferring its probe waiting for resources that never become available.

The modules exist in the kernel (`/lib/modules/$(uname -r)/kernel/drivers/misc/mei/mei-vsc*.ko.zst` and `.../media/pci/intel/ivsc/ivsc-*.ko.zst`) but there is no udev rule or module alias that triggers them to auto-load on this hardware.

---

## The Fix

### Prerequisites

Verify you have the right hardware:

```bash
# Confirm IPU6 Meteor Lake
lspci -d 8086:7d19
# Should show: Intel Corporation Meteor Lake IPU

# Confirm OV02C10 sensor in ACPI
cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep OVTI02C1
# Should show: OVTI02C1

# Confirm IVSC firmware files exist
ls /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin.zst
ls /lib/firmware/intel/vsc/ivsc_skucfg_ovti02c1_0_1.bin.zst

# Confirm kernel modules exist but aren't loaded
find /lib/modules/$(uname -r) -name 'mei-vsc*' -o -name 'ivsc-*'
lsmod | grep -E 'ivsc|mei.vsc'  # Should return nothing
```

### Step 1: Load IVSC Kernel Modules

```bash
# Load the IVSC module chain
sudo modprobe mei-vsc
sudo modprobe mei-vsc-hw
sudo modprobe ivsc-ace
sudo modprobe ivsc-csi

# Verify they loaded
lsmod | grep -E 'ivsc|mei.vsc'
```

You should see `ivsc_csi`, `ivsc_ace`, `mei_vsc`, and `mei_vsc_hw` in the output.

### Step 2: Make IVSC Modules Load at Boot

```bash
echo -e "mei-vsc\nmei-vsc-hw\nivsc-ace\nivsc-csi" | sudo tee /etc/modules-load.d/ivsc.conf
```

### Step 3: Add IVSC Modules to Initramfs

Loading modules via `modules-load.d` is too late — udev starts probing ACPI devices (including the OV02C10 sensor) before `systemd-modules-load.service` runs, so the sensor hits `-EPROBE_DEFER` repeatedly. Adding the IVSC modules to the initramfs ensures they're loaded before any device probing begins.

```bash
# Add IVSC modules to initramfs
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null || \
        echo "$mod" | sudo tee -a /etc/initramfs-tools/modules
done

# Rebuild initramfs
sudo update-initramfs -u
```

After a reboot, `journalctl -b -k | grep ov02c10` should show zero `-517` errors.

### Step 4: Re-probe the Camera Sensor

```bash
sudo modprobe -r ov02c10 && sudo modprobe ov02c10
```

Verify the sensor probed successfully:

```bash
journalctl -b -k --since "1 minute ago" | grep ov02c10
```

You should see the sensor register as a media entity (e.g., `entity 367`) with output format `SGRBG10` through a CSI2 port, instead of the `-517` errors.

### Step 5: Install the Camera HAL and Relay Service

The IPU6 outputs raw Bayer data. You need Intel's camera HAL to process it into standard video formats, and v4l2-relayd to bridge it to a V4L2 device.

```bash
# Add the Ubuntu OEM PPA for Intel IPU6 camera support
sudo add-apt-repository ppa:oem-solutions-group/intel-ipu6
sudo apt update

# Install the Meteor Lake camera HAL and relay service
sudo apt install libcamhal-ipu6epmtl v4l2-relayd
```

This installs:
- `libcamhal-ipu6epmtl` — Intel camera HAL for Meteor Lake (image processing, debayering, 3A)
- `gstreamer1.0-icamera` — GStreamer plugin (`icamerasrc`) that interfaces with the HAL
- `v4l2-relayd` — Daemon that bridges icamerasrc to a v4l2loopback device
- `v4l2loopback` module configuration

### Step 6: Fix the v4l2loopback Device Name

The v4l2loopback module may have loaded before the modprobe config was installed, resulting in a "Dummy video device" name instead of "Intel MIPI Camera". The v4l2-relayd service looks up the device by name, so this mismatch causes it to fail.

```bash
# Reload v4l2loopback with the correct label
sudo modprobe -r v4l2loopback
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"

# Verify the name is correct
cat /sys/devices/virtual/video4linux/video0/name
# Should output: Intel MIPI Camera
```

The modprobe config file (installed by the v4l2-relayd package) at `/etc/modprobe.d/v4l2loopback-ipu6.conf` ensures this persists across reboots:

```
options v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"
```

### Step 7: Configure and Start v4l2-relayd

The v4l2-relayd package creates a default config at `/etc/default/v4l2-relayd` with a test source. The `v4l2-relayd@default` service also reads instance overrides from `/etc/v4l2-relayd.d/default.conf`, which takes priority:

```bash
# Create/verify the IPU6 override config
sudo mkdir -p /etc/v4l2-relayd.d
cat /etc/v4l2-relayd.d/default.conf
```

It should contain:

```
VIDEOSRC=icamerasrc buffer-count=7 ! videoconvert
FORMAT=YUY2
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
```

> **No hardcoded WIDTH/HEIGHT.** The camera HAL (`libcamhal-ipu6epmtl`) can change its default output resolution across package updates (e.g. 1280x720 → 1920x1080). If WIDTH/HEIGHT don't match icamerasrc's native resolution, `videoconvert` can't scale (it only converts pixel formats), causing the relay to silently produce blank frames. Instead, the resolution is auto-detected at service startup (see Step 7b).

> **Why `videoconvert` in VIDEOSRC?** The `icamerasrc` GStreamer element only outputs NV12 format. The v4l2-relayd service constructs its pipeline with `appsrc caps=...format=YUY2...`, which expects the input side to already be in YUY2. Without `videoconvert` in the input pipeline, GStreamer caps negotiation fails silently — the relay appears to run but delivers zero frames to the loopback device (black screen in apps). The `videoconvert` element converts NV12→YUY2 before frames reach the appsrc.

If this file doesn't exist or has different content, create it:

```bash
sudo mkdir -p /etc/v4l2-relayd.d
sudo tee /etc/v4l2-relayd.d/default.conf << 'EOF'
VIDEOSRC=icamerasrc buffer-count=7 ! videoconvert
FORMAT=YUY2
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
EOF
```

### Step 7b: Install Resolution Auto-Detection

The camera HAL may change its default output resolution across package updates. Instead of hardcoding WIDTH/HEIGHT (which causes silent blank frames on mismatch), a detection script probes icamerasrc at service startup:

```bash
sudo install -m 755 v4l2-relayd-detect-resolution.sh /usr/local/sbin/v4l2-relayd-detect-resolution.sh
```

This script runs as `ExecStartPre` in the systemd service (configured in Step 8), probes icamerasrc for its negotiated caps, and writes WIDTH/HEIGHT to `/run/v4l2-relayd-resolution.env` which the service reads as an `EnvironmentFile`.

Now start the relay service:

```bash
sudo systemctl reset-failed v4l2-relayd
sudo systemctl restart v4l2-relayd
systemctl status v4l2-relayd
```

The service should show `active (running)` and stay running. You should see the webcam's blue LED turn on.

### Step 8: Harden v4l2-relayd Service

Even with the initramfs fix, the first CSI stream after boot can occasionally fail. A systemd override auto-restarts on failure and re-triggers WirePlumber to pick up the loopback device correctly:

```bash
sudo mkdir -p /etc/systemd/system/v4l2-relayd@default.service.d
sudo tee /etc/systemd/system/v4l2-relayd@default.service.d/override.conf << 'EOF'
[Unit]
# Rate-limit restarts: max 10 attempts in 60 seconds
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
# Auto-detect camera resolution before starting the relay.
# The HAL may change its default resolution across updates (e.g. 720p → 1080p),
# so we probe icamerasrc at startup instead of hardcoding WIDTH/HEIGHT.
ExecStartPre=/usr/local/sbin/v4l2-relayd-detect-resolution.sh
EnvironmentFile=-/run/v4l2-relayd-resolution.env

# After the relay connects, re-trigger udev on the loopback device and
# restart the user's WirePlumber so it re-discovers the device as
# VIDEO_CAPTURE (v4l2loopback with exclusive_caps=1 only advertises
# capture once a producer is attached).
ExecStartPost=/bin/sh -c 'sleep 2; udevadm trigger --action=change /dev/video0 2>/dev/null; sleep 1; for uid in $(loginctl list-users --no-legend 2>/dev/null | awk "{print \\$1}"); do su - "#$uid" -c "systemctl --user restart wireplumber" 2>/dev/null || true; done'

# Fast auto-restart on failure (covers transient CSI frame sync errors).
Restart=always
RestartSec=2
EOF
sudo systemctl daemon-reload
```

> **Important:** `StartLimitIntervalSec` and `StartLimitBurst` must be in the `[Unit]` section, not `[Service]`. systemd silently ignores them if placed in `[Service]`.

This ensures the relay auto-recovers from transient CSI errors, and the ExecStartPost udev trigger + WirePlumber restart handles the device classification timing issue (see Step 9).

### Step 9: Fix PipeWire Device Classification

With `exclusive_caps=1`, v4l2loopback only advertises `VIDEO_CAPTURE` capability **after** a producer (v4l2-relayd) attaches. Before that, it shows `VIDEO_OUTPUT`. WirePlumber discovers the device at boot before the relay connects, sees it as an output device, and never creates a Source node — making the camera invisible to portal-based apps (GNOME Camera, browsers, Zoom, etc.).

> **Note:** `device.capabilities` is **read-only** in PipeWire — it's set by the kernel V4L2 ioctl. WirePlumber rules cannot override it. The only fix is to make WirePlumber re-discover the device after the relay attaches.

This is handled automatically by the `ExecStartPost` in Step 8, which:
1. Waits 2 seconds for the relay to attach to the loopback device
2. Triggers a udev `change` event on `/dev/video0` (makes the kernel re-report capabilities)
3. Restarts WirePlumber so it re-queries the device and sees `VIDEO_CAPTURE`

Verify a Source node appeared:

```bash
wpctl status | grep -A5 "^Video"
```

You should see the camera listed under **Sources**:
```
 ├─ Sources:
 │  *   47. Intel MIPI Camera (V4L2)
```

Without the ExecStartPost fix, only apps that directly open `/dev/video0` via V4L2 (mpv, ffmpeg, OBS) will work. Portal-based apps (GNOME Camera, browser WebRTC) will not see any camera.

### Step 10: Blank Frame Watchdog

Over time (days of uptime, or after suspend/resume), CSI-2 frame sync errors can accumulate and the relay starts producing white/blank frames — but the process stays running, so systemd's `Restart=always` never triggers. A lightweight watchdog timer detects this and auto-recovers:

- Runs every 3 minutes via systemd timer
- Captures a test frame from `/dev/video0` and checks JPEG file size (real frames are 15-200KB; blank frames compress to <8KB)
- Skips checks when the relay is initializing (30s grace period), the lid is closed, or the relay isn't running
- After 3 consecutive blank-frame detections, performs recovery: stops the relay, cleans stale shared memory, unbinds/rebinds IPU6 ISYS, re-probes the sensor, and restarts the relay

State is tracked in `/run/v4l2-relayd-watchdog/` (tmpfs — cleared on reboot). Manual trigger: `sudo systemctl start v4l2-relayd-watchdog.service`. Check timer: `systemctl list-timers | grep watchdog`.

### Step 11: Upstream Detection

A boot-time service checks whether native IPU6 webcam support has landed in the running kernel. When all three conditions are met, it auto-removes the entire v4l2-relayd workaround:

1. **IVSC modules have ACPI aliases** — `mei-vsc` auto-loads without `/etc/modules-load.d/` hacks
2. **libcamera IPU6 pipeline handler exists** — the open-source pipeline replaces the proprietary HAL
3. **libcamera can enumerate the camera** — the pipeline handler actually works with this kernel

When native support is detected, the service removes all configuration files, systemd services, watchdog, and itself. The camera continues working that session (relay is already loaded), and the next reboot uses the native libcamera pipeline via PipeWire. No manual intervention needed.

The service only runs if the workaround is still installed (`ConditionPathExists=/etc/v4l2-relayd.d/default.conf`).

### Step 12: Verify

```bash
# Capture a test frame
ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -update 1 -y /tmp/webcam_test.jpg

# Verify
file /tmp/webcam_test.jpg
# Should output: JPEG image data, baseline, precision 8, 1920x1080 (or similar), components 3

# Live preview
mpv av://v4l2:/dev/video0 --profile=low-latency
```

The webcam should now appear as **"Intel MIPI Camera"** in any V4L2-compatible application: Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC, etc. See [Known App Issues](#known-app-issues) at the top of this document for Cheese and GNOME Camera compatibility.

---

## Configuration Files

The install script creates these persistent configuration files:
- `/etc/modules-load.d/ivsc.conf` — IVSC module auto-loading
- `/etc/modprobe.d/ivsc-camera.conf` — Module soft-dependency (IVSC loads before sensor)
- `/etc/modprobe.d/v4l2loopback.conf` — v4l2loopback device configuration
- `/etc/v4l2-relayd.d/default.conf` — Camera HAL relay configuration
- `/etc/udev/rules.d/90-hide-ipu6-v4l2.rules` — Hides raw IPU6 nodes from applications
- `/etc/initramfs-tools/modules` — IVSC module entries (loads before udev sensor probe)
- `/etc/systemd/system/v4l2-relayd@default.service.d/override.conf` — Auto-restart, resolution detection, and WirePlumber re-trigger
- `/usr/local/sbin/v4l2-relayd-detect-resolution.sh` — Probes icamerasrc at startup to auto-detect WIDTH/HEIGHT
- `/usr/local/sbin/v4l2-relayd-watchdog.sh` — Blank frame detection and recovery script
- `/etc/systemd/system/v4l2-relayd-watchdog.service` — Watchdog oneshot service
- `/etc/systemd/system/v4l2-relayd-watchdog.timer` — Watchdog timer (every 3 minutes)
- `/usr/local/sbin/v4l2-relayd-check-upstream.sh` — Detects native kernel support and auto-removes workaround
- `/etc/systemd/system/v4l2-relayd-check-upstream.service` — Upstream detection (runs at boot)

---

## Troubleshooting

### Sensor still fails after loading IVSC modules

If `journalctl -b -k | grep ov02c10` still shows `-517` errors after reboot, verify the IVSC modules are in the initramfs:

```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E "ivsc|mei.vsc"
```

If they're missing, add them and rebuild:

```bash
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    echo "$mod" | sudo tee -a /etc/initramfs-tools/modules
done
sudo update-initramfs -u
sudo reboot
```

### Intermittent black frames / "Frame sync error"

If `dmesg` shows `csi2-4 error: Frame sync error`, the CSI-2 link between the sensor and IPU6 is unstable. This is usually caused by the sensor probing before IVSC is ready (the initramfs fix above resolves this). As a workaround, restarting the relay service re-probes the sensor:

```bash
sudo systemctl restart v4l2-relayd@default
```

The install script configures `Restart=always` on the service so it auto-recovers from transient CSI errors.

### v4l2-relayd crashes immediately

Check the logs:

```bash
journalctl -u v4l2-relayd --no-pager | tail -20
```

Common causes:
- **`device=/dev/""`** — v4l2loopback name mismatch. Reload with `sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"`
- **`gst_element_set_state: assertion 'GST_IS_ELEMENT' failed`** — icamerasrc can't connect to the camera. Verify IVSC modules are loaded: `lsmod | grep ivsc`
- **Blank frames (relay running, small JPEG ~7KB)** — Resolution mismatch. If WIDTH/HEIGHT in the config don't match icamerasrc's native output, `videoconvert` can't scale and produces blank frames. Remove hardcoded WIDTH/HEIGHT from `/etc/v4l2-relayd.d/default.conf` and ensure the `ExecStartPre` auto-detection script is installed (see Step 7b). Check detected resolution: `cat /run/v4l2-relayd-resolution.env`
- **Black screen (relay running, zero frames)** — Missing `videoconvert` in VIDEOSRC. Ensure the config has `VIDEOSRC=icamerasrc buffer-count=7 ! videoconvert`. The `icamerasrc` element only produces NV12; without `videoconvert`, the caps negotiation to YUY2 fails silently.

### No `/dev/video0` device

```bash
lsmod | grep v4l2loopback  # Module loaded?
ls /sys/devices/virtual/video4linux/  # Any devices?
```

If v4l2loopback isn't loaded: `sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"`

### Permission denied on `/dev/video33` (or similar)

The IPU6 device nodes have restricted permissions. The v4l2-relayd service runs as root and handles this. If you're trying to run icamerasrc directly as your user, you'll hit permission errors on the raw IPU6 devices — this is expected. Use `/dev/video0` (the v4l2loopback device) which has proper permissions.

---

## Compatibility

### Supported — Meteor Lake (IPU6)

This fix works for any laptop with:
- Intel IPU6 on **Meteor Lake** (PCI ID `8086:7d19`)
- **OV02C10** camera sensor
- **Ubuntu or Ubuntu-based distro** (apt, initramfs-tools) with kernel 6.17+

This includes Samsung Galaxy Book4 Ultra, Pro, Pro 360, and possibly other Meteor Lake laptops (Dell, Lenovo, etc.) with the same sensor. The core issue — IVSC modules not auto-loading — is not Samsung-specific.

Laptops with different sensors (OV01A1S, OV13B10, HM2172, etc.) may have similar issues. The IVSC module fix (Steps 1-2) is likely universal for Meteor Lake cameras, but the camera HAL package and sensor driver compatibility may vary.

### Not Supported — Lunar Lake (IPU7)

**Galaxy Book5 models (Book5 Pro, Book5 Pro 360) are NOT supported.** These use Intel **Lunar Lake** processors with **IPU7**, which is a completely different camera ISP with its own driver stack. The install script detects Lunar Lake hardware and exits with a helpful message.

IPU7 requires different kernel drivers and a different camera HAL than IPU6. As of February 2026, Lunar Lake webcam support on Linux is still being developed upstream. Track progress at [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers).

> **Note:** The [speaker fix](../speaker-fix/) in this repo **does** work on Galaxy Book5 models — only the webcam fix is Meteor Lake-specific.

---

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** — Root cause analysis, fix script, PipeWire/WirePlumber workaround, and documentation

---

## Related Resources

- [Ubuntu Intel MIPI Camera Wiki](https://wiki.ubuntu.com/IntelMIPICamera)
- [Intel IPU6 Drivers (kernel)](https://github.com/intel/ipu6-drivers)
- [Intel IPU6 Camera HAL](https://github.com/intel/ipu6-camera-hal)
- [Intel icamerasrc GStreamer plugin](https://github.com/intel/icamerasrc)
- [Samsung Galaxy Book Extras (platform driver)](https://github.com/joshuagrisham/samsung-galaxybook-extras)

### Speaker Fix (Galaxy Book4)

The internal speakers on Galaxy Book4 models use MAX98390 amplifiers which also don't work out of the box on Linux. See the **[speaker fix](../speaker-fix/)** in this repo for a DKMS driver package that enables them. Based on [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616).
