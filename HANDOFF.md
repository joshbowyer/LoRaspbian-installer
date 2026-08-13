# LoRaspbian Installer — Project Handoff

Complete state dump for picking this project up in a fresh session. Written
2026-08-03. Repo: https://github.com/joshbowyer/LoRaspbian-installer

## 1. What this project is

A build system that produces a flashable SD card image (`lyra-gold.img`) for
the **Luckfox Lyra Zero W** (RK3506B SoC), turning it into an off-grid LoRa
mesh node running either **Reticulum** (NomadNet + RNS) or **Meshtastic**
(mutually exclusive, chosen at first boot). The board's 40-pin header is
remapped via a devicetree overlay to match the **Raspberry Pi family**
pinout (SPI0 + meshadv-HAT control lines + I2C1 position), so an existing
Pi-designed LoRa HAT — and the RTC/power-monitor HATs commonly paired with
it — plugs in and works unmodified. The project name is a nod to Raspbian:
same "flash it, boot it, it just works" goal.

### First-time hardware: SPI NAND must be empty for SD boot

New Lyra Zero W units often have factory (or prior) firmware on **SPI NAND**,
which takes boot priority over TF/SD. Symptom: serial stops after OP-TEE
"switching to normal world boot" with no U-Boot banner. Working SD-only
boards have SPI NAND wiped to `0xFF`.

**Documented easy path (see README Quick start §0):** remove SD card, hold
BOOT ~5s while plugging USB-C, open Chrome WebUSB eraser
https://web-flasher-git-rockchip-webusb-erase-meshtastic.vercel.app ,
connect device, erase NAND flash at bottom of page. (If SD is inserted it
may erase the card instead.) Serial: U-Boot often 1500000; Linux
`ttyS2,115200n8`.

**Origin story**: this grew out of an earlier, much longer Reticulum
off-grid networking project (in a separate repo, `/home/josh/Reticulum`,
with internal docs at `docs/00` through `docs/15`). The Lyra gold-image work
specifically had two prior sessions die/hang mid-build — root-caused and
fixed (see §7). This repo is the clean, standalone extraction of just the
gold-image build system, meant to be handed to a collaborator
(**NomDeTom**, who is designing a Pi-compatible LoRa HAT specifically
targeting this pinout) so they can build/flash/test independently.

## 2. Repo layout

```
build-lyra-gold-image.sh   # main build script - run this, on a Linux host (or WSL2, see README)
files/
  reticulum-config-base    # base RNS config incl. [[MeshAdv LoRa]] SX126x interface block
  sx126x_platforms         # GPIO/SPI pin-mapping overlay for reticulum-hat-mod's driver
  first-boot-wizard.sh     # on-device first-boot: identity wipe, WiFi fallback, mode/board select, passwd prompt
  first-boot.service       # systemd oneshot running the noninteractive half of the wizard at boot
  00-lyra-first-boot.sh    # profile.d hook triggering the interactive wizard on first login
  nomadnet.service         # NomadNet daemon unit
  rngit.service            # rngit (RRC chat) daemon unit
dts-overlay/
  lyra-zero-w-pi-header.dts        # THE devicetree overlay (SPI0 + I2C0), hardware-verified
  lyra-zero-w-pi-spi0-lora.dts.template  # stale, kept only as historical reference - ignore
  README.md                # full pin-mapping derivation + every real bug found testing live
  dump-lyra-pinctrl.sh     # run on a live board over SSH to dump its pinctrl state
README.md                  # public-facing project README
HANDOFF.md                 # this file
.gitignore                 # excludes work/ (build workspace) and out/ (build output)
```

## 3. Hardware status — what's actually verified vs. not

All of the following was tested live over SSH on the physical board
(`lyra-node` / `10.0.0.200`, see §8 for access details):

| Component | Status |
|---|---|
| WiFi (aic8800 chip: rfkill soft-block fix, netplan `wlan0` direct-key syntax) | **Hardware-verified working** |
| SPI0 remapped to Pi header pins 19/21/23/40 | **Hardware-verified** — `/dev/spidev0.0` exists, zero dmesg errors |
| IRQ/BUSY/RESET GPIO lines (pins 36/38/12) | **Hardware-verified** — pinmux confirmed correct |
| I2C0 remapped to Pi header pins 3/5 (I2C1 position, for RTC/INA3221) | **Hardware-verified** — `/dev/i2c-0` exists, `i2cdetect -y 0` scans cleanly (empty scan expected, nothing wired yet) |
| End-to-end LoRa radio through an actual HAT | **NOT tested** — no physical LoRa HAT existed at time of writing (NomDeTom is still designing one against this exact pinout) |
| rngit / RRC chat install | Known Rust/cbor2-under-qemu-emulation build issue, has a piwheels-based workaround in the build script, not fully hardened |
| Meshtasticd mode | Installed, disabled by default, selectable via first-boot wizard — **not live-tested**, only that the install step works |

## 4. The pinout — full derivation and why it's trustworthy

Confirmed exact match, physical-pin-for-physical-pin, against **both**:
- `reticulum-hat-mod`'s bundled `meshadv-pi-hat-v1.1` board profile
- meshtasticd's own canonical config for the MeshAdv HAT
  (`bin/config.d/lora-MeshAdv-900M30S.yaml` in `meshtastic/firmware`)

| Signal | Physical pin | BCM (Pi reference) | Lyra RM_IO | Lyra GPIO chip/line |
|---|---|---|---|---|
| SPI0 MOSI | 19 | 10 | RM_IO6 | (SPI controller pin, not raw GPIO) |
| SPI0 MISO | 21 | 9 | RM_IO7 | (SPI controller pin) |
| SPI0 SCLK | 23 | 11 | RM_IO8 | (SPI controller pin) |
| SPI0 CS/NSS | 40 | 21 | RM_IO18 | gpiochip0 line 18 (bit-banged CS, see §5) |
| LoRa IRQ/DIO1 | 36 | 16 | RM_IO29 | gpiochip1 line 25 |
| LoRa BUSY | 38 | 20 | RM_IO17 | gpiochip0 line 17 |
| LoRa RESET | 12 | 18 | RM_IO14 | gpiochip0 line 14 |
| LoRa TXEN (optional) | 33 | 13 | RM_IO27 | gpiochip1 line 18 |
| LoRa RXEN (optional) | 32 | 12 | RM_IO30 | gpiochip1 line 26 |
| I2C SDA | 3 | 2 | RM_IO0 | (I2C controller pin) |
| I2C SCL | 5 | 3 | RM_IO1 | (I2C controller pin) |

Notes:
- This physical 40-pin layout is standardized across the **entire modern
  Raspberry Pi lineup** with a 40-pin header (Zero/Zero W/Zero 2W, 2B+/3/4/5,
  400, CM IO boards) — only the original Pi 1 Model A/B had a smaller 26-pin
  header. So any HAT built against this pinout works across the whole
  modern Pi family too, not just this specific board.
- CS on pin 40 is **bit-banged via GPIO** (`cs-gpios` in the devicetree
  overlay), not driven by hardware SPI CE0 — this matches exactly how both
  the meshadv HAT's Pi reference design and meshtasticd's own config handle
  it (confirmed identical approach, not a Lyra-specific workaround).
- `i2c2` (a different Lyra I2C controller, `ff060000`) was already claimed
  by the board's touchscreen — do not repurpose it. `i2c1` (`ff050000`) is
  free if a second I2C bus is ever needed.

## 5. Real bugs found building the devicetree overlay (don't repeat these)

Full derivation is in `dts-overlay/README.md`; short version of the three
real, non-obvious devicetree bugs found by testing live on hardware:

1. **`cs-gpios` is required** even though the CS pin is also pinmux'd to the
   hardware CSN0 function — without it, `spi_master` never registers, with
   **zero dmesg output at all** (silent failure). Found by cross-referencing
   NomDeTom's own known-working femtofox config
   (`github.com/joshbowyer/femtofox`, same `rockchip,rk3066-spi`-family
   driver) which does the same thing.
2. **Pin groups must be nested inside an intermediate named subnode**
   (e.g. `lora_pi { lora-pi-spi0-mosi {...}; }`), not declared directly as
   children of `&pinctrl`. Flat top-level nodes fail with
   `rockchip-pinctrl pinctrl: unable to find group for node <name>` in
   dmesg. Matches this board's own base-tree pattern (`rm_io6 { rm-io6-
   spi0-mosi {...}; }`).
3. **One pin per node** — a single node with a comma-separated multi-tuple
   `rockchip,pins` list also fails with the same "unable to find group"
   error. Each signal needs its own named subnode.

The devicetree overlay itself was iterated live 3 times against the actual
board until all of these were found and fixed — the current
`lyra-zero-w-pi-header.dts` in the repo is the final, working version.

## 6. The build script — what it does, stage by stage

`build-lyra-gold-image.sh` runs on a Linux dev machine (not the board):
downloads the stock Armbian community image for this board, loop-mounts +
chroots into it via `qemu-arm-static`, configures everything, then repacks
it into `out/lyra-gold.img`. Idempotent — re-extracts a fresh raw image copy
every run.

Stages (abbreviated — read the script itself for exact commands):
1. Download/cache the base Armbian image
2. Decompress to a fresh working copy
3. Loop-mount + prepare qemu-arm-static chroot
4. Base apt packages
5. Create `lyra` user (password `lyra:lyra`, hardcoded — see §9), install SSH key
6. Install RNS/LXMF/NomadNet, rngit (with piwheels cbor2 fix, see §9),
   reticulum-hat-mod driver + `sx126x_platforms` overlay
7. Install meshtasticd (disabled by default)
8. Deploy systemd services (nomadnet, rngit, first-boot)
9. Base Reticulum config (includes the `[[MeshAdv LoRa]]` interface block)
   - WiFi bake-in (interactive prompt or `LYRA_WIFI_SSID`/`LYRA_WIFI_PSK` env vars)
   - rfkill soft-block pre-seed (writes `/var/lib/systemd/rfkill/*` = `0`
     directly, does NOT run `rfkill unblock` in the chroot — that would
     incorrectly touch the *host build machine's* real rfkill state since
     `/sys` is bind-mounted from the host)
   - Compiles + installs the devicetree overlay (`dtc` on the host — no qemu
     needed, dtc is architecture-independent) and updates the chroot's
     `armbianEnv.txt` with `user_overlays=lyra-zero-w-pi-header`
10. Hostname (`lyra-node`)
11. Fix ping capability (known qemu-chroot quirk)
12. Ownership/cleanup, unmount, repack image

## 7. Root cause of the original session deaths (IMPORTANT, load-bearing fix)

Two prior sessions working on this exact project hung/died mid-work. Root
cause: the build's loop-mounted chroot (`work/mnt`) contains **live bind
mounts of the host's real `/dev`, `/proc`, `/sys`** during a build. This
directory was, at the time, sitting in a git-tracked (ungitignored) part of
the repo. The agent environment's own git-based snapshot/checkpoint system
does full-tree operations on the project directory between steps — walking
into those live virtual filesystems can hang indefinitely or balloon in
size (huge dynamic content, blocking device files, potential symlink
loops).

**Fix applied**: `.gitignore` in this repo excludes `work/` (and `out/`)
entirely. **This is load-bearing — do not remove it, and never leave chroot
bind mounts inside a non-ignored path in ANY related repo.** If cloning this
project into a different working copy, always gitignore the build
workspace before ever running the build script inside an agent session.

## 8. Live board access (if still available)

- SSH alias: `ssh lyra-node` (configured in `~/.ssh/config` as
  `10.0.0.200`, user `lyra`, key `~/.ssh/id_ed25519_minimax`)
- Board's own sudo password: `lyra` (for the `lyra` user on the board
  itself — unrelated to any local machine sudo password)
- Useful live-debugging commands used throughout this project:
  - `ssh lyra-node 'dtc -I fs -O dts /proc/device-tree'` — dump the live
    device tree
  - `dts-overlay/dump-lyra-pinctrl.sh` — helper script for the above plus
    gpioinfo/spidev checks
  - After changing the overlay: `scp` the `.dts` to `/tmp` on the board,
    `dtc -@ -I dts -O dtb` to compile, copy the `.dtbo` to
    `/boot/overlay-user/`, confirm `user_overlays=` in `/boot/armbianEnv.txt`
    points at it, `sudo reboot`, then check `/sys/class/spi_master/`,
    `/dev/spidev0.0`, `/dev/i2c-0`, and `dmesg` for errors.

## 9. Known open items / deliberate decisions

- **`lyra:lyra` default login is intentional** (user's explicit decision) —
  the first-boot wizard prompts to run `passwd` interactively, but it's not
  force-changed.
- **rngit/rrcd install** can still fail under qemu emulation in some
  environments (Rust/cbor2 build issue) — the build script's piwheels
  workaround (`pip3 install --index-url https://www.piwheels.org/simple
  cbor2` before installing rrcd) handles the common case; if it still
  fails, the documented fallback is installing rustup + a modern toolchain
  instead of relying on Debian's packaged rustc.
- **No RTC/INA3221 chip config yet** — I2C0 bus is up and verified, but no
  specific chip has been chosen/wired. `dts-overlay/lyra-zero-w-pi-header.dts`
  fragment@3 has commented placeholder child nodes
  (`rtc@68`/`ina3221@40`) ready to fill in once a chip is picked.
- **End-to-end LoRa radio is unverified** — everything up to the SPI
  bus/GPIO lines is hardware-confirmed, but no physical radio has been
  tested through it yet (chicken-and-egg: NomDeTom's HAT design depends on
  this exact pinout being finalized first).
- **WSL2 build caveats** (documented in main README): loop devices can be
  flaky on some WSL2 kernels; flashing needs a raw block device which WSL2
  doesn't pass through by default (workaround: build in WSL, flash from
  Windows with Etcher/Rufus, or use `usbipd-win`).

## 10. LR1121 — future work, not started

Context: NomDeTom (the HAT designer) is also a Meshtastic firmware
collaborator. Recon-only research (no code written) covered:

- **LR1121** (Semtech's next-gen chip, multi-band: sub-GHz + 2.4GHz +
  S-band satellite, LR-FHSS, Sigfox) is **air-interface and control-signal
  compatible with SX1262** at the hardware level (same SPI/NSS/BUSY/
  RESET/IRQ shape) — a viable future upgrade path, not a different pinout.
- **No Reticulum support exists anywhere** (mainline or third-party) —
  we'd be first. `reticulum-hat-mod` currently only has `SX126xInterface.py`.
- meshtasticd/mainline Meshtastic firmware **does** already support LR1121
  (RadioLib-backed), including a real, currently-open bug: **PR #11215**
  (`meshtastic/firmware`, opened by NomDeTom) fixes a hang where
  configuring a TCXO reference on a bare/no-TCXO LR1121 module makes
  RadioLib hang forever (unbounded BUSY wait), requiring a physical power
  cycle to recover (upstream: `jgromes/RadioLib#1844`). Fix: try XTAL
  first, fall back to TCXO only if the chip answers and refuses XTAL. As of
  writing, the PR is open, structurally low-risk (a no-op for every
  already-shipped board — only affects boards defining `TCXO_OPTIONAL`),
  and awaiting a second review pass from `vidplace7`. A code review was
  posted to the PR (with an LLM-assistance disclosure footer, per the
  user's request) confirming the fix's correctness and low blast radius.
- **When we do build an LR1121 interface for Reticulum**: this is a
  moderate adaptation of the existing `SX126xInterface.py` architecture
  (radio-owner thread, IRQ-driven, spidev + libgpiod), not a rewrite.
  Reference driver: Semtech's `Lora-net/SWDR001` (C driver covering
  LR1110/LR1120/LR1121). **Must bake in the same XTAL-first-then-TCXO-
  fallback ordering from PR #11215 independently** — this is a hardware/
  protocol-level LR1121 quirk, not a meshtastic-specific bug, so any new
  driver would hit the identical hang if it didn't account for it.
- **Trigger to resume this work**: once NomDeTom (or anyone) has actual
  LR1121 hardware in hand to test against. Not started, no code written,
  no HAT exists yet.

## 11. Related documentation

- `dts-overlay/README.md` — the authoritative source for the pinmux
  derivation and every real hardware bug found (more detail than this doc).
- `/home/josh/Reticulum/docs/15-lyra-gold-image-build-handoff.md` — the
  original internal handoff doc from the source project this was extracted
  from, includes the full narrative of the two prior session deaths and
  root-cause investigation (see §7 above for the short version).
- Main `README.md` in this repo — public-facing quick-start + hardware
  status table + WSL2 notes.
