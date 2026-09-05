# LoRaspbian KEYED U-Boot (Luckfox Lyra Zero W)

## Why

MeshAdv Mini routes GPS NMEA TX to **header pin 10**. On Lyra Zero W, pins
**8/10 are UART0** (RM_IO22/23). Vendor Armbian U-Boot uses UART0 as
`DEBUG_UART` at **1500000** baud with `BOOTDELAY=1` and **unkeyed** autoboot
(`# CONFIG_AUTOBOOT_KEYED is not set`). Any RX byte/noise aborts the countdown
and drops to the `=>` prompt — Linux never starts. Solid red LED = power OK,
no kernel.

Device-tree overlays cannot fix this (they run after U-Boot).

## Fix

Enable keyed autoboot; only the stop string aborts boot:

| Option | Value |
|---|---|
| `CONFIG_AUTOBOOT_KEYED` | `y` |
| `CONFIG_AUTOBOOT_STOP_STR` | `uboot` |
| `CONFIG_AUTOBOOT_FLUSH_STDIN` | `y` |
| `CONFIG_AUTOBOOT_PROMPT` | `Hit 'uboot' to stop autoboot: %d\n` |
| `CONFIG_LOCALVERSION` | `-loraspbian-keyed` |

Fragment: [`autoboot-keyed.fragment`](autoboot-keyed.fragment).

## Build (host, once)

Based on Armbian mainline for this board (2026-09):

- U-Boot branch/tag: `v2026.07`
- Patches: Armbian `patch/u-boot/v2026.07-rk3506/`
- Defconfig: `luckfox-lyra-zero-w-rk3506b_defconfig`
- Blobs (match board package when possible):
  - `ROCKCHIP_TPL=rk3506b_ddr_750MHz_v1.06.bin`
  - `TEE=rk3506_tee_v2.10.bin`
- Output: `u-boot-rockchip.bin`
- Host tool note: disable `CONFIG_TOOLS_MKEFICAPSULE` if host lacks gnutls-dev
  (not needed for Rockchip SPL image).

Workspace used for first KEYED build: `/tmp/opencode/lyra-uboot-build/`.
Binary kept gitignored under `client-setup/u-boot-rockchip-keyed.bin` on the
build host (not pushed).

```bash
# sketch — see HANDOFF § KEYED U-Boot for full env
export CROSS_COMPILE=arm-linux-gnueabihf-
export ARCH=arm
make luckfox-lyra-zero-w-rk3506b_defconfig
# merge autoboot-keyed.fragment into .config
make -j$(nproc) DTC=$(which dtc) \
  ROCKCHIP_TPL=.../rk3506b_ddr_750MHz_v1.06.bin \
  TEE=.../rk3506_tee_v2.10.bin
# → u-boot-rockchip.bin
```

## Install on a live board

**Same recipe as** `/usr/lib/u-boot/platform_install.sh`:

```bash
# BACK UP first 16MiB of MMC, then:
sudo dd if=u-boot-rockchip-keyed.bin of=/dev/mmcblk0 bs=32k seek=1 conv=notrunc
sudo sync && sudo reboot
```

**Never flash lyra1 (10.0.0.108)** while it carries the production MeshAdv Pi
Hat path unless intentionally migrating that node. Test board: **lyra2
(10.0.0.56)**.

Restore stock from backup:

```bash
sudo dd if=uboot-backup-pre-keyed-16M.bin of=/dev/mmcblk0 bs=1M count=16 conv=notrunc
```

## Serial rescue

- Baud: **1500000** (U-Boot/SPL); Linux later **115200** on `ttyS2` (often
  disabled in DT — prefer SSH).
- To enter U-Boot prompt: type **`uboot`** during the countdown (not any key).

## Gold image bake (TODO)

Future: rebuild `linux-u-boot-luckfox-lyra-zero-w-vendor` with this fragment
and ship KEYED by default so MeshAdv Mini (and any GPS-on-UART0 hat) boots
without a manual dd. Until then, flash KEYED on Mini boards after first boot.
