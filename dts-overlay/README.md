# Lyra Zero W → Raspberry Pi header pinmux (LoRa HAT compatibility)

## Three overlays — mutually exclusive

The gold image ships **three** `.dtbo` overlays for the 40-pin header. Loading
more than one at once is undefined (shared SPI data lines + conflicting control
directions). Switch with `/usr/local/sbin/lyra-hat-pinmux` (first-boot wizard
and `reticulum-mesh-ctl` start also call it). It edits
`/boot/armbianEnv.txt` `user_overlays=`; pinmux takes effect on the **next boot**
(script does not reboot).

| Overlay | HAT | CS | RESET | IRQ/BUSY | other |
|---|---|---|---|---|---|
| `lyra-zero-w-pi-header` (**default**) | MeshAdv Pi Hat v1.1 | pin **40** (RM_IO18) | pin **12** | 36 / 38 | PPS **in** pin16 |
| `lyra-zero-w-meshadv-mini` | MeshAdv Mini | pin **24** (RM_IO10) | pin **18** | 36 / 38 | RXEN out pin32; PPS **in** pin11 |
| `lyra-zero-w-station-g3` | BQ / Uniteng Station G3 | pin40 HW path† | board-specific | 36 / 38 | pin **16** = RXEN **OUT** |

† Station G3 userspace may bit-bang CS on pin24; the G3 DTBO still uses the
Pi-header SPI CS pinmux on pin40 for `/dev/spidev0.0` registration — see
`lyra-zero-w-station-g3.dts` comments.

Detection order for desired profile: explicit `lyra-hat-pinmux apply …` →
`/etc/lyra-hardware.conf` → `radio_board=` in `~/.reticulum/config` →
Meshtastic yaml if present → default **meshadv** (pi-header).

**MeshAdv Mini critical rule:** physical pin **12 is Fan PWM**. Never load
`lyra-zero-w-pi-header` with a Mini attached (that overlay drives pin12 as
RESET). Mini RESET is pin **18** only.

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
| I2C SDA/SCL | 2/3 | 3/5 | RM_IO0/1 | i2c0 |

Userspace board profile: `radio_board = meshadv-mini` via
`~/.reticulum/interfaces/sx126x_boards` (installer-shipped). With the Mini
overlay, keep `pin_cs = -1` so spidev owns HW CS on RM_IO10 (same pattern as
Pi Hat gold config with CS on pin40).

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

## Live verification lessons (apply to all three overlays)

Confirmed working on hardware for `lyra-zero-w-pi-header` (2026-08-03):

1. **`cs-gpios` is required** even when CS is also pinmux'd to hardware CSN0 —
   without it `spi_master` never registers (silent; no dmesg). Same fix on Mini
   with `cs-gpios = <&gpio0 0x0a 0x01>` (pin24 / RM_IO10).
2. **Pin groups nested** inside an intermediate named subnode under `&pinctrl`
   (e.g. `lora_mini { … }`), not flat children of pinctrl.
3. **One pin per node** — multi-tuple `rockchip,pins` fails with
   `unable to find group for node`.
4. Child compatible **`rockchip,spidev`** (vendor kernel), not generic `spidev`.

SPI0 (`ff120000`) is distinct from boot flash `fspi@ff488000` — safe to claim.

## Deploy / switch on a live board

```bash
# compile (host or board)
dtc -@ -I dts -O dtb -o lyra-zero-w-meshadv-mini.dtbo lyra-zero-w-meshadv-mini.dts
sudo cp lyra-zero-w-meshadv-mini.dtbo /boot/overlay-user/

# switch profile (does not reboot)
sudo lyra-hat-pinmux apply meshadv-mini   # or meshadv | station-g3
sudo lyra-hat-pinmux status
sudo reboot

# after reboot
ls -l /dev/spidev0.0 /dev/i2c-0
lyra-hat-pinmux status
# Mini expected CS gpio: gpiochip0 line 10; RESET line 12; IRQ gpiochip1 line 25
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
| **24** | **10 (SPI CS0)** | 26 | 9 |
| 27 / 28 | 24 / 31 | 29 / 31 | 25 / 26 |
| 32 / 33 | 30 / 27 | 35 / 36 | 16 / 29 |
| 37 / 38 | 28 / 17 | 40 | 18 (alt SPI CS0) |

SPI CSN0 mux value **0x55** on whichever RM_IO is chosen (pin24 → offset 0x0a,
pin40 → offset 0x12).

## Background

- RK3506B pinmux: primary IOMUX (`rockchip,pins`) + RMIO matrix. Header pins
  default GPIO/disabled until routed.
- Armbian: `overlay_prefix=rockchip`; custom overlays in `/boot/overlay-user/`
  via `user_overlays=` in `/boot/armbianEnv.txt`.
