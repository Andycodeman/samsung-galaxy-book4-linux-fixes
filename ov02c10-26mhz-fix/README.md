# OV02C10 26 MHz Clock Fix (DKMS)

**Test fix** for Samsung Galaxy Book 3/4 models with **Raptor Lake IPU6** where the
OV02C10 camera sensor fails to probe with:

```
ov02c10 i2c-OVTI02C1:00: error -EINVAL: external clock 26000000 is not supported
```

## What this fixes

The upstream kernel's `ov02c10` driver only accepts a 19.2 MHz external clock.
Raptor Lake IPU6 provides 26 MHz instead. This DKMS module patches the driver to
accept both frequencies.

Based on the patch from:
https://lore.kernel.org/linux-media/CAKP_te-WT+HTEyhSvQ3snEOaTp5B1OUL18JjuzO238=_fTOuXQ@mail.gmail.com/

## Requirements

- Linux kernel with in-tree `ov02c10` driver (kernel 6.8+)
- `dkms` and kernel headers (the install script will try to install these)
- Samsung Galaxy Book with Raptor Lake IPU6 + OV02C10 sensor

## Install

```bash
sudo bash install.sh
```

## Verify

After installing, check that the driver loaded without the clock error:

```bash
dmesg | grep -i ov02c10
```

You should no longer see `external clock 26000000 is not supported`.

## Uninstall

```bash
sudo bash uninstall.sh
```

This removes the DKMS module and restores the stock kernel driver.

## How it works

The only change from the stock driver is in the `ov02c10_probe()` function:

```c
// Stock driver:
if (freq != OV02C10_MCLK)  // OV02C10_MCLK = 19200000

// Patched driver:
if (freq != OV02C10_MCLK_19_2MHZ && freq != OV02C10_MCLK_26MHZ)
```

This is the exact same fix proposed in the upstream kernel mailing list patch.
