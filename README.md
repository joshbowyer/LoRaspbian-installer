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

**MeshAdv Mini + LoRa (shipped):** pinmux CS24 / RST18 / RXEN32 is verified
end-to-end on hardware (SX126x Up, LXMF over LoRa). Mini GPS TX sits on header
pin 10 = Lyra UART0 RX (same pins vendor U-Boot uses as debug UART). Stock
unkeyed autoboot aborts to `=>` on any RX noise. **Every gold build bakes
KEYED U-Boot** (stop string `uboot`) — see [`u-boot/README.md`](u-boot/README.md).
If a self-built card hangs solid-red with the Mini HAT, the image was built
without KEYED; `dd` the keyed binary onto the SD (`bs=32k seek=1`) or rebuild.

**Onboard GPS (MeshAdv Mini ATGM336H): deferred until mainline.** Vendor
kernel 6.1.115 owns UART0 via Rockchip **fiq-debugger** (`/dev/ttyFIQ0`).
DT overlays that disable FIQ and/or enable `&uart0` brick-hang boot (solid
red LED). GPS support will land once we switch this board to **mainline
Linux** after RK3506 device-tree and related patches are fully merged
upstream. Until then: ship **LoRa-only** for Mini (GPS EN held low); use a
USB GPS if you need location now.

**I2C sensors (baked):** `/home/lyra/ina3221/` + timers for local MOTD and
LXMF telemetry. Optional hardware on I2C0 (pins 3/5):
- **INA3221** @ `0x40` — power rails (default labels `solar` / `bat` / `system`)
- **TMP102** @ `0x48` — MeshAdv Mini onboard hat temp (MOTD only)
- **BME280/BMP280** @ `0x76`/`0x77` — ambient temp/humidity/pressure → collector
  (BME temp supersedes TMP102 for LXMF). Absent chips are skipped.
- Cache timer (1 min) → `~/.cache/ina3221.json` → login MOTD Power/Env lines
- Beacon timer (10 min) → The Spot collector `da424e0f…` (edit
  `config.json` `display_name` / `collector` / channel labels after first boot)
- **Powerguard** timer (1 min, root): soft-stop `reticulum-mesh` when `bat` ≤
  `stop_v` (default **3.0 V**, 2 samples), restore when `bat` ≥ `restore_v`
  (default **3.4 V**). **No OS poweroff** — charge-board UVLO still cuts power;
  on reboot mesh comes back if voltage is healthy. Toggle via
  `config.json` → `powerguard.enabled`. Status: MOTD **Bat Guard** line or
  `sudo python3 ~/ina3221/ina3221-powerguard.py --status`
- Manual: `python3 ~/ina3221/read_ina3221.py`

**rnsh over LoRa:** character-mode PTY is painful at SF7 (~5.5 kbps). Upstream
already has line-interactive mode (`~` then `L` after newline). For a
**non-forking** default, apply the idempotent patch in
[`files/rnsh-line-mode/`](files/rnsh-line-mode/) on the **client** (initiator):

```bash
python3 files/rnsh-line-mode/apply-rnsh-line-mode.py
rnsh -L <dest>                 # or: export RNSH_LINE_MODE=1
# re-run after pip install -U rns (upgrades wipe site-packages patches)
```

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
| SPI0 remapped to the Pi's header pinout | **Hardware-verified** — `/dev/spidev0.0` working |
| MeshAdv **Pi Hat** v1.1 (CS40 RST12) | **Hardware-verified** — SX126x Up, mesh traffic |
| MeshAdv **Mini** LoRa (CS24 RST18 RXEN32) | **Hardware-verified** — KEYED U-Boot + SX126x Up + LXMF 1-hop LoRa |
| Station G3 pinmux overlay | Shipped; needs live HAT confirmation |
| MeshAdv Mini **onboard GPS** (UART0 / ATGM336H) | **Deferred** — blocked on vendor FIQ debugger; lands with **mainline** RK3506 once patches are fully merged |
| RX LED on Mini (D8 “LoRa RX”) | Hard-tied to **RXEN** (schematic) — solid red while continuous RX is expected, not packet blink |
| INA3221 @0x40 + TMP102 @0x48 + BME280 @0x77 | **Baked** — MOTD cache + LXMF beacon timers; verified on lyra3 solar |
| rngit / RRC chat | Known Rust/cbor2 build issue under emulation — piwheels workaround |

See `dts-overlay/README.md` for pinmux derivation and live-hardware gotchas
(`cs-gpios`, ConfigObj JSON for `sx126x_platforms`, Mini vs Pi Hat CS/RST).

## Repo layout

```
build-lyra-gold-image.sh   # the main build script (run this)
files/                     # payloads copied into the image during build
  reticulum-config-base    # base RNS config, includes the SX126x LoRa interface
  sx126x_platforms         # GPIO/SPI pin map (quoted JSON + /dev/gpiochip paths)
  sx126x_boards            # MeshAdv Mini board profile (cs24 …)
  first-boot-wizard.sh     # WiFi / Reticulum|Meshtastic / HAT select
  lyra-hat-pinmux          # apply one HAT overlay to armbianEnv.txt
  ina3221/                 # power + env sensors (MOTD + LXMF beacon)
  *.service                # nomadnet/rngit/rrcd/rnsh/telemetry/retibbs/mesh
dts-overlay/               # HAT pinmux overlays (mutually exclusive)
  lyra-zero-w-pi-header.dts           # MeshAdv Pi Hat v1.1 (default)
  lyra-zero-w-meshadv-mini.dts        # MeshAdv Mini LoRa-only (shipped)
  lyra-zero-w-meshadv-mini-gps.dts    # experimental only — do not use on vendor kernel
  lyra-zero-w-station-g3.dts
  README.md
u-boot/                    # KEYED autoboot fragment + flash notes (Mini)
```

## Known gaps / next steps

- **Onboard Mini GPS** waits on mainline RK3506 (no FIQ dual-claim). See
  Hardware status above. USB GPS works today if needed.
- KEYED U-Boot is **mandatory** in gold builds (`files/u-boot-rockchip-keyed.bin`
  is git-tracked; missing → download from release + SHA verify → else exit).
  Override with `LYRA_KEYED_UBOOT=`. See `u-boot/README.md`.
- `lyra:lyra` is the default login — wizard prompts to change it, not forced.
- rngit install can still fail under qemu emulation; piwheels handles the
  common case.
