# Samsung Galaxy Book4 — Speaker Fix (MAX98390 HDA Driver)

## Quick Install

Download and install in one step — no git required:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/speaker-fix && sudo ./install.sh && sudo reboot
```

**Already cloned?** `sudo ./install.sh && sudo reboot`

To uninstall: `sudo ./uninstall.sh && sudo reboot`

---

> **Battery Impact:** This workaround keeps the speaker amplifiers powered on at all times (even when not playing audio), which uses an estimated **0.3–0.5W extra** (~3–5% battery life). This is a limitation of the workaround approach — when the upstream kernel fix eventually lands, proper power management will be handled automatically and this package will auto-remove itself.

> **Secure Boot Users:** If you have Secure Boot enabled (most laptops do by default), you **must** enroll a Machine Owner Key (MOK) before the driver modules will load. If you've never installed a DKMS or out-of-tree kernel module before, you will need to complete a **one-time MOK enrollment** that involves a reboot and typing a password in a blue setup screen. See the [Secure Boot Setup](#secure-boot-setup) section below — **do this before running the install script**.

## The Problem

Samsung Galaxy Book4 laptops using **MAX98390 speaker amplifiers** have no audio output from the built-in speakers on Linux. The headphone jack works fine, but the laptop speakers are completely silent.

**Tested on:**
- Samsung Galaxy Book4 Ultra — Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic (HWE)
- Samsung Galaxy Book4 Ultra — Fedora 43, Kernel 6.18.9 (community-confirmed)
- Samsung Galaxy Book5 Pro — Speaker fix works, mic continues to work (community-confirmed)

The upstream PR was also reported working on Galaxy Book4 Pro, Pro 360, and Pro 16-inch by other users — this fix should work on those models too.

> **Book5 owners:** The speaker fix works on Galaxy Book5 Pro models and the built-in microphone continues to work after installation. The install script auto-detects the number of amplifiers present on your model.

> **Fedora users:** The install script auto-detects Fedora (DNF) and configures DKMS module signing using the akmods MOK key. If no key exists, it generates one and prompts for enrollment.

This affects systems with:
- **HDA Codec**: Realtek ALC298 (subsystem ID `0x144dc1d8` or similar Samsung variants)
- **Speaker Amps**: 4x Maxim MAX98390 connected via I2C (addresses `0x38`, `0x39`, `0x3c`, `0x3d`)
- **Kernel**: 6.x series (tested on 6.17.0-14-generic, Ubuntu 24.04)

### Root Cause

The stock kernel is missing three things needed to drive these amps:

1. **`serial-multi-instantiate`** doesn't know about the `MAX98390` ACPI device ID, so it doesn't enumerate all 4 amplifiers
2. **`snd_hda_codec_alc269`** has no quirk entry for Samsung's MAX98390 subsystem IDs, so it never sets up the HDA side-codec component master
3. **`snd-hda-scodec-max98390`** (the actual amp driver) doesn't exist in the kernel tree yet

An upstream fix is in progress at [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616), but hasn't been merged into mainline yet.

## What This Fix Does

This is a **DKMS out-of-tree driver package** that provides the missing `snd-hda-scodec-max98390` driver. It works around the other two missing pieces (serial-multi-instantiate and alc269 quirk) by:

- **Manually creating I2C devices** for the 3 amps that ACPI doesn't enumerate (the first amp at `0x38` is created by ACPI automatically)
- **Enabling the amps during driver probe** rather than relying on HDA playback hooks (which require the missing alc269 quirk)
- **Loading DSM (Dynamic Speaker Management) firmware** with separate woofer/tweeter configurations

### Speaker Layout

| I2C Address | Component Index | Type | Channel |
|---|---|---|---|
| `0x38` | 0 | Woofer | Left |
| `0x39` | 1 | Woofer | Right |
| `0x3c` | 2 | Tweeter | Left |
| `0x3d` | 3 | Tweeter | Right |

### What Gets Installed

| File | Purpose |
|---|---|
| `snd-hda-scodec-max98390.ko` | Core HDA side-codec driver (init, DSM, component binding) |
| `snd-hda-scodec-max98390-i2c.ko` | I2C transport driver (probe, regmap, ACPI matching) |
| `/usr/local/sbin/max98390-hda-i2c-setup.sh` | Creates I2C devices for amps 2-4 on boot |
| `/usr/local/sbin/max98390-hda-check-upstream.sh` | Checks for native kernel support; auto-removes this package when found |
| `/etc/systemd/system/max98390-hda-i2c-setup.service` | Systemd service: runs I2C setup on boot |
| `/etc/systemd/system/max98390-hda-check-upstream.service` | Systemd service: upstream detection on boot |
| `/etc/modules-load.d/max98390-hda.conf` | Ensures modules load on every boot |
| `/usr/src/max98390-hda-1.0/` | DKMS source tree (auto-rebuilds on kernel updates) |

## Installation

### Prerequisites

```bash
# Ubuntu / Debian
sudo apt install dkms linux-headers-$(uname -r)

# Fedora
sudo dnf install dkms kernel-devel
```

### Install

```bash
git clone <this-repo>
cd speaker-fix
sudo ./install.sh
sudo reboot
```

The install script will:
1. Verify MAX98390 hardware is present (refuses to install on unsupported systems)
2. Build the kernel modules via DKMS (auto-signs for Secure Boot if MOK keys are configured)
3. Install systemd services and module autoload config
4. DKMS will auto-rebuild the modules on every kernel update

### Test Without Reboot

```bash
sudo ./install.sh
sudo systemctl start max98390-hda-i2c-setup.service
# Speakers should work immediately
```

### Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

## Automatic Upstream Detection

A systemd service runs on every boot to check if the running kernel has gained native MAX98390 support. It checks three conditions:

1. `serial-multi-instantiate` has a `MAX98390` alias
2. `snd_hda_codec_alc269` contains the `alc298-samsung-max98390` quirk string
3. `snd-hda-scodec-max98390` exists in the kernel module tree (not just DKMS)

**When all three pass**, the service automatically removes the entire DKMS workaround — modules, services, scripts, everything. Speakers continue working that session (modules are already loaded in memory), and on the next reboot the native kernel driver takes over. No user interaction needed.

## How It Works (Technical Details)

### The Workaround

The upstream PR (#5616) touches 5 areas of the kernel:

1. `drivers/acpi/scan.c` — built-in, can't be changed without recompiling the kernel
2. `drivers/platform/x86/serial-multi-instantiate.c` — adds MAX98390 enumeration
3. `sound/pci/hda/patch_realtek.c` — adds Samsung quirk entries to alc269
4. `sound/soc/codecs/max98390.c` — exports regmap config
5. `sound/hda/codecs/side-codecs/` — new MAX98390 HDA driver (this package)

This DKMS package only implements #5 (the new driver) and works around #1-#4:

- **Instead of scan.c + serial-multi-instantiate**: A systemd service dynamically finds the I2C bus via ACPI and creates the missing I2C devices via sysfs `new_device`
- **Instead of the alc269 quirk**: The driver enables amps during `probe()` (sets `GLOBAL_EN=1`, `SPK_EN=0x81`) rather than relying on HDA playback hooks
- **Instead of the exported regmap**: A local `regmap_config` with `REGCACHE_NONE` is defined in the driver headers

### Always-On Amps

Because the alc269 quirk isn't applied, the HDA component master is never created, so playback hooks don't fire. The amps are instead initialized to "always on" during probe. This means:

- Speakers work immediately with no dependency on the HDA codec driver
- The amps consume ~0.3-0.5W when idle (roughly 3-5% battery impact)
- When the upstream fix eventually lands, the playback hooks will properly power-manage the amps

### I2C Bus Detection

The I2C setup script doesn't hardcode a bus number. It dynamically finds the correct bus by:
1. Searching `/sys/bus/i2c/devices/` for any device matching `MAX98390`
2. Following symlinks to find the parent I2C adapter
3. Falling back to ACPI device path resolution

This makes it portable across Galaxy Book4 Pro, Pro 360, Ultra, and Book5 models.

### Secure Boot

DKMS handles module signing automatically if MOK (Machine Owner Key) keys are configured. See the full [Secure Boot Setup](#secure-boot-setup) section below if you haven't set this up before.

## File Structure

```
speaker-fix/
├── README.md                           # This file
├── install.sh                          # Installer (run with sudo)
├── uninstall.sh                        # Uninstaller (run with sudo)
├── dkms.conf                           # DKMS build configuration
├── max98390-hda-i2c-setup.sh           # I2C device creation script
├── max98390-hda-i2c-setup.service      # Systemd service for I2C setup
├── max98390-hda-check-upstream.sh      # Upstream detection + auto-removal
├── max98390-hda-check-upstream.service # Systemd service for upstream check
└── src/
    ├── Makefile                        # Kernel module build rules
    ├── max98390_hda.c                  # Core driver (init, component, PM)
    ├── max98390_hda.h                  # Driver private structures
    ├── max98390_hda_i2c.c              # I2C transport + probe logic
    ├── max98390_hda_filters.c          # DSM firmware blobs + filter config
    ├── max98390_hda_filters.h          # Filter function declarations
    ├── max98390_regs.h                 # Register definitions + local regmap
    ├── hda_scodec_component.h          # HDA side-codec component framework
    └── hda_generic.h                   # PCM action enum shim
```

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** — DKMS packaging, out-of-tree build workarounds (local headers, regmap shim), I2C probe fix (address-based index derivation), dynamic I2C bus detection, automatic upstream detection and self-removal, install/uninstall scripts, systemd services, and documentation
- **[Kevin Cuperus](https://github.com/thesofproject/linux/pull/5616)** — Original MAX98390 HDA side-codec driver code, DSM filter configuration, and HDA component integration (upstream PR #5616)
- **DSM firmware blobs** — Extracted from Google Redrix (Chromebook with same MAX98390 amps)

## Troubleshooting

**Speakers not working after install + reboot?**
```bash
# Check if modules loaded
lsmod | grep max98390

# Check if I2C devices were created
ls /sys/bus/i2c/devices/ | grep -i max

# Check service status
systemctl status max98390-hda-i2c-setup.service

# Check kernel log for driver messages
dmesg | grep -i max98390
```

**DKMS build fails on kernel update?**
```bash
# Check if headers are installed for the new kernel
sudo apt install linux-headers-$(uname -r)   # Ubuntu/Debian
sudo dnf install kernel-devel                 # Fedora

# Rebuild manually
sudo dkms build max98390-hda/1.0
sudo dkms install max98390-hda/1.0
```

## Secure Boot Setup

**If Secure Boot is disabled on your system, skip this section entirely.** Check with:

```bash
mokutil --sb-state
# "SecureBoot enabled" = you need to do this
# "SecureBoot disabled" = skip this section
```

Secure Boot prevents unsigned kernel modules from loading. DKMS on Ubuntu can auto-sign modules using a Machine Owner Key (MOK), but the key must be **enrolled in your firmware** first. This is a one-time process.

### Step 1: Check if MOK keys already exist

```bash
ls /var/lib/shim-signed/mok/MOK.der /var/lib/shim-signed/mok/MOK.priv 2>/dev/null
```

If both files exist, skip to Step 2. If not, Ubuntu's `shim-signed` package usually generates them automatically. If they're missing:

```bash
sudo apt install shim-signed
# Keys should now exist at /var/lib/shim-signed/mok/
```

### Step 2: Check if the MOK is already enrolled

```bash
mokutil --list-enrolled
```

If you see a key listed, you're already set — skip to the install. If it says "MokListRT is empty" or shows no keys, continue to Step 3.

### Step 3: Enroll the MOK key

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
```

You'll be prompted to create a **one-time password**. Remember it — you'll need to type it on the next screen.

### Step 4: Reboot into MOK Manager

```bash
sudo reboot
```

On reboot, instead of booting normally, you'll see a **blue screen** (MOK Manager). This is expected:

1. Select **"Enroll MOK"**
2. Select **"Continue"**
3. Select **"Yes"**
4. **Type the password** you created in Step 3
5. Select **"Reboot"**

After this, your MOK is permanently enrolled. You never need to do this again — all future DKMS module builds (including kernel updates) will be auto-signed and load without issues.

### Step 5: Verify

After rebooting:

```bash
mokutil --list-enrolled | head -5
# Should show [key 1] with a SHA1 fingerprint
```

**Now you can run the install script.** If you already ran it before enrolling the MOK, just reboot — DKMS already signed the modules during install, they just couldn't load until the key was enrolled.

## See Also

- **[Webcam Fix](../webcam-fix/)** — Fix for the built-in webcam (Intel IPU6 / OV02C10) on the same laptops
