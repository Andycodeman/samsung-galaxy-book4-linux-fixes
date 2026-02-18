# Fix: Samsung Galaxy Book5 Webcam on Arch / Fedora (Intel IPU7 / OV02C10 / Lunar Lake)

> **!! EXPERIMENTAL — UNTESTED ON SAMSUNG HARDWARE — USE AT YOUR OWN RISK !!**
>
> This fix has **NOT been tested on any Samsung Galaxy Book5 model**. It is based on research from working setups on other Lunar Lake laptops (Dell XPS 13 9350, Lenovo X1 Carbon Gen13) and one unverified Book5 360 report on Fedora 42. **It may not work, may require manual adjustments, or could potentially cause system instability.** If you try it, please report your results so we can improve it.

**Status:** Experimental / Community testing
**Supported distros:** Arch-based (CachyOS, Manjaro, EndeavourOS) and Fedora 42+
**Not supported:** Ubuntu (packages not yet available in PPAs)
**Hardware:** Intel IPU7 (Lunar Lake, PCI ID `8086:645d` or `8086:6457`), OV02C10 sensor (`OVTI02C1`)

---

## What This Fixes

The Samsung Galaxy Book5 (Lunar Lake) webcam doesn't work on Linux because:

1. **Missing `intel_cvs` kernel module** — The Intel Computer Vision Subsystem (CVS) module is required to power the camera sensor on IPU7, but it's not yet in the mainline kernel. Intel provides it via DKMS from their [vision-drivers](https://github.com/intel/vision-drivers) repo.
2. **Missing userspace pipeline** — IPU7 uses libcamera (not the IPU6 camera HAL). The `pipewire-libcamera` plugin connects libcamera to PipeWire so apps can access the camera.

This installer packages those two pieces into a single script.

---

## How It Works

The IPU7 camera pipeline is simpler than IPU6 — no v4l2loopback or relay service needed:

```
Intel IPU7  →  OV02C10 sensor  →  libcamera  →  PipeWire  →  Applications
(kernel)       (kernel)           (userspace)    (pipewire-    (Firefox, Zoom,
                                                  libcamera)    Chrome, etc.)
                  ↑
            intel_cvs (DKMS)
         powers the sensor via
         Computer Vision Subsystem
```

**Key difference from Book4 (IPU6) fix:** The Book4 fix uses Intel's proprietary camera HAL (`icamerasrc`) with a v4l2loopback relay. The Book5 fix uses the open-source libcamera stack, which talks directly to PipeWire — no relay, no loopback, no initramfs changes needed.

---

## Supported Distros

| Distro | Status | Notes |
|--------|--------|-------|
| **Arch / CachyOS / Manjaro** | Supported | libcamera 0.6+ in repos |
| **Fedora 42+** | Supported | libcamera 0.6+ in repos |
| **Ubuntu** | Not supported | libcamera + IPU7 packages not yet in PPAs |

---

## Requirements

- **Kernel 6.18+** — IPU7, USBIO, and OV02C10 drivers are all in-tree starting from 6.18
- **Lunar Lake hardware** — Intel IPU7 (PCI ID `8086:645d` or `8086:6457`)
- **Internet connection** — To download the intel_cvs DKMS module from GitHub

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

### PipeWire doesn't see the camera

If the camera works with `cam -l` but PipeWire apps don't see it:

```bash
systemctl --user restart pipewire wireplumber
```

If that doesn't help, verify that `pipewire-libcamera` (Arch) or `pipewire-plugin-libcamera` (Fedora) is installed.

---

## Tested Hardware

| Device | Platform | Distro | Status | Notes |
|--------|----------|--------|--------|-------|
| Dell XPS 13 9350 | Lunar Lake | Arch | Working | Same OV02C10 sensor |
| Lenovo X1 Carbon Gen13 | Lunar Lake | Fedora 42 | Working | Confirmed by community |
| Samsung Galaxy Book5 360 | Lunar Lake | Fedora 42 | Reported working (browsers) | Unverified single report |
| Samsung Galaxy Book5 Pro | Lunar Lake | — | **UNTESTED** | Please report if you try |
| Samsung Galaxy Book5 Pro 360 | Lunar Lake | — | **UNTESTED** | Please report if you try |

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
| **Supported distros** | Ubuntu only | Arch and Fedora |
| **Maturity** | Tested and confirmed | Experimental |
| **Directory** | `webcam-fix/` | `webcam-fix-book5/` |

---

## Configuration Files

The install script creates these files:

| File | Purpose |
|------|---------|
| `/etc/modules-load.d/intel-cvs.conf` | Load intel_cvs module at boot |
| `/etc/modprobe.d/intel-cvs-camera.conf` | Softdep: intel_cvs loads before ov02c10 |
| `/etc/environment.d/libcamera-ipa.conf` | Set LIBCAMERA_IPA_MODULE_PATH (systemd sessions) |
| `/etc/profile.d/libcamera-ipa.sh` | Set LIBCAMERA_IPA_MODULE_PATH (login shells) |
| `/usr/src/vision-driver-1.0.0/` | DKMS source for intel_cvs module |

All files are removed by `uninstall.sh`.

---

## Troubleshooting

### `cam -l` shows no cameras

1. Verify intel_cvs is loaded: `lsmod | grep intel_cvs`
2. Check kernel messages: `journalctl -b -k | grep -i "cvs\|ov02c10\|ipu"`
3. Verify IPU7 hardware: `lspci -d 8086:645d` or `lspci -d 8086:6457`
4. Try rebooting — some module loading sequences only work on fresh boot

### DKMS build fails

- Ensure kernel headers are installed:
  - Arch: `sudo pacman -S linux-headers`
  - Fedora: `sudo dnf install kernel-devel`
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
- [libcamera documentation](https://libcamera.org/docs.html)
- [Samsung Galaxy Book Extras (platform driver)](https://github.com/joshuagrisham/samsung-galaxybook-extras)
- [Speaker fix (Galaxy Book4/5)](../speaker-fix/) — MAX98390 HDA driver (DKMS)
- [Webcam fix (Galaxy Book4)](../webcam-fix/) — IPU6 / Meteor Lake / Ubuntu

### Galaxy Book4 Webcam Fix

If you have a **Galaxy Book4** (Meteor Lake / IPU6), you need the **[webcam-fix](../webcam-fix/)** directory instead. That fix uses a completely different pipeline (Intel camera HAL + v4l2loopback relay) and only supports Ubuntu.
