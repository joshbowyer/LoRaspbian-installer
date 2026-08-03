# LoRaspbian Installer

Builds a ready-to-flash SD card image for off-grid [Reticulum](https://reticulum.network/)
mesh nodes on the **Luckfox Lyra Zero W** (RK3506B), with the board's 40-pin
header remapped to match the Raspberry Pi's SPI0 + LoRa-HAT control-line
layout - so an existing "meshadv"-style SX126x LoRa HAT built for a Pi plugs
in and works, unmodified.

The name is a nod to Raspbian - the goal is the same "flash it, boot it, it
just works" experience, for a LoRa + Reticulum mesh node instead of a general
desktop.

## What this produces

A single `lyra-gold.img` you `dd` to an SD card. On first boot the board:
- joins WiFi (either baked in at build time, or via an on-device setup wizard)
- runs NomadNet + Reticulum over LoRa (via the remapped SPI0 + meshadv HAT
  pinout) and TCP (LAN)
- generates a fresh identity per card (no two flashed cards share a hash)
- optionally runs Meshtastic instead (installed but disabled by default -
  chosen via the first-boot wizard)

## Quick start

```bash
sudo apt-get install -y wget xz-utils util-linux qemu-user-static e2fsprogs device-tree-compiler
sudo ./build-lyra-gold-image.sh
# or, non-interactively:
LYRA_WIFI_SSID="YourNetwork" LYRA_WIFI_PSK="YourPassword" sudo -E ./build-lyra-gold-image.sh
```

Output: `out/lyra-gold.img`. Flash with:
```bash
sudo dd if=out/lyra-gold.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## How it works

`build-lyra-gold-image.sh` runs on your Linux dev machine (not on the
board): downloads the stock Armbian image, loop-mounts + chroots into it
(via `qemu-arm-static`), installs and configures everything, then repacks it
into a flashable image. This keeps the whole build reproducible from a clean
base image every time, instead of hand-configuring a live board over SSH.

## Hardware status

| Component | Status |
|---|---|
| WiFi (aic8800 chip, rfkill soft-block, netplan) | Hardware-verified, working |
| SPI0 remapped to the Pi's header pinout | **Hardware-verified live on the board** - `/dev/spidev0.0` confirmed working |
| IRQ/BUSY/RESET GPIO lines | Hardware-verified (pinmux confirmed correct) |
| End-to-end LoRa radio through a HAT | **Not yet tested** - written in anticipation of a HAT design in progress, not yet physically tested with a radio attached |
| rngit / RRC chat | Known Rust/cbor2 build issue under emulation - has a workaround (piwheels), not fully hardened |

See `dts-overlay/README.md` for the full pinmux derivation, including the
real bugs found by testing live on hardware (not just theory) - `cs-gpios`
requirements, devicetree node-nesting quirks, etc. - useful context if
something doesn't work on a different Lyra revision or a different HAT.

## Repo layout

```
build-lyra-gold-image.sh   # the main build script (run this)
files/                     # payloads copied into the image during build
  reticulum-config-base    # base RNS config, includes the SX126x LoRa interface
  sx126x_platforms         # GPIO/SPI pin mapping for this board (driver profile overlay)
  first-boot-wizard.sh     # on-device first-boot setup (WiFi fallback, mode/board select)
  *.service                # systemd units for nomadnet/rngit/first-boot
dts-overlay/                # devicetree overlay remapping the 40-pin header
  lyra-zero-w-pi-spi0-lora.dts   # the overlay itself (compiled + applied by the build script)
  README.md                      # full derivation + hardware-tested gotchas
  dump-lyra-pinctrl.sh           # helper to inspect a board's live pinctrl state
```

## Known gaps / next steps

- LoRa radio behavior through an actual HAT hasn't been tested (pinmux/SPI
  bus is verified independent of any specific radio module).
- `lyra:lyra` is the default login - the first-boot wizard prompts to change
  it, but it's not force-changed.
- rngit install can still fail under qemu emulation in some environments;
  the piwheels workaround in the build script handles the common case.
