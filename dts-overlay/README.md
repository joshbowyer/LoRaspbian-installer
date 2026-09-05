# Lyra Zero W → Raspberry Pi header pinmux (LoRa HAT compatibility)

## HAT overlays — mutually exclusive

The gold image ships **four** HAT `.dtbo` overlays for the 40-pin header.
Loading more than one HAT overlay at once is undefined (shared SPI data lines +
conflicting control directions). Switch with `/usr/local/sbin/lyra-hat-pinmux`
(first-boot wizard and `reticulum-mesh-ctl` start also call it). It edits
`/boot/armbianEnv.txt` `user_overlays=`; pinmux takes effect on the **next boot**
(script does not reboot — the wizard offers reboot after HAT selection).

| Overlay | HAT / profile | CS | RESET | IRQ/BUSY | other |
|---|---|---|---|---|---|
| `lyra-zero-w-pi-header` (**default**) | MeshAdv Pi Hat v1.1 / `meshadv` | pin **40** (RM_IO18) | pin **12** | 36 / 38 | PPS **in** pin16 |
| `lyra-zero-w-meshadv-mini` | MeshAdv Mini LoRa-only / `meshadv-mini` (**wizard default for Mini**) | pin **24** (RM_IO10) | pin **18** | 36 / 38 | RXEN pin32; PPS pin11; GPS EN **LOW**; FIQ console kept |
| `lyra-zero-w-meshadv-mini-gps` | MeshAdv Mini + GPS / `meshadv-mini-gps` (**EXPERIMENTAL**) | pin **24** | pin **18** | 36 / 38 | GPS EN **HIGH**; **UART0** 8/10; **fiq-debugger off** |
| `lyra-zero-w-station-g3` | BQ / Uniteng Station G3 / `station-g3` | pin40 HW path† | board-specific | 36 / 38 | pin **16** = RXEN **OUT** |

Optional stackable diagnostic (not a HAT profile):

| Overlay | Purpose |
|---|---|
| `lyra-diag-fiq-off` | Disable `&fiq_debugger` only — GPS bring-up A/B test |

† Station G3 userspace may bit-bang CS on pin24; the G3 DTBO still uses the
Pi-header SPI CS pinmux on pin40 for `/dev/spidev0.0` registration — see
`lyra-zero-w-station-g3.dts` comments.

Detection order for desired profile: explicit `lyra-hat-pinmux apply …` →
`/etc/lyra-hardware.conf` (`hat=` + optional `gps=`) → `radio_board=` in
`~/.reticulum/config` → Meshtastic yaml if present → default **meshadv**
(pi-header).

- `hat=meshadv-mini` + `gps=off` (or missing) → **meshadv-mini** (LoRa-only)
- `hat=meshadv-mini` + `gps=on` → **meshadv-mini-gps** (experimental)
- `meshadv-mini-lora` is an alias for `meshadv-mini`

**MeshAdv Mini critical rule:** physical pin **12 is Fan PWM**. Never load
`lyra-zero-w-pi-header` with a Mini attached (that overlay drives pin12 as
RESET). Mini RESET is pin **18** only.

## MeshAdv Mini (wizard path = LoRa-only)

First-boot wizard HAT choice **MeshAdv Mini** writes:

```
hat=meshadv-mini
gps=off
```

then `lyra-hat-pinmux apply meshadv-mini` →
`user_overlays=lyra-zero-w-meshadv-mini` (GPS EN low, FIQ console kept).

### Onboard GPS — deferred until mainline

**Do not enable the GPS overlay on the current vendor kernel.** It brick-hangs.

Root cause (confirmed 2026-09-05 on lyra2, vendor 6.1.115):

- Rockchip **fiq-debugger** owns UART0 (`rockchip,serial-id = <0>`, 1.5Mbaud)
  → real console is `/dev/ttyFIQ0` (`console=ttyS2` is a dead letter).
- Enabling `&uart0` alone dual-claims UART0 → solid-red hang (even hatless).
- Disabling `&fiq_debugger` alone → same hang.
- Combined fiq-off + uart0 + GPS EN high → same hang.

`lyra-zero-w-meshadv-mini-gps.dts` and `lyra-diag-fiq-off.dts` are kept in-tree
as historical reference only. They are **not** a supported path on vendor
kernel.

**Plan:** onboard ATGM336H GPS (pins 7 EN, 8/10 UART, 11 PPS) lands when
LoRaspbian switches this board to **mainline Linux** after RK3506 device-tree
and related patches are fully merged upstream (normal dw-apb UART, no FIQ
debugger on UART0). Until then: **LoRa-only Mini** (this overlay) + optional
USB GPS. KEYED U-Boot (stop string `uboot`) is still required for Mini HAT
boot because GPS TX can noise pin10 even with EN low — see `u-boot/README.md`.

### LoRa-only recovery (safe default)

```bash
sudo lyra-hat-pinmux apply meshadv-mini   # or meshadv-mini-lora alias
# ensure gps=off in /etc/lyra-hardware.conf
sudo reboot
```

`CONFIG_OF_OVERLAY` is **unset** on vendor 6.1.115 — no live `dtoverlay`;
profile switches are always next-boot. SD recovery if hung: mount root,
set `user_overlays=lyra-zero-w-meshadv-mini`, `gps=off`.

## MeshAdv Mini pinout (confirmed)

Source: [chrismyers2000/MeshAdv-Mini](https://github.com/chrismyers2000/MeshAdv-Mini)
yaml (CS:8 IRQ:16 Busy:20 Reset:24 RXen:12) + Luckfox Zero W pinout
(phys 24 = GPIO0_B2 = **RM_IO10**) + official
`rockchip-luckfox-lyra-zero-w-spi0-2cs-spidev` (SPI0 CS0 on RM_IO10).

| Function | BCM | Phys | Lyra RM_IO | gpio line |
|---|---|---|---|---|
| MOSI / MISO / SCLK | 10/9/11 | 19/21/23 | RM_IO6/7/8 | g0.6/7/8 |
| NSS/CS | **8** | **24** | **RM_IO10** | **g0.10** |
| IRQ / DIO1 | 16 | 36 | RM_IO29 | g1.25 |
| BUSY | 20 | 38 | RM_IO17 | g0.17 |
| RESET | **24** | **18** | **RM_IO12** | **g0.12** |
| RXEN | 12 | 32 | RM_IO30 | g1.26 |
| GPS PPS | 17 | 11 | RM_IO3 | g0.3 |
| GPS EN | 4 | **7** | RM_IO2 | g0.2 (hog low=LoRa-only / high=GPS) |
| GPS UART | 14/15 | **8/10** | RM_IO22/23 | uart0 (GPS overlay only) |
| I2C SDA/SCL | 2/3 | 3/5 | RM_IO0/1 | i2c0 |

Userspace board profile: `radio_board = meshadv-mini` via
`~/.reticulum/interfaces/sx126x_boards` (installer-shipped). With the Mini
overlay, keep `pin_cs = -1` so spidev owns HW CS on RM_IO10 (same pattern as
Pi Hat gold config with CS on pin40).

**Boot-safe defaults (required):** RESET/RXEN/IRQ/BUSY/PPS pin groups are on
`spi0` `pinctrl-0` (not a dummy root node — placeholders never bind, so those
muxes stayed UNCLAIMED). LoRa-only keeps GPS EN **output-low**.

**RX LED solid red** while mesh is up is expected: Mini RX silk tracks **RXEN**
(continuous RX path), not packet IRQ.

## MeshAdv Pi Hat v1.1 pinout (default overlay)

| Function | BCM | Phys | Lyra RM_IO |
|---|---|---|---|
| MOSI / MISO / SCLK | 10/9/11 | 19/21/23 | RM_IO6/7/8 |
| NSS/CS | 21 | **40** | RM_IO18 |
| IRQ / BUSY | 16 / 20 | 36 / 38 | RM_IO29 / 17 |
| RESET | 18 | **12** | RM_IO14 |
| PPS (optional GPS stack) | — | **16** | RM_IO13 (input) |

## Goal

Make the Lyra Zero W 40-pin header match Raspberry Pi Zero 2W SPI0 + HAT
control lines so SX126x LoRa HATs plug in without rewiring. Almost all header
pins are unassigned RMIO until an overlay pinmuxes them.

## Live verification lessons (apply to all overlays)

Confirmed working on hardware for `lyra-zero-w-pi-header` (2026-08-03) and
Mini LoRa + KEYED U-Boot + SX126x e2e (2026-09-05 lyra2):

1. **`cs-gpios` is required** even when CS is also pinmux'd to hardware CSN0 —
   without it `spi_master` never registers (silent; no dmesg). Same fix on Mini
   with `cs-gpios = <&gpio0 0x0a 0x01>` (pin24 / RM_IO10).
2. **Pin groups nested** inside an intermediate named subnode under `&pinctrl`
   (e.g. `lora_mini { … }`), not flat children of pinctrl.
3. **One pin per node** — multi-tuple `rockchip,pins` fails with
   `unable to find group for node`.
4. Child compatible **`rockchip,spidev`** (vendor kernel), not generic `spidev`.
5. **Never enable `&uart0` without disabling `&fiq_debugger`** on this board —
   and even with both, GPS path still hung once (see experimental note).
6. **sx126x_platforms** `header_pin_to_line` must be a **single-quoted JSON
   string** with full `/dev/gpiochipN` paths (ConfigObj + libgpiod 2.x).

SPI0 (`ff120000`) is distinct from boot flash `fspi@ff488000` — safe to claim.

## Deploy / switch on a live board

```bash
# compile (host or board)
dtc -@ -I dts -O dtb -o lyra-zero-w-meshadv-mini.dtbo lyra-zero-w-meshadv-mini.dts
dtc -@ -I dts -O dtb -o lyra-diag-fiq-off.dtbo lyra-diag-fiq-off.dts
sudo cp *.dtbo /boot/overlay-user/
sudo cp lyra-hat-pinmux /usr/local/sbin/lyra-hat-pinmux && sudo chmod 755 /usr/local/sbin/lyra-hat-pinmux

# wizard default: Mini LoRa-only
sudo lyra-hat-pinmux apply meshadv-mini
sudo lyra-hat-pinmux status
sudo reboot

# Test A (fiq off only — stack diagnostic; manual armbianEnv)
# user_overlays=lyra-zero-w-meshadv-mini lyra-diag-fiq-off
# expect: boot OK, no /dev/ttyFIQ0, uart0 still disabled, LoRa still Up

# GPS opt-in ONLY after A/B pass (experimental)
sudo lyra-hat-pinmux apply meshadv-mini-gps && sudo reboot
```

`/boot` is not a separate partition on this image (single ext4 root).

## Full header RM_IO map (Luckfox Zero W interactive pinout)

Verified against known working pi-header pins + diagram row layout:

| Pin | RM_IO | Pin | RM_IO |
|---|---|---|---|
| 3 / 5 | 0 / 1 (I2C) | 7 | 2 |
| 8 / 10 | 22 / 23 (UART0) | 11 | 3 |
| 12 | 14 | 13 | 4 |
| 15 | 5 | 16 | 13 |
| 18 | 12 | 19 / 21 / 23 | 6 / 7 / 8 (SPI) |
| 22 | 11 | **24** | **10** (SPI CS0) |
| 26 | 9 | 27 / 28 | 24 / 31 |
| 29 / 31 | 25 / 26 | 32 / 33 | 30 / 27 |
| 35 / 36 | 16 / 29 | 37 / 38 | 28 / 17 |
| 40 | 18 (Pi Hat CS) | | |
