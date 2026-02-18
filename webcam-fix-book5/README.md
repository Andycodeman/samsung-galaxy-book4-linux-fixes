# Fix: Samsung Galaxy Book5 Webcam on Arch / Fedora / Ubuntu (Intel IPU7 / OV02C10 / Lunar Lake)

> **!! EXPERIMENTAL — UNTESTED ON SAMSUNG HARDWARE — USE AT YOUR OWN RISK !!**
>
> This fix has **NOT been tested on any Samsung Galaxy Book5 model**. It is based on research from working setups on other Lunar Lake laptops (Dell XPS 13 9350, Lenovo X1 Carbon Gen13) and one unverified Book5 360 report on Fedora 42. **It may not work, may require manual adjustments, or could potentially cause system instability.** If you try it, please report your results so we can improve it.

**Status:** Experimental / Community testing
**Supported distros:** Arch-based (CachyOS, Manjaro, EndeavourOS), Fedora 42+, and Ubuntu (with libcamera 0.6+ built from source)
**Hardware:** Intel IPU7 (Lunar Lake, PCI ID `8086:645d` or `8086:6457`), OV02C10 (`OVTI02C1`) or OV02E10 (`OVTI02E1`) sensor

---

## What This Fixes

The Samsung Galaxy Book5 (Lunar Lake) webcam doesn't work on Linux because:

1. **Missing `intel_cvs` kernel module** — The Intel Computer Vision Subsystem (CVS) module is required to power the camera sensor on IPU7, but it's not yet in the mainline kernel. Intel provides it via DKMS from their [vision-drivers](https://github.com/intel/vision-drivers) repo.
2. **LJCA modules don't auto-load** — The Lunar Lake Joint Controller for Accessories (`usb_ljca`, `gpio_ljca`) provides GPIO/USB control needed by the vision subsystem. These must load before `intel_cvs` and the sensor, but aren't auto-loaded on all systems.
3. **Missing userspace pipeline** — IPU7 uses libcamera (not the IPU6 camera HAL). The `pipewire-libcamera` plugin connects libcamera to PipeWire so apps can access the camera.
4. **Raw IPU7 video nodes exposed** — IPU7 creates multiple `/dev/video*` nodes that confuse apps enumerating cameras. These need to be hidden via udev.

This installer packages all of those pieces into a single script.

---

## How It Works

The IPU7 camera pipeline is simpler than IPU6 — no v4l2loopback or relay service needed:

```
usb_ljca + gpio_ljca  →  intel_cvs (DKMS)  →  OV02C10/OV02E10  →  libcamera  →  PipeWire  →  Apps
(LJCA GPIO/USB)           (powers sensor)      (kernel sensor)      (userspace)   (pipewire-    (Firefox,
                                                                                   libcamera)    Zoom, etc.)
```

**Key difference from Book4 (IPU6) fix:** The Book4 fix uses Intel's proprietary camera HAL (`icamerasrc`) with a v4l2loopback relay. The Book5 fix uses the open-source libcamera stack, which talks directly to PipeWire — no relay, no loopback, no initramfs changes needed.

---

## Supported Distros

| Distro | Status | Notes |
|--------|--------|-------|
| **Arch / CachyOS / Manjaro** | Supported | libcamera 0.6+ in repos |
| **Fedora 42+** | Supported | libcamera 0.6+ in repos |
| **Ubuntu** | Supported (with manual steps) | Requires libcamera 0.6+ built from source and kernel 6.18+ compiled manually. See [Ubuntu instructions](#ubuntu-specific-setup) below. |

---

## Requirements

- **Kernel 6.18+** — IPU7, USBIO, and OV02C10 drivers are all in-tree starting from 6.18
- **Lunar Lake hardware** — Intel IPU7 (PCI ID `8086:645d` or `8086:6457`)
- **libcamera 0.6+** — Available in Arch/Fedora repos; must be built from source on Ubuntu
- **Internet connection** — To download the intel_cvs DKMS module from GitHub

---

## Ubuntu-Specific Setup

Ubuntu 24.04 ships kernel 6.17 and libcamera 0.2.x — both too old for IPU7. To use this fix on Ubuntu, you need to manually provide:

1. **Kernel 6.18+** — Compile from source or install a [mainline kernel build](https://kernel.ubuntu.com/mainline/). One user confirmed kernel 6.19.2 works.
2. **libcamera 0.6+** — Build from source following the [libcamera getting started guide](https://libcamera.org/getting-started.html). Ubuntu's apt packages are too old.

The installer will detect Ubuntu and **check your libcamera version** at runtime. If libcamera 0.6+ is found (however you installed it), the script will proceed — it skips the package install step and only sets up the DKMS module and configuration files.

**Reference:** The [Arch Wiki Dell XPS 13 9350 camera page](https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera) has a detailed walkthrough for the same hardware. The steps can be adapted for Ubuntu.

---

## Quick Install

**No git?** Download, install, and reboot in one step:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/webcam-fix-book5 && ./install.sh && sudo reboot
```

**Already cloned?**

```bash
./install.sh
sudo reboot
```

**Skip hardware check** (for testing on non-Lunar Lake systems):

```bash
./install.sh --force
```

---

## Uninstall

```bash
./uninstall.sh
sudo reboot
```

The uninstaller removes the DKMS module, source files, and all configuration files. It does **not** remove distro packages (libcamera, etc.) since you may need them for other purposes.

---

## Known Issues

### Green tint / color cast

IPU7 + libcamera may produce a green tint or incorrect white balance. This is because libcamera calibration/tuning profiles for specific sensors on IPU7 are still being developed. This is a **libcamera tuning issue**, not a driver bug.

**Workaround:** Adjust white balance in your app if possible, or wait for updated libcamera tuning files.

### No calibration profiles

Sensor-specific IPA (Image Processing Algorithm) tuning files may not exist yet for the OV02C10 on IPU7. libcamera will use defaults, which may result in suboptimal image quality.

### Vertically flipped image

Some setups produce an upside-down camera preview. This is a sensor orientation / libcamera tuning issue — the rotation metadata for the OV02C10 on some platforms may be incorrect or missing.

### Firefox / browser conflicts with qcam

One user reported that opening the camera in Firefox kills the image in qcam, requiring a reboot to recover. This appears to be a resource contention issue between PipeWire and direct libcamera access. Avoid running qcam and browser-based camera access simultaneously.

### PipeWire doesn't see the camera

If the camera works with `cam -l` but PipeWire apps don't see it:

```bash
systemctl --user restart pipewire wireplumber
```

If that doesn't help, verify that `pipewire-libcamera` (Arch) or `pipewire-plugin-libcamera` (Fedora) is installed. On Ubuntu, you may need to build the PipeWire libcamera SPA plugin from source.

---

## Tested Hardware

| Device | Platform | Distro | Kernel | Status | Notes |
|--------|----------|--------|--------|--------|-------|
| Dell XPS 13 9350 | Lunar Lake | Arch | 6.18+ | Working | OV02C10 sensor |
| Lenovo X1 Carbon Gen13 | Lunar Lake | Fedora 42 | 6.18+ | Working | Confirmed by community |
| Samsung Galaxy Book5 360 | Lunar Lake | Fedora 42 | 6.18+ | Working (browsers) | Community report |
| Samsung Galaxy Book5 360 | Lunar Lake | Ubuntu 24.04 | 6.19.2 | Working (qcam) | OV02E10 sensor. Image flipped, Firefox conflict. Kernel + libcamera from source. |
| Samsung Galaxy Book5 Pro | Lunar Lake | — | — | **UNTESTED** | Please report if you try |
| Samsung Galaxy Book5 Pro 360 | Lunar Lake | — | — | **UNTESTED** | Please report if you try |

**If you test this on a Galaxy Book5, please open an issue with:**
- Your exact model
- Distro and kernel version
- Output of `cam -l`
- Whether apps (Firefox, Zoom, etc.) can see the camera
- Any error messages from `journalctl -b -k | grep -i "ipu\|cvs\|ov02c10\|libcamera"`

---

## Comparison with Book4 (Meteor Lake / IPU6) Webcam Fix

| | Book4 (IPU6) | Book5 (IPU7) |
|---|---|---|
| **Camera ISP** | IPU6 (Meteor Lake) | IPU7 (Lunar Lake) |
| **Userspace pipeline** | Intel camera HAL (`icamerasrc`) | libcamera (open source) |
| **PipeWire bridge** | v4l2loopback + v4l2-relayd | pipewire-libcamera (direct) |
| **Out-of-tree module** | None (IVSC modules are in-tree) | `intel_cvs` via DKMS |
| **Initramfs changes** | Yes (IVSC boot race fix) | No |
| **Supported distros** | Ubuntu only | Arch, Fedora, Ubuntu (source build) |
| **Maturity** | Tested and confirmed | Experimental |
| **Directory** | `webcam-fix/` | `webcam-fix-book5/` |

---

## Configuration Files

The install script creates these files:

| File | Purpose |
|------|---------|
| `/etc/modules-load.d/intel-ipu7-camera.conf` | Load LJCA + intel_cvs modules at boot |
| `/etc/modprobe.d/intel-ipu7-camera.conf` | Softdep: LJCA -> intel_cvs -> sensor load order |
| `/etc/udev/rules.d/90-hide-ipu7-v4l2.rules` | Hide raw IPU7 video nodes from apps |
| `/etc/environment.d/libcamera-ipa.conf` | Set LIBCAMERA_IPA_MODULE_PATH (systemd sessions) |
| `/etc/profile.d/libcamera-ipa.sh` | Set LIBCAMERA_IPA_MODULE_PATH (login shells) |
| `/usr/src/vision-driver-1.0.0/` | DKMS source for intel_cvs module |

All files are removed by `uninstall.sh`.

---

## Troubleshooting

### `cam -l` shows no cameras

1. Verify LJCA modules are loaded: `lsmod | grep ljca`
2. Verify intel_cvs is loaded: `lsmod | grep intel_cvs`
3. Check kernel messages: `journalctl -b -k | grep -i "cvs\|ov02c10\|ov02e10\|ljca\|ipu"`
4. Verify IPU7 hardware: `lspci -d 8086:645d` or `lspci -d 8086:6457`
5. Try loading manually in order: `sudo modprobe usb_ljca && sudo modprobe gpio_ljca && sudo modprobe intel_cvs`
6. Try rebooting — some module loading sequences only work on fresh boot

### DKMS build fails

- Ensure kernel headers are installed:
  - Arch: `sudo pacman -S linux-headers`
  - Fedora: `sudo dnf install kernel-devel`
  - Ubuntu: `sudo apt install linux-headers-$(uname -r)`
- Check DKMS build log: `cat /var/lib/dkms/vision-driver/1.0.0/build/make.log`

### Secure Boot: module not loading

If Secure Boot is enabled, the DKMS module must be signed. On Fedora, the installer handles this with the akmods MOK key. You may need to:

1. Enroll the MOK key: `sudo mokutil --import /etc/pki/akmods/certs/public_key.der`
2. Reboot and complete the enrollment at the blue MOK Manager screen

On Arch with Secure Boot, you'll need to sign the module manually or use a tool like `sbsigntools`.

---

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** — Installer script, packaging, documentation
- **[Intel vision-drivers](https://github.com/intel/vision-drivers)** — CVS kernel module (DKMS)
- **libcamera project** — Open-source camera stack with IPU7 support

---

## Related Resources

- [Intel vision-drivers (CVS module)](https://github.com/intel/vision-drivers)
- [Arch Wiki — Dell XPS 13 9350 Camera](https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera) — Same Lunar Lake + OV02C10 setup
- [libcamera documentation](https://libcamera.org/docs.html)
- [Samsung Galaxy Book Extras (platform driver)](https://github.com/joshuagrisham/samsung-galaxybook-extras)
- [Speaker fix (Galaxy Book4/5)](../speaker-fix/) — MAX98390 HDA driver (DKMS)
- [Webcam fix (Galaxy Book4)](../webcam-fix/) — IPU6 / Meteor Lake / Ubuntu

### Galaxy Book4 Webcam Fix

If you have a **Galaxy Book4** (Meteor Lake / IPU6), you need the **[webcam-fix](../webcam-fix/)** directory instead. That fix uses a completely different pipeline (Intel camera HAL + v4l2loopback relay) and only supports Ubuntu.
