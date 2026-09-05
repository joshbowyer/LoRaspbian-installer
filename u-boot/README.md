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

**Shipped binary:** `files/u-boot-rockchip-keyed.bin` (git-tracked, ~8.7 MiB).

| Field | Value |
|---|---|
| SHA256 | `0016e6a9c2f68b5e68983950e2907e54999438b3850eaaa9a4cd68a40a4f1ff9` |
| Release asset | `u-boot-rockchip-keyed-2026.07.bin` on [v1.1.0](https://github.com/joshbowyer/LoRaspbian-installer/releases/tag/v1.1.0) |
| Localversion | `2026.07-loraspbian-keyed` |

```bash
# sketch — see HANDOFF § KEYED U-Boot for full env
export CROSS_COMPILE=arm-linux-gnueabihf-
export ARCH=arm
make luckfox-lyra-zero-w-rk3506b_defconfig
# merge autoboot-keyed.fragment into .config
make -j$(nproc) DTC=$(which dtc) \
  ROCKCHIP_TPL=.../rk3506b_ddr_750MHz_v1.06.bin \
  TEE=.../rk3506_tee_v2.10.bin
# → u-boot-rockchip.bin  (copy to files/u-boot-rockchip-keyed.bin + update SHA)
```

## Gold image bake (mandatory)

`build-lyra-gold-image.sh` **always** writes KEYED into the image
(`dd bs=32k seek=1`). Resolve order:

1. `LYRA_KEYED_UBOOT=/path/to.bin` (override)
2. `files/u-boot-rockchip-keyed.bin` (repo default)
3. Download from GitHub release asset + SHA256 verify
4. **Exit 1** if missing or hash mismatch — never silently keep stock U-Boot

WiFi bake is independent (`LYRA_WIFI_SSID` / `LYRA_WIFI_PSK`).

## Install / repair on a live board or already-flashed SD

**Same recipe as** `/usr/lib/u-boot/platform_install.sh`. Use this to fix a
self-built card that was made before KEYED became mandatory (solid red with
Mini HAT seated):

```bash
# On host, with SD as /dev/sdX (NOT partition):
sudo dd if=files/u-boot-rockchip-keyed.bin of=/dev/sdX bs=32k seek=1 conv=notrunc
sudo sync

# Or on a live board that still boots hatless:
# BACK UP first 16MiB of MMC, then:
sudo dd if=u-boot-rockchip-keyed.bin of=/dev/mmcblk0 bs=32k seek=1 conv=notrunc
sudo sync && sudo reboot
```

Restore stock from backup:

```bash
sudo dd if=uboot-backup-pre-keyed-16M.bin of=/dev/mmcblk0 bs=1M count=16 conv=notrunc
```

## Serial rescue

- Baud: **1500000** (U-Boot/SPL); Linux later **115200** on `ttyS2` (often
  disabled in DT — prefer SSH / FIQ console).
- To enter U-Boot prompt: type **`uboot`** during the countdown (not any key).
