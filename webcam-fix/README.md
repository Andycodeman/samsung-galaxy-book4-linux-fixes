# Fix: Samsung Galaxy Book4 Ultra Webcam on Ubuntu 24.04 (Intel IPU6 / OV02C10 / Meteor Lake)

**Tested on:** Samsung Galaxy Book4 Ultra, Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic (HWE)
**Date:** February 2026
**Hardware:** Intel IPU6 (Meteor Lake, PCI ID `8086:7d19`), OV02C10 sensor (`OVTI02C1:00`), Intel Visual Sensing Controller (IVSC)

---

## The Problem

The Samsung Galaxy Book4 Ultra's built-in webcam does not work out of the box on Ubuntu 24.04. The webcam uses Intel's IPU6 (Image Processing Unit 6) on Meteor Lake, with an OmniVision OV02C10 sensor connected through Intel's Visual Sensing Controller (IVSC). While the kernel has all the required drivers, **four separate issues** prevent the camera from working:

1. **IVSC kernel modules don't auto-load** — The MEI VSC (Management Engine Interface - Visual Sensing Controller) modules are present in the kernel but never get loaded at boot, breaking the entire camera initialization chain
2. **Missing userspace camera HAL** — IPU6 outputs raw Bayer sensor data that requires Intel's proprietary camera HAL library to convert into usable video formats (NV12/YUY2)
3. **v4l2loopback device name mismatch** — The v4l2-relayd relay service can't find the loopback device because the module loads before its configuration is applied
4. **PipeWire misclassifies the device** — PipeWire's V4L2 SPA plugin classifies v4l2loopback as a video *output* instead of *capture*, preventing portal-based apps (Cheese, GNOME Camera, browser WebRTC) from seeing the webcam

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

### Step 3: Re-probe the Camera Sensor

```bash
sudo modprobe -r ov02c10 && sudo modprobe ov02c10
```

Verify the sensor probed successfully:

```bash
journalctl -b -k --since "1 minute ago" | grep ov02c10
```

You should see the sensor register as a media entity (e.g., `entity 367`) with output format `SGRBG10` through a CSI2 port, instead of the `-517` errors.

### Step 4: Install the Camera HAL and Relay Service

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

### Step 5: Fix the v4l2loopback Device Name

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

### Step 6: Configure and Start v4l2-relayd

The v4l2-relayd package creates a default config at `/etc/default/v4l2-relayd` with a test source. The IPU6-specific config needs to override it:

```bash
# Create/verify the IPU6 override config
cat /etc/v4l2-relayd
```

It should contain:

```
VIDEOSRC=icamerasrc buffer-count=7
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
```

If this file doesn't exist or has different content, create it:

```bash
sudo tee /etc/v4l2-relayd << 'EOF'
VIDEOSRC=icamerasrc buffer-count=7
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
EOF
```

Now start the relay service:

```bash
sudo systemctl reset-failed v4l2-relayd
sudo systemctl restart v4l2-relayd
systemctl status v4l2-relayd
```

The service should show `active (running)` and stay running. You should see the webcam's blue LED turn on.

### Step 7: Fix PipeWire Device Classification

PipeWire's V4L2 SPA plugin incorrectly classifies v4l2loopback devices as video *output* rather than *capture*, even when `exclusive_caps=1` is set. This prevents camera apps that use PipeWire/portals (GNOME Camera, Cheese, etc.) from seeing the webcam. Without this fix, `wpctl status` will show the camera under Video > Devices but **not** under Video > Sources, meaning no app can access it through the camera portal.

A WirePlumber rule overrides this:

```bash
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d

sudo tee /etc/wireplumber/wireplumber.conf.d/50-v4l2-ipu6-camera.conf << 'EOF'
monitor.v4l2.rules = [
  {
    matches = [
      {
        api.v4l2.cap.card = "Intel MIPI Camera"
      }
    ]
    actions = {
      update-props = {
        device.capabilities = ":video_capture:"
      }
    }
  }
]
EOF

# Restart WirePlumber to apply
systemctl --user restart wireplumber
```

Verify a Source node appeared:

```bash
wpctl status | grep -A5 "^Video"
```

You should see the camera listed under **Sources**:
```
 ├─ Sources:
 │  *   47. Intel MIPI Camera (V4L2)
```

Without this step, only apps that directly open `/dev/video0` via V4L2 (mpv, ffmpeg, OBS) will work. Portal-based apps (Cheese, GNOME Camera, browser WebRTC) will not see any camera.

### Step 8: Verify

```bash
# Capture a test frame
ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -update 1 -y /tmp/webcam_test.jpg

# Verify
file /tmp/webcam_test.jpg
# Should output: JPEG image data, baseline, precision 8, 1280x720, components 3

# Live preview
mpv av://v4l2:/dev/video0 --profile=low-latency
```

The webcam should now appear as **"Intel MIPI Camera"** in any V4L2-compatible application: Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC, etc.

> **Note:** The GNOME Snapshot app (`snapshot`) may segfault on KDE Plasma — this is a Snapshot/GTK4 bug, not a camera issue. Use Cheese, Firefox, Chromium, or other apps instead.

---

## Quick Setup Script

A complete automated script (`install.sh`) is provided alongside this guide. It performs all 8 steps with hardware verification, error handling, and validation.

```bash
./install.sh
```

The script creates these persistent configuration files:
- `/etc/modules-load.d/ivsc.conf` — IVSC module auto-loading
- `/etc/v4l2-relayd` — Camera HAL relay configuration
- `/etc/wireplumber/wireplumber.conf.d/50-v4l2-ipu6-camera.conf` — PipeWire device classification fix

### Uninstall

To reverse everything the fix script did:

```bash
./uninstall.sh
sudo reboot
```

This removes the config files, the camera HAL and relay packages, and the Intel IPU6 PPA.

---

## Troubleshooting

### Sensor still fails after loading IVSC modules

If `journalctl -b -k | grep ov02c10` still shows `-517` errors, try a full reboot. The module load order matters and some dependencies resolve better during a clean boot.

### v4l2-relayd crashes immediately

Check the logs:

```bash
journalctl -u v4l2-relayd --no-pager | tail -20
```

Common causes:
- **`device=/dev/""`** — v4l2loopback name mismatch. Reload with `sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"`
- **`gst_element_set_state: assertion 'GST_IS_ELEMENT' failed`** — icamerasrc can't connect to the camera. Verify IVSC modules are loaded: `lsmod | grep ivsc`
- **`failed to config stream for format NV12 1920x1080`** — Wrong resolution. Ensure `/etc/v4l2-relayd` specifies 1280x720, not 1920x1080

### No `/dev/video0` device

```bash
lsmod | grep v4l2loopback  # Module loaded?
ls /sys/devices/virtual/video4linux/  # Any devices?
```

If v4l2loopback isn't loaded: `sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"`

### Permission denied on `/dev/video33` (or similar)

The IPU6 device nodes have restricted permissions. The v4l2-relayd service runs as root and handles this. If you're trying to run icamerasrc directly as your user, you'll hit permission errors on the raw IPU6 devices — this is expected. Use `/dev/video0` (the v4l2loopback device) which has proper permissions.

---

## What This Applies To

This fix should work for any laptop with:
- Intel IPU6 on **Meteor Lake** (PCI ID `8086:7d19`)
- **OV02C10** camera sensor
- Ubuntu 24.04 with HWE kernel 6.17+

This likely includes other Samsung Galaxy Book4 models and possibly other Meteor Lake laptops (Dell, Lenovo, etc.) with the same sensor. The core issue — IVSC modules not auto-loading — is not Samsung-specific.

Laptops with different sensors (OV01A1S, OV13B10, HM2172, etc.) may have similar issues. The IVSC module fix (Steps 1-2) is likely universal for Meteor Lake cameras, but the camera HAL package and sensor driver compatibility may vary.

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
