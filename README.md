# LoRaspbian Installer

Builds a ready-to-flash SD card image for off-grid LoRa mesh nodes on the
**Luckfox Lyra Zero W** (RK3506B), running either
[Reticulum](https://reticulum.network/) (NomadNet + RNS) **or**
[Meshtastic](https://meshtastic.org/) - chosen at first boot, mutually
exclusive. The board's 40-pin header is remapped to match the Raspberry
Pi's SPI0 + LoRa-HAT control-line layout, so an existing "meshadv"-style
SX126x LoRa HAT built for a Pi plugs in and works, unmodified, under either
mesh stack.

The name is a nod to Raspbian - the goal is the same "flash it, boot it, it
just works" experience, for a LoRa mesh node (Reticulum or Meshtastic)
instead of a general desktop.

## What this produces

A single `lyra-gold.img` you `dd` to an SD card. On first boot the board:
- joins WiFi (either baked in at build time, or via an on-device setup wizard)
- prompts you to choose **Reticulum or Meshtastic** (mutually exclusive - both
  are installed on the image, only one runs at a time)
- if Reticulum: runs NomadNet + RNS over LoRa (via the remapped SPI0 +
  meshadv HAT pinout) and TCP (LAN), with a fresh identity per card (no two
  flashed cards share a hash)
- if Meshtastic: runs `meshtasticd` over the same remapped SPI0/LoRa pinout

## Quick start

### 0. First-time board: erase SPI NAND (required on new Lyra Zero W)

New Luckfox Lyra Zero W boards ship with firmware on the onboard **SPI NAND**.
That flash wins the boot order over the TF/SD card, so a freshly written
LoRaspbian image can hang after OP-TEE with no U-Boot/Linux on serial until
the SPI NAND is wiped empty. (A board that already boots SD-only — SPI NAND
all `0xFF` — can skip this.)

**Easiest path (Chrome + WebUSB, no SDK):**

1. **Remove the SD/TF card** before erasing. If a card is inserted, the
   flasher may erase the card instead of the onboard SPI NAND.
2. Hold **BOOT** for ~5 seconds while plugging USB-C into the computer
   (Loader / Maskrom mode).
3. Open in **Chrome**:
   [Rockchip WebUSB eraser](https://web-flasher-git-rockchip-webusb-erase-meshtastic.vercel.app)
4. Connect the device in the page, then use the **erase NAND flash** option
   at the bottom of the page.
5. Unplug, insert the flashed SD card, power up.

Credit: Meshtastic WebUSB Rockchip erase flasher (VID).

**Serial baud when debugging boot:** U-Boot/SPL often uses **1500000**; once
Linux/Armbian is up, console is **`ttyS2,115200n8`**.

**CLI fallback** (if you prefer not to use the browser tool): install
`rkdeveloptool` or Luckfox `upgrade_tool`, put the board in Loader mode the
same way, download an RK3506 `MiniLoaderAll.bin` from the Luckfox SDK, then
`ef` (erase flash) + `rd` (reset). See
[Luckfox Lyra image flashing](https://wiki.luckfox.com/Luckfox-Lyra/Getting-Started/Image-flashing).

### 1. Build the image

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

Then erase SPI NAND if needed (step 0), insert the card, and boot.

### Running the build under WSL

Not primarily tested there, but should mostly work on **WSL2** (not WSL1 -
WSL1 doesn't support loop devices/chroot at all). Two known gaps:

- **Loop devices can be flaky on some WSL2 kernels** - if `losetup` fails
  with "cannot find an unused loop device", try `sudo modprobe loop` or
  `wsl --update` for a current kernel.
- **Flashing needs a raw block device, which WSL2 doesn't pass through by
  default.** Easiest path: build the image in WSL, then copy
  `out/lyra-gold.img` to the Windows filesystem and flash it from Windows
  with Balena Etcher / Rufus / Win32DiskImager instead of the `dd` command
  above. (Or use `usbipd-win` to bind a USB SD reader into WSL2 if you want
  to `dd` from inside WSL.)

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
  lyra-zero-w-pi-header.dts      # the overlay itself (compiled + applied by the build script)
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
