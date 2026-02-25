# Fix: Samsung Galaxy Book3/Book4 Webcam (Intel IPU6 / OV02C10 / libcamera)

> **Recommended webcam fix for Galaxy Book3 and Book4.** Uses the open-source libcamera stack with PipeWire. Supports **Ubuntu, Fedora, and Arch-based distros**. Includes an on-demand camera relay for apps that don't support PipeWire (Zoom, OBS, VLC) with near-zero idle CPU usage, and auto-enables PipeWire camera flags in Chromium browsers. The installer auto-detects your distro.

> **Galaxy Book5 (Lunar Lake / IPU7):** Use [webcam-fix-book5](../webcam-fix-book5/) instead — the installer will detect Lunar Lake and direct you there.

**Tested on:** Samsung Galaxy Book4 Ultra, Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic (HWE)
**Date:** February 2026
**Hardware:** Intel IPU6 (Meteor Lake `8086:7d19` or Raptor Lake `8086:a75d`), OV02C10 sensor (`OVTI02C1`), Intel Visual Sensing Controller (IVSC)

---

## Quick Install

**No git?** Download, install, and reboot in one step:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/webcam-fix-libcamera && ./install.sh && sudo reboot
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

The on-demand camera relay for non-PipeWire apps (Zoom, OBS, VLC) is automatically enabled during install and starts on login with near-zero idle CPU usage.

---

## How It Works

The fix uses the open-source libcamera Simple pipeline handler with Software ISP, accessed through PipeWire. An on-demand camera relay provides a standard V4L2 device for apps that don't support PipeWire:

```
IVSC firmware  →  OV02C10 sensor  →  IPU6 ISYS  →  libcamera  →  PipeWire  →  Apps
(mei-vsc, ivsc-*)   (kernel driver)    (kernel)      (Simple ISP)   (pipewire-    (Firefox,
                                                                      libcamera)    Chromium, etc.)
                                                                         ↓
                                                                 camera-relay (on-demand)
                                                                 libcamerasrc → v4l2loopback
                                                                         ↓
                                                                 /dev/videoX (V4L2)  →  Zoom, OBS, VLC
```

**PipeWire-native apps** (Firefox, Chromium, GNOME Camera) access the camera directly through PipeWire's libcamera SPA plugin — no relay needed.

**Non-PipeWire apps** (Zoom, OBS, VLC) access the camera through the on-demand V4L2 relay. The relay uses **near-zero CPU when idle** — it monitors the v4l2loopback device for client connections using kernel V4L2 events, and only starts the GStreamer pipeline when an app opens the device. When the app closes, the pipeline stops automatically.

### On-Demand Camera Relay

The camera relay is an event-driven bridge between libcamera and V4L2:

- **Idle state:** A lightweight C monitor (`camera-relay-monitor`) holds the v4l2loopback device open and writes black frames to keep it in a ready state. Uses ~0 CPU.
- **App opens device:** The monitor detects the V4L2 client event and signals the relay to start a GStreamer pipeline: `libcamerasrc → videoflip method=none → videoconvert → v4l2sink`.
- **App closes device:** The monitor detects the disconnect and the pipeline stops. The camera LED turns off.
- **`videoflip method=none`:** Forces a CPU buffer copy — required because libcamera 0.7.0's GPU ISP produces DMA-BUF buffers that read as zeros through v4l2loopback's mmap interface.

To manage the relay:

```bash
camera-relay status          # Show current state
camera-relay start           # Start relay (foreground GStreamer pipeline)
camera-relay start-ondemand  # Start on-demand mode (idle until app opens device)
camera-relay stop            # Stop relay
camera-relay enable-persistent   # Enable on-demand mode at login (recommended)
camera-relay disable-persistent  # Disable auto-start
```

A system tray icon is also available for GUI control.

---

## What the Installer Does

The install script performs these steps:

1. **Detects distro** (Ubuntu, Fedora, Arch) and hardware (IPU6 Meteor Lake or Raptor Lake)
2. **Checks kernel version** (6.10+ required for IPU6 ISYS driver)
3. **Verifies kernel modules** (IVSC, IPU6, OV02C10)
4. **Loads IVSC modules** and adds them to initramfs (fixes the boot race condition where the OV02C10 sensor probes before IVSC is ready)
5. **Installs libcamera** (from repos on Fedora/Arch, builds from source on Ubuntu)
6. **Installs PipeWire libcamera plugin** (rebuilds SPA plugin on Ubuntu if needed)
7. **Installs sensor tuning file** (`ov02c10.yaml` with color correction matrix)
8. **Hides raw IPU6 V4L2 nodes** (udev rules + WirePlumber rules to prevent ~48 unusable "ipu6" entries in app camera lists)
9. **Installs camera relay** (v4l2loopback, GStreamer plugin, on-demand monitor, CLI tool, systray GUI)
10. **Enables PipeWire camera flag** in Chromium-based browsers (Brave, Chrome, Chromium)
11. **Restarts PipeWire** and verifies the camera is detected

---

## Supported Hardware

This fix works for any laptop with:
- Intel IPU6 on **Meteor Lake** (PCI ID `8086:7d19`) or **Raptor Lake** (PCI ID `8086:a75d`)
- **OV02C10** camera sensor (`OVTI02C1`)
- **Linux** with kernel 6.10+

This includes Samsung Galaxy Book3, Book4 Ultra, Book4 Pro, Book4 Pro 360, and possibly other laptops with the same IPU6 + OV02C10 combination (Dell, Lenovo, etc.). The core issue — IVSC modules not auto-loading — is not Samsung-specific.

**Not supported:** Galaxy Book5 (Lunar Lake / IPU7) — use [webcam-fix-book5](../webcam-fix-book5/) instead.

---

## Supported Distros

| Distro | Status | Notes |
|--------|--------|-------|
| **Ubuntu / Ubuntu-based** | Supported | Builds libcamera from source if system version is too old |
| **Fedora** | Supported | libcamera from repos |
| **Arch / CachyOS / Manjaro** | Supported | libcamera from repos |

---

## Known App Issues

### Cheese -- Crashes (broken, do not use)

GNOME Cheese crashes with a segfault (`SIGSEGV` in `libgstvideoconvertscale.so`) when receiving frames from the v4l2loopback device. This is a Cheese/Clutter bug, not a camera issue.

### GNOME Camera (snapshot) -- May crash on some systems

GNOME Camera may crash with `SIGSEGV` in `gst_video_frame_copy_plane`. **Workaround:** `LIBGL_ALWAYS_SOFTWARE=1 snapshot`

### What works

The webcam works correctly with: **Firefox**, **Chromium/Brave/Chrome** (with PipeWire camera flag), **Zoom**, **Microsoft Teams**, **OBS Studio**, **mpv**, **VLC**, and most other apps.

Quick test:
```bash
# PipeWire-native test
gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink

# V4L2 test (requires camera-relay running)
mpv av://v4l2:/dev/video0 --profile=low-latency
```

---

## Configuration Files

The install script creates these files:

| File | Purpose |
|------|---------|
| `/etc/modules-load.d/ivsc.conf` | IVSC module auto-loading at boot |
| `/etc/modprobe.d/ivsc-camera.conf` | Softdep: IVSC loads before sensor |
| `/etc/udev/rules.d/90-hide-ipu6-v4l2.rules` | Remove uaccess from raw IPU6 V4L2 nodes |
| `/etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf` | Hide raw IPU6 nodes from PipeWire (WP 0.5+) |
| `/etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua` | Hide raw IPU6 nodes from PipeWire (WP 0.4) |
| `/usr/share/libcamera/ipa/simple/ov02c10.yaml` | Sensor color tuning with CCM |
| `/usr/local/bin/camera-relay` | On-demand camera relay CLI tool |
| `/usr/local/bin/camera-relay-monitor` | V4L2 event monitor for on-demand activation |
| `/etc/modprobe.d/99-camera-relay-loopback.conf` | v4l2loopback config for camera relay |
| `/usr/local/share/camera-relay/camera-relay-systray.py` | System tray GUI |
| `/usr/share/applications/camera-relay-systray.desktop` | Desktop entry for systray |
| Initramfs entries | IVSC modules (Ubuntu: `/etc/initramfs-tools/modules`, Fedora: `/etc/dracut.conf.d/`, Arch: `/etc/mkinitcpio.conf.d/`) |

Source-built libcamera (Ubuntu) also creates:
| File | Purpose |
|------|---------|
| `/etc/profile.d/libcamera-ipa.sh` | IPA module path (login shells) |
| `/etc/environment.d/libcamera-ipa.conf` | IPA module path (systemd sessions) |

---

## Troubleshooting

### Camera not detected after reboot

Check that IVSC modules loaded:
```bash
lsmod | grep -E 'ivsc|mei.vsc'
```

If missing, verify they're in the initramfs:
```bash
# Ubuntu
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E "ivsc|mei.vsc"
# Fedora
lsinitrd | grep -E "ivsc|mei.vsc"
```

### Too many "ipu6" entries in camera list

Log out and back in for the udev rules and WirePlumber config to take effect. The rules hide raw IPU6 V4L2 nodes so only the libcamera source and Camera Relay appear.

### Zoom / OBS / VLC don't see the camera

Enable the on-demand camera relay:
```bash
camera-relay enable-persistent
```

### Chromium browser doesn't show camera

The installer auto-enables the PipeWire camera flag. If you installed a Chromium browser after running the installer, enable the flag manually:
- **Brave:** `brave://flags/#enable-webrtc-pipewire-camera` -> Enabled
- **Chrome:** `chrome://flags/#enable-webrtc-pipewire-camera` -> Enabled
- **Chromium:** `chrome://flags/#enable-webrtc-pipewire-camera` -> Enabled

Firefox works without any flags.

### Desaturated / green-tinted image

Verify the tuning file is installed:
```bash
ls /usr/share/libcamera/ipa/simple/ov02c10.yaml /usr/local/share/libcamera/ipa/simple/ov02c10.yaml 2>/dev/null
```

---

## Legacy Webcam Fix

There is an older webcam fix in [`webcam-fix/`](../webcam-fix/) that uses Intel's proprietary camera HAL (`icamerasrc`) with `v4l2-relayd`. **This is not recommended** — it's kept only as a fallback if the libcamera stack doesn't work on your hardware. The libcamera fix is open-source, supports more distros, and includes on-demand activation with near-zero idle CPU.

---

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** -- Root cause analysis, fix script, on-demand camera relay, PipeWire/WirePlumber configuration, and documentation

---

## Related Resources

- [Samsung Galaxy Book Extras (platform driver)](https://github.com/joshuagrisham/samsung-galaxybook-extras)
- [Ubuntu Intel MIPI Camera Wiki](https://wiki.ubuntu.com/IntelMIPICamera)
- [libcamera documentation](https://libcamera.org/docs.html)
- [Speaker fix (Galaxy Book4/5)](../speaker-fix/) -- MAX98390 HDA driver (DKMS)
- [Webcam fix -- Galaxy Book5 / Lunar Lake](../webcam-fix-book5/) -- IPU7 + libcamera
- [Webcam fix -- Legacy](../webcam-fix/) -- IPU6 / icamerasrc (not recommended)
