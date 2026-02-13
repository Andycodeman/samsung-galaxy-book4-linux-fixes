# Samsung Galaxy Book4 Linux Fixes

Fixes for hardware that doesn't work out of the box on Linux (Ubuntu 24.04+) on Samsung Galaxy Book4 laptops. Tested on the **Galaxy Book4 Ultra** — should also work on Pro, Pro 360, and Book5 models with the same hardware, but only the Ultra has been directly verified.

> **Disclaimer:** These fixes involve loading kernel modules and running scripts with root privileges. While they are designed to be safe and reversible (both include uninstall steps), they are provided **as-is with no warranty**. Modifying kernel modules carries inherent risk — in rare cases, incompatible drivers could cause boot issues or system instability. **Use at your own risk.** It is recommended to have a recent backup and know how to access recovery mode before proceeding.

## Quick Install

Each fix can be downloaded and installed in a single command — no git required.

### Speaker Fix (no sound from built-in speakers)

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/speaker-fix && sudo ./install.sh && sudo reboot
```

To uninstall: `sudo ./uninstall.sh && sudo reboot`

### Webcam Fix (built-in camera not detected)

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/webcam-fix && ./install.sh && sudo reboot
```

To uninstall: `./uninstall.sh && sudo reboot`

The webcam works with **Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC**, and most other apps. See [webcam known app issues](webcam-fix/README.md#known-app-issues) for Cheese and GNOME Camera compatibility.

---

## What's Included

### [Speaker Fix](speaker-fix/) — MAX98390 HDA Driver (DKMS)

The internal speakers use 4x Maxim MAX98390 I2C amplifiers that have no kernel driver yet. This DKMS package provides the missing driver, based on [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616).

- Builds two kernel modules via DKMS (auto-rebuilds on kernel updates)
- Creates I2C devices for the amplifiers on boot
- Loads DSM firmware with separate woofer/tweeter configurations
- Auto-detects and removes itself when native kernel support lands

> **Battery Impact:** This workaround keeps the speaker amps always-on, using ~0.3–0.5W extra (~3–5% battery life). This goes away automatically when native kernel support lands.

> **Secure Boot:** Most laptops have Secure Boot enabled. If you've never installed a DKMS/out-of-tree kernel module before, you'll need to do a **one-time MOK key enrollment** (reboot + blue screen + password) before the modules will load. See the [full walkthrough](speaker-fix/README.md#secure-boot-setup).

### [Webcam Fix](webcam-fix/) — Intel IPU6 / OV02C10

The built-in webcam uses Intel IPU6 (Meteor Lake) with an OmniVision OV02C10 sensor. Five separate issues prevent it from working reliably: IVSC modules don't auto-load, IVSC/sensor boot race condition causing intermittent black frames, missing camera HAL, v4l2loopback name mismatch, and PipeWire device misclassification. The fix includes adding IVSC modules to the initramfs (eliminating the boot race) and hardening the relay service with auto-restart.

## Tested On

- **Samsung Galaxy Book4 Ultra** — Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic (HWE)

The upstream speaker PR (#5616) was also confirmed working on Galaxy Book4 Pro, Pro 360, and Book4 Pro 16-inch by other users, so this fix should work on those models too — but it has only been directly tested on the Ultra. If you try it on another model, please report back.

## Hardware

| Component | Details |
|---|---|
| Audio Codec | Realtek ALC298 (subsystem `0x144dc1d8`) |
| Speaker Amps | 4x MAX98390 on I2C (`0x38`, `0x39`, `0x3c`, `0x3d`) |
| Camera ISP | Intel IPU6 Meteor Lake (`8086:7d19`) |
| Camera Sensor | OmniVision OV02C10 (`OVTI02C1`) |

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** — Webcam fix (research, script, documentation), speaker fix DKMS packaging, out-of-tree build workarounds, I2C device setup, automatic upstream detection, install/uninstall scripts, and all documentation in this repo
- **[Kevin Cuperus](https://github.com/thesofproject/linux/pull/5616)** — Original MAX98390 HDA side-codec driver code (upstream PR #5616)
- **DSM firmware blobs** — Extracted from Google Redrix (Chromebook with same MAX98390 amps)

## Related

- [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616) — Upstream speaker driver (not yet merged)
- [Samsung Galaxy Book Extras](https://github.com/joshuagrisham/samsung-galaxybook-extras) — Platform driver for Samsung-specific features
- [Ubuntu Intel MIPI Camera Wiki](https://wiki.ubuntu.com/IntelMIPICamera) — IPU6 camera documentation

## License

[GPL-2.0](LICENSE) — Free to use, modify, and redistribute. Derivative works must use the same license.
