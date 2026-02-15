# Samsung Galaxy Book4 Linux Fixes

Fixes for hardware that doesn't work out of the box on Linux on Samsung Galaxy Book4/5 laptops. Tested on the **Galaxy Book4 Ultra** — should also work on Pro, Pro 360, and Book5 models with the same hardware, but only the Ultra has been directly verified.

> **Distro support:** The **speaker fix** works on Ubuntu, Fedora, and Arch-based distros (CachyOS, Manjaro, etc. — `dkms` and `linux-headers` must be installed first, see [speaker-fix README](speaker-fix/)). The **webcam fix** currently requires **Ubuntu or Ubuntu-based distros** (uses apt, PPA packages, and initramfs-tools). Fedora and Arch are not yet supported for the webcam fix.

> **Disclaimer:** These fixes involve loading kernel modules and running scripts with root privileges. While they are designed to be safe and reversible (both include uninstall steps), they are provided **as-is with no warranty**. Modifying kernel modules carries inherent risk — in rare cases, incompatible drivers could cause boot issues or system instability. **Use at your own risk.** It is recommended to have a recent backup and know how to access recovery mode before proceeding.

## Quick Install

Each fix can be downloaded and installed in a single command — no git required.

### Speaker Fix (no sound from built-in speakers)

> **Microphone note (Book4 models):** On Galaxy Book4 (Meteor Lake), the built-in DMIC does not work with or without this fix — no mic functionality is lost. On **Galaxy Book5** (Lunar Lake), the speaker fix works and the **built-in mic continues to work** after installation. See [Microphone Status](#microphone-status) for details.

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/speaker-fix && sudo ./install.sh && sudo reboot
```

To uninstall: `sudo ./uninstall.sh && sudo reboot`

### Webcam Fix (built-in camera not detected) — Meteor Lake / Galaxy Book4 / Ubuntu only

> **Lunar Lake (Galaxy Book5) not supported:** This webcam fix is for **Meteor Lake (IPU6)** systems only — Galaxy Book4 models. Galaxy Book5 models use **Lunar Lake (IPU7)**, which has a completely different camera driver stack. The install script will detect Lunar Lake and show a helpful message. Lunar Lake webcam support is being tracked upstream at [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers).

> **Ubuntu only:** The webcam fix requires Ubuntu or Ubuntu-based distros (apt, PPA packages, initramfs-tools). Fedora and Arch-based distros are not currently supported.

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/webcam-fix && ./install.sh && sudo reboot
```

To uninstall: `./uninstall.sh && sudo reboot`

The webcam works with **Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC**, and most other apps. See [webcam known app issues](webcam-fix/README.md#known-app-issues) for Cheese and GNOME Camera compatibility.

---

## What's Included

### [Speaker Fix](speaker-fix/) — MAX98390 HDA Driver (DKMS) — Output Only

The internal speakers use 4x Maxim MAX98390 I2C amplifiers that have no kernel driver yet. This DKMS package provides the missing driver, based on [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616). **Note:** This fix addresses speaker output only — it does not enable the built-in microphones (see [Microphone Status](#microphone-status) below).

- Builds two kernel modules via DKMS (auto-rebuilds on kernel updates)
- Creates I2C devices for the amplifiers on boot
- Loads DSM firmware with separate woofer/tweeter configurations
- Auto-detects and removes itself when native kernel support lands

> **Sound Quality:** Audio will sound thinner and lack bass compared to Windows. This is because Windows uses Samsung's DSP audio processing (Dolby Atmos, bass enhancement, EQ) which Linux doesn't have. See [Sound Quality & EQ](speaker-fix/README.md#sound-quality--eq) for details and a workaround using EasyEffects.

> **Battery Impact:** This workaround keeps the speaker amps always-on, using ~0.3–0.5W extra (~3–5% battery life). This goes away automatically when native kernel support lands.

> **Secure Boot:** Most laptops have Secure Boot enabled. If you've never installed a DKMS/out-of-tree kernel module before, you'll need to do a **one-time MOK key enrollment** (reboot + blue screen + password) before the modules will load. See the [full walkthrough](speaker-fix/README.md#secure-boot-setup).

> **Fedora / DNF-based distros:** The install script auto-detects Fedora and configures DKMS module signing using the akmods MOK key (`/etc/pki/akmods/`). If no key exists, it generates one with `kmodgenca` and prompts for enrollment. Confirmed working on Fedora 43, kernel 6.18.9 (Galaxy Book4 Ultra).

### [Webcam Fix](webcam-fix/) — Intel IPU6 / OV02C10 (Meteor Lake + Ubuntu only)

The built-in webcam uses Intel IPU6 (Meteor Lake) with an OmniVision OV02C10 sensor. Five separate issues prevent it from working reliably: IVSC modules don't auto-load, IVSC/sensor boot race condition causing intermittent black frames, missing camera HAL, v4l2loopback name mismatch, and PipeWire device misclassification. The fix includes adding IVSC modules to the initramfs (eliminating the boot race) and hardening the relay service with auto-restart.

> **Note:** This webcam fix only supports **Meteor Lake (IPU6)** on **Ubuntu (and Ubuntu-based distros)**. Galaxy Book5 (Lunar Lake / IPU7) is not supported (different driver stack). Fedora and Arch-based distros are not yet supported (the install script uses apt, Ubuntu PPAs, and initramfs-tools).

## Microphone Status

The Galaxy Book4/5 laptops have built-in dual array digital microphones (DMIC). Whether they work on Linux **depends on your model and audio driver**:

| Model | Platform | Default Driver | Mic (without speaker fix) | Mic (with speaker fix) |
|-------|----------|---------------|--------------------------|----------------------|
| Book4 Ultra | Meteor Lake | Legacy HDA | No | No |
| Book4 Pro / Pro 360 | Meteor Lake | Legacy HDA | Unknown | No |
| Book5 Pro | Lunar Lake | SOF | **Yes** | **Yes** (Ubuntu/Fedora confirmed) |
| Book5 Pro 360 | Lunar Lake | SOF | **Yes** | **Yes** (Ubuntu/Fedora confirmed) |

**Good news for Book5 owners:** The speaker fix has been confirmed working on Galaxy Book5 Pro models, and the built-in microphone **continues to work** after installing the speaker fix. On Lunar Lake, the SOF driver coexists with the legacy HDA driver, so both speakers and DMIC work together.

> **Arch-based distros (CachyOS, Manjaro, etc.):** The DMIC on Book5 models requires SOF firmware, which is **not installed by default** on Arch. If your mic doesn't work after installing the speaker fix, install the firmware: `sudo pacman -S sof-firmware` and reboot. This is not caused by the speaker fix — the mic may not have worked before either without this package.

**For Book4 models:** The built-in DMIC does not work on Meteor Lake with the legacy HDA driver, regardless of whether the speaker fix is installed. The DMIC requires SOF support that is not yet available for Meteor Lake.

**When will Book4 mic work?** The [SOF upstream PR #5616](https://github.com/thesofproject/linux/pull/5616) is building native SOF support for Galaxy Book4/5 that will handle both speakers and DMIC together. This is expected to land in **Linux kernel 7.0 (mid-April 2026)** or **7.1 (June 2026)**. Once that ships in your distro kernel, the speaker fix in this repo will auto-detect native support and remove itself, and the built-in microphones should work automatically on Book4 models too.

**Workarounds for Book4 mic:**
- Use a **USB headset or microphone** — works immediately, no configuration needed
- Use the **3.5mm headphone/mic combo jack** — the external mic input (ALC298 Node 0x18) is functional

## Tested On

- **Samsung Galaxy Book4 Ultra** — Ubuntu 24.04 LTS, kernel 6.17.0-14-generic (HWE)
- **Samsung Galaxy Book4 Ultra** — Fedora 43, kernel 6.18.9 (community-confirmed)
- **Samsung Galaxy Book4 Pro** — Ubuntu 25.10, kernel 6.18.7, speaker fix confirmed (community-confirmed)
- **Samsung Galaxy Book5 Pro** — Speaker fix confirmed working, mic continues to work (community-confirmed)

The upstream speaker PR (#5616) was also confirmed working on Galaxy Book4 Pro, Pro 360, and Book4 Pro 16-inch by other users, so this fix should work on those models too. If you try it on another model or distro, please report back.

**Note:** The webcam fix is for **Meteor Lake (Galaxy Book4) only**. Galaxy Book5 (Lunar Lake) uses a different camera driver (IPU7) — see [Webcam Fix](webcam-fix/) for details.

## Hardware

| Component | Details |
|---|---|
| Audio Codec | Realtek ALC298 (subsystem `0x144dc1d8`) |
| Speaker Amps | 4x MAX98390 on I2C (`0x38`, `0x39`, `0x3c`, `0x3d`) |
| Camera ISP | Intel IPU6 Meteor Lake (`8086:7d19`) |
| Camera Sensor | OmniVision OV02C10 (`OVTI02C1`) |
| Microphones | Dual array DMIC (digital — status varies by model, see [Microphone Status](#microphone-status)) |

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
