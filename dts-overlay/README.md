# Lyra Zero W → Raspberry Pi Zero 2W header pinmux (LoRa HAT compatibility)

## Two overlays - mutually exclusive

The gold image ships TWO `.dtbo` overlays for the 40-pin header because
physical pin 16 (RM_IO13 / GPIO0_B5) serves opposite roles on the two
supported HATs:

| Overlay | HAT | Pin 16 role |
|---|---|---|
| `lyra-zero-w-pi-header` | MeshAdv Pi HAT v1.1 (+ optional GPS PPS) | **INPUT** (GPS PPS) |
| `lyra-zero-w-station-g3` | BQ / Uniteng Station G3 | **OUTPUT** (RXEN/LNA_EN, active-low, default HIGH) |

Loading both at once on the same pin (same bank/offset, opposite
directions) is undefined. The active overlay is selected by
`/usr/local/sbin/lyra-hat-pinmux` — called by the first-boot wizard AND
by `reticulum-mesh-ctl` start, which detect the desired HAT from
`/etc/lyra-hardware.conf`, `/home/lyra/.reticulum/config`'s
`radio_board = …` line, and (if present) the Meshtastic config. Switching
edits `/boot/armbianEnv.txt`'s `user_overlays=` line; the actual pinmux
change takes effect at the next boot — `lyra-hat-pinmux` does NOT reboot
automatically.

Out of the box the MeshAdv overlay is the default — pin16 left as an
input is safe on an unpopulated header, and any properly-installed GPS
HAT that drives a PPS pulse on pin16 will work.

## Goal

Make the Lyra Zero W's 40-pin header electrically/logically match the
Raspberry Pi Zero 2W's SPI0 + control lines, so an existing "meshadv"-style
SX126x LoRa HAT (built for a Pi) can be plugged straight into the Lyra
without rewiring.

## Why this isn't done yet

Almost all of the Lyra's 40-pin header is unassigned **RMIO** (Rockchip
Matrix I/O) out of the box — nothing is pinmuxed to SPI/GPIO by default. Doing
this correctly requires:

1. The RK3506B's actual bank/pin numbers for the *specific physical header
   pins* we care about (19, 21, 23, 40, 36, 38, 12 — see mapping below).
2. Those numbers come from Luckfox's own devicetree source
   (`rk3506b-luckfox-lyra-zero-w(-sd).dts` / `rk3506-luckfox-lyra-ultra.dtsi`,
   from the Luckfox SDK or Armbian's `linux-rockchip` repo) or from reading
   the live board's compiled device tree — **not** something to guess at.

Fabricating plausible-looking bank/pin numbers would produce a devicetree
overlay that either silently does nothing or (worse) mis-muxes an unrelated
pin. So this directory contains a documented template + a helper script to
extract the real numbers next time the board is available, rather than a
finished overlay.

## Target pinout (confirmed, from meshadv-style SX126x Pi HATs)

Standard Pi Zero 2W physical header, BCM numbering:

| Function | BCM GPIO | Physical pin |
|---|---|---|
| MOSI | 10 | 19 |
| MISO | 9  | 21 |
| SCLK | 11 | 23 |
| NSS/CS | 21 | 40 |
| IRQ / DIO1 | 16 | 36 |
| BUSY | 20 | 38 |
| RESET | 18 | 12 |
| TXEN (optional) | 13 | 33 |
| RXEN (optional) | 12 | 32 |

3.3V: pins 1, 17. GND: 6, 9, 14, 20, 25, 30, 34, 39 (already aligned
mechanically — no pinmux needed for power/ground).

## CONFIRMED WORKING on live hardware (2026-08-03)

`lyra-zero-w-pi-header.dts` (renamed from `lyra-zero-w-pi-spi0-lora.dts` once
scope grew beyond just SPI0/LoRa) has been compiled, applied, and verified
on the actual Lyra board (lyra-node / 10.0.0.200):
- `/dev/spidev0.0` exists
- `spi0` appears in `/sys/class/spi_master/`
- `/dev/i2c-0` exists, `i2cdetect -y 0` scans cleanly (physical pins 3/5,
  matching the Pi's user-facing I2C1 position - for RTC/power-monitor HATs
  like an INA3221; no device wired yet so the scan is empty, which is
  expected)
- Zero dmesg errors/warnings for either bus

Three real bugs were found and fixed by testing live, none of which were
obvious from the devicetree docs alone:
1. **`cs-gpios` is required** even though the CS pin is also pinmux'd to the
   hardware CSN0 function - confirmed via josh's known-working femtofox
   (rv1103, same `rockchip,rk3066-spi`-family driver) reference config at
   github.com/joshbowyer/femtofox. Without it the `spi_master` never
   registers, with **zero dmesg output at all** (not even an error).
2. **Pin groups must be nested inside an intermediate named subnode**
   (e.g. `lora_pi { lora-pi-spi0-mosi {...}; }`), not declared directly as
   children of `&pinctrl`. Matches this board's own base tree pattern
   (`rm_io6 { rm-io6-spi0-mosi {...}; }`) and femtofox's
   (`spi0 { spi0m0_clk {...}; }`). Flat top-level nodes fail with
   `rockchip-pinctrl pinctrl: unable to find group for node <name>` in dmesg.
3. **One pin per node** - a single node with a comma-separated multi-tuple
   `rockchip,pins` list also fails with the same "unable to find group"
   error. Each signal (MOSI/MISO/CLK/CSN0/IRQ/BUSY/RESET) needs its own
   named subnode, referenced individually in `pinctrl-0`.

Child device `compatible` was also changed from generic `"spidev"` to
`"rockchip,spidev"` to match the vendor kernel's driver, per the same
femtofox reference.

Deployment note: no `armbian-add-overlay` tool on this image - manual steps
used instead: compile with `dtc -@ -I dts -O dtb`, copy `.dtbo` to
`/boot/overlay-user/`, add `user_overlays=lyra-zero-w-pi-spi0-lora` to
`/boot/armbianEnv.txt` (backed up as `.bak`), reboot. `/boot` is not a
separate partition on this image (single ext4 root), so the overlay prefix
resolves to `/boot/` directly.

**Still needed**: wire up the actual LoRa HAT and confirm
`reticulum-hat-mod`'s `SX126xInterface.py` can talk to it over
`/dev/spidev0.0` plus the IRQ/BUSY/RESET GPIO lines (gpiochip0 line 17/14,
gpiochip1 line 25) before adding `[[SX126xInterface]]` to
`reticulum-config-base` and baking this overlay into the main
`build-lyra-gold-image.sh`.

## Update: real overlay written, needs live test

`lyra-zero-w-pi-spi0-lora.dts` is now filled in with real values (the
`.template` file is kept only for reference/process documentation). Values
came from: live SSH dump of `/proc/device-tree` on lyra-node (10.0.0.200) via
`dump-lyra-pinctrl.sh`, cross-referenced against josh's own RMIO/pinctrl
mapping table for this board and the official Luckfox pinout image.

Confirmed via the live device tree that every RM_IO pin can be routed to any
SPI0 signal (mosi/miso/clk/csn0/csn1) - not just a fixed subset - so all four
SPI0 signals land exactly on the physical pins that match the Pi's SPI0
layout (19/21/23/40). IRQ/BUSY/RESET (pins 36/38/12) just use plain GPIO
mux, no RMIO routing needed. Full derivation and exact `rockchip,pins`
values are documented in comments at the top of the `.dts` file.

**Still needs, before trusting this for the gold image:**
1. Compile + apply on the live board and confirm no boot regressions.
2. Verify with `gpioinfo` that gpiochip0 line 17/14 and gpiochip1 line 25
   show up correctly, and `/dev/spidev0.0` appears.
3. Wire up the actual LoRa HAT and confirm `reticulum-hat-mod`'s
   `SX126xInterface.py` can talk to it.
4. Confirm repurposing `spi0` (`ff120000`) doesn't conflict with anything
   else on the board - it's a general-purpose SPI controller distinct from
   the boot flash controller (`fspi@ff488000`), so this should be safe, but
   worth a sanity check given hands-on board knowledge.

## Steps once confirmed working

1. Compile/apply via Armbian's overlay tooling:
   ```bash
   sudo armbian-add-overlay lyra-zero-w-pi-spi0-lora.dts
   # or manually:
   dtc -@ -I dts -O dtb -o lyra-zero-w-pi-spi0-lora.dtbo lyra-zero-w-pi-spi0-lora.dts
   sudo cp lyra-zero-w-pi-spi0-lora.dtbo /boot/overlay-user/
   # add to user_overlays= in /boot/armbianEnv.txt, then reboot
   ```
6. Verify with `gpioinfo` / `ls /dev/spidev*` after reboot, then plug in the
   HAT and confirm `reticulum-hat-mod`'s `SX126xInterface.py` can talk to it
   (already deployed to `/home/lyra/.reticulum/interfaces/` by the main
   build script).
7. Once confirmed working, add the `[[SX126xInterface]]` block to
   `files/reticulum-config-base` and this whole overlay into the main build
   script (copy the compiled `.dtbo` into the chroot's
   `/boot/overlay-user/` and append to its `armbianEnv.txt` `user_overlays=`
   line, so it's baked into every gold image going forward).

## Background (why RMIO, what dtoverlay mechanism)

- RK3506B pinmux is two-layer: primary IOMUX (GRF/PMU registers, standard
  `rockchip,pins` devicetree property) plus a secondary RMIO routing matrix
  that maps internal peripheral signals onto physical pins
  (`rockchip,rmio-pins = <rmio_id pin_id func_id>`). Most header pins default
  to GPIO-only/disabled until explicitly routed through RMIO to a peripheral
  function (e.g. SPI0_MOSI).
- Armbian uses `overlay_prefix=rockchip` (see `/boot/armbianEnv.txt`):
  built-in overlays live in `/boot/dtb/rockchip/overlay/`, custom ones go in
  `/boot/overlay-user/` referenced via `user_overlays=` in `armbianEnv.txt`.
  `armbian-add-overlay <file.dts>` handles compiling + installing + updating
  the env file for you.
