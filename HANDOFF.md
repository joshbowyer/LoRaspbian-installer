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
  sx126x_boards            # board profiles not (yet) upstream (meshadv-mini)
  lyra-hat-pinmux          # switch user_overlays: meshadv | meshadv-mini | station-g3
  first-boot-wizard.sh     # on-device first-boot: identity wipe, WiFi fallback, mode/board select, passwd prompt
  first-boot.service       # systemd oneshot running the noninteractive half of the wizard at boot
  00-lyra-first-boot.sh    # profile.d hook triggering the interactive wizard on first login
  nomadnet.service         # NomadNet daemon unit
  rngit.service            # rngit (RRC chat) daemon unit
dts-overlay/
  lyra-zero-w-pi-header.dts        # MeshAdv Pi Hat v1.1 (CS40 RST12 PPS16) — default gold
  lyra-zero-w-meshadv-mini.dts     # MeshAdv Mini (CS24 RST18 RXEN32 PPS11) — pinmux verified lyra2
  lyra-zero-w-station-g3.dts       # Station G3 alternate control set
  lyra-zero-w-pi-spi0-lora.dts.template  # stale, kept only as historical reference - ignore
  README.md                # full pin-mapping derivation + every real bug found testing live
  dump-lyra-pinctrl.sh     # run on a live board over SSH to dump its pinctrl state
u-boot/
  autoboot-keyed.fragment  # CONFIG_AUTOBOOT_KEYED + stop str "uboot" (Mini GPS on UART0)
  README.md                # build/flash/restore KEYED U-Boot; serial rescue
README.md                  # public-facing project README
HANDOFF.md                 # this file
.gitignore                 # excludes work/ out/ and client-setup/ (local bins/scripts)
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

## 12. MeshAdv Mini overlay (2026-09-01) — resume when hats arrive

### Why this exists

LoRaspbian originally targeted **MeshAdv Pi Hat v1.1** only
(`lyra-zero-w-pi-header.dts`: CS pin **40**, RST pin **12**, PPS pin **16**).
The **MeshAdv Mini** (chrismyers2000/MeshAdv-Mini) uses a different control
set on the same 40-pin form factor. Loading the Pi Hat overlay on a Mini
would drive **physical pin 12 as RESET** — on Mini that pin is **Fan PWM**,
which is dangerous. A third, mutually exclusive overlay was added.

### Pin mismatch (settled)

| Function | MeshAdv Mini | MeshAdv Pi Hat v1.1 / old default |
|---|---|---|
| SPI MOSI/MISO/CLK | 19 / 21 / 23 | same |
| CS | **24** (BCM8) | **40** |
| RESET | **18** (BCM24) | **12** (Mini pin12 = Fan PWM — NEVER) |
| IRQ / BUSY | 36 / 38 | same |
| RXEN | **32** | platforms map / not default pi-header control |
| GPS PPS | **11** | **16** |
| Extra Mini | DIO2 RF switch, DIO3 TCXO 1.8V, GPS EN/UART optional | — |

Mini yaml (upstream): CS:8 IRQ:16 Busy:20 Reset:24 RXen:12
`DIO2_AS_RF_SWITCH` `DIO3_TCXO`.

### Critical Lyra phys → RM_IO map (pin 24 was the gap)

| Phys | Function (Mini) | RM_IO | gpio |
|---|---|---|---|
| 19/21/23 | SPI | 6/7/8 | SPI mux 0x53/0x54/0x52 |
| **24 CS** | CSN0 | **RM_IO10** | **gpiochip0 line 10** (bank0 offset 0x0a), mux **0x55** |
| **18 RST** | RESET out high | RM_IO12 | g0.12 |
| 36 / 38 | IRQ / BUSY | 29 / 17 | g1.25 / g0.17 |
| **32 RXEN** | out low default | RM_IO30 | g1.26 |
| **11 PPS** | input | RM_IO3 | g0.3 |
| 3/5 | I2C | 0/1 | i2c0 |

**Pin 24 = RM_IO10** confirmed from:
1. Luckfox Zero W interactive pinout WebP (`GPIO0_B2_d` / RM_IO10)
2. Official DTBO `rockchip-luckfox-lyra-zero-w-spi0-2cs-spidev` (CS0 on RM_IO10)
3. Cross-check: all previously verified pins (11,12,15,16,18,19,21,23,32,33,36,38,40) matched the same diagram

Full 40-pin table lives in `dts-overlay/README.md`.

### Files added/changed (this work)

| Path | Role |
|---|---|
| `dts-overlay/lyra-zero-w-meshadv-mini.dts` | NEW overlay: SPI + CS RM_IO10, RST18, IRQ36, BUSY38, RXEN32 out low, PPS11 in, I2C 3/5; pinctrl group `lora_mini`; cs-gpios `<&gpio0 0x0a 0x01>` |
| `files/sx126x_boards` | NEW hat-mod board overlay `[[meshadv-mini]]` (cs=24 reset=18 rxen=32 dio2=True dio3=1.8) |
| `files/sx126x_platforms` | added `"24": ["gpiochip0", 10]` |
| `files/lyra-hat-pinmux` | third profile `meshadv-mini`; detect **mini before** generic `meshadv` substring |
| `files/first-boot-wizard.sh` | 3-option HAT menu + `pinmux_profile_for_hat` → meshadv-mini |
| `build-lyra-gold-image.sh` | compile 3rd dtbo; install `sx126x_boards` beside platforms |
| `dts-overlay/README.md` | rewritten for three overlays + Mini pin table + critical fan-PWM warning |

Gold **default remains** `lyra-zero-w-pi-header` / `radio_board=meshadv-pi-hat-v1.1`.
For Mini, config must use `radio_board = meshadv-mini` and `pin_cs = -1`
(HW CS owned by spidev on pin24), same pin_cs=-1 pattern as Pi Hat on pin40.

Overlays are **mutually exclusive**: only one of
`lyra-zero-w-pi-header` | `lyra-zero-w-meshadv-mini` | `lyra-zero-w-station-g3`
in `user_overlays=`.

### What was verified on lyra2 (10.0.0.56) — pinmux only

**NEVER touch lyra1 (10.0.0.108)** — it runs a real MeshAdv Pi Hat.

On lyra2 only:
- Host `dtc` compile of mini.dts OK
- Installed mini `.dtbo` + updated pinmux/platforms/boards under
  `/boot/overlay-user/`, `/usr/local/sbin/lyra-hat-pinmux`,
  `/home/lyra/.reticulum/interfaces/`
- Applied mini: live pinctrl group **`lora_mini`**, CS on **gpio0-10**,
  cs-gpios offset **0xa**, `/dev/spidev0.0` + `/dev/i2c-0` up, no dmesg
  pinmux errors
- **Gotcha:** `lyra-hat-pinmux ensure` (and mesh startup paths that call it)
  rewrites `user_overlays` from `radio_board` in reticulum config. If
  `radio_board` is still `meshadv-pi-hat-v1.1`, ensure snaps back to
  **pi-header**. Sticky Mini requires `radio_board = meshadv-mini`.
- lyra2 was **restored to pi-header** after the pinmux smoke test (CS g0.18,
  `lora_pi`). Mini dtbo + updated userspace files were **left installed**
  on lyra2 for the next test pass. lyra2 hat conf may still say
  `wio-sx1262` / `meshadv-pi-hat-v1.1` until a Mini is attached and config
  is switched.

### Access / infra for resume

| Host | IP | Notes |
|---|---|---|
| lyra1 | 10.0.0.108 | MeshAdv Pi Hat — **DO NOT TOUCH** for Mini work |
| lyra2 | 10.0.0.56 | Safe Mini test target; hostname `lyra2` |
| josh-claw hub | 10.0.0.59 | RNS TCP hub :4242 |

SSH: `ssh -i ~/.ssh/id_ed25519_minimax lyra@10.0.0.56`  
sudo password historically `Lyra1234`.

### Checklist when MeshAdv Mini hardware arrives

1. Confirm physical board is Mini (CS on header pin 24 silk / docs), not Pi Hat v1.1.
2. On **lyra2 only**:
   ```bash
   sudo lyra-hat-pinmux apply meshadv-mini
   # edit ~/.reticulum/config [[MeshAdv LoRa]] (or hat conf):
   #   radio_board = meshadv-mini
   #   pin_cs = -1
   # keep frequency/SF/etc. as needed; dio2/dio3 come from sx126x_boards
   # /etc/lyra-hardware.conf must say hat=meshadv-mini (not wio-sx1262)
   sudo reboot
   ```
3. After boot (bare first, then with HAT):
   ```bash
   lyra-hat-pinmux status
   # expect overlay lyra-zero-w-meshadv-mini, CS gpio0-10 / lora_mini
   ls -l /dev/spidev0.0 /dev/i2c-0
   # GPS EN hogged low (LoRa-first):
   sudo cat /sys/kernel/debug/gpio | grep meshadv-mini-gps-en   # out lo
   # RESET/RXEN/IRQ/BUSY/PPS must be owned by ff120000.spi (not UNCLAIMED-only):
   sudo cat /sys/kernel/debug/pinctrl/*/pinmux-pins | grep lora-mini
   dmesg | tail -50   # no spi/pinctrl errors
   ```
4. **HAT install procedure (power-sensitive):**
   - Power off, seat Mini firmly (orientation), **antenna on SMA before power**.
   - Use a solid **5V** supply (USB power bank / wall brick that holds 5V under load).
   - Boot; if no SSH within ~2 min, remove HAT and boot bare to recover.
5. Bring up Reticulum mesh / SX126x interface; confirm radio init (no BUSY hang,
   CS responds, TX/RX path). RXEN should be driven by hat-mod from profile.
6. Optional GPS later: remove/disable pin7 `meshadv-mini-gps-en` hog (or add a
   mini+gps profile), drive EN high, enable UART0 on pins 8/10 (RM_IO22/23).
   PPS pin11 is already GPIO-in via SPI pinctrl.
7. If sticky overlay keeps flipping to pi-header: check `radio_board`,
   `/etc/lyra-hardware.conf`, and mesh `ensure`.
8. When e2e works: rebuild gold image; **push** only when user asks.
9. Do **not** run Mini pinmux on lyra1 while Pi Hat is attached.

### Boot hang with Mini HAT (2026-09-05) — REAL root cause is U-Boot

**Symptom:** lyra2 boots fine bare with mini overlay. With MeshAdv Mini seated:
solid red user LED, never reaches userspace (no SSH, no journal). Remove HAT
→ boots again. Overlay alone does not brick. Physical reseat + high-watt PD
PSU did not help.

**Root cause (~85%, confirmed defconfig + Mini pinout): U-Boot autoboot abort**

| Fact | Detail |
|---|---|
| Mini GPS TX | header **pin 10** (and RX on pin 8) |
| Lyra pin 8/10 | **UART0** = RM_IO22/23 |
| Vendor U-Boot | `CONFIG_DEBUG_UART_BASE=0xFF0A0000` (UART0), baud **1500000** |
| Autoboot | `CONFIG_BOOTDELAY=1`, **`# CONFIG_AUTOBOOT_KEYED is not set`** |
| Effect | Any RX noise/break on pin 10 aborts countdown → stuck at `=>` |
| Why solid red | Power OK; Linux never starts (no heartbeat) |
| Why Pi Zero 2W “works” | Pi firmware does not treat 8/10 as unkeyed “any key cancel boot” |
| Why overlay cannot fix | DTS runs **after** U-Boot |

lyra1 + MeshAdv **Pi Hat** works because that hat typically has **no GPS on 8/10**.

**Overlay hardening still valid (not the hang fix):** commit `34fea9a` moved
RESET/RXEN/IRQ/BUSY/PPS onto `spi0` pinctrl and hogged GPS EN pin7 LOW for
LoRa-first. Keep it; it is good practice, not the boot-past-U-Boot fix.

### KEYED U-Boot (2026-09-05) — installed on lyra2

**Config fragment** (see `u-boot/autoboot-keyed.fragment` + `u-boot/README.md`):

```
CONFIG_BOOTDELAY=1
CONFIG_AUTOBOOT_KEYED=y
CONFIG_AUTOBOOT_FLUSH_STDIN=y
CONFIG_AUTOBOOT_PROMPT="Hit 'uboot' to stop autoboot: %d\n"
CONFIG_AUTOBOOT_STOP_STR="uboot"
CONFIG_LOCALVERSION="-loraspbian-keyed"
```

Serial rescue: type **`uboot`** (not any key) during countdown @ **1500000** baud.

**Built:** U-Boot `2026.07-loraspbian-keyed` (Armbian tag v2026.07 +
`v2026.07-rk3506` patches, TPL `rk3506b_ddr_750MHz_v1.06.bin`, TEE
`rk3506_tee_v2.10.bin`). Host build tree:
`/tmp/opencode/lyra-uboot-build/` (not in git). Artifact on lyra2:
`/home/lyra/u-boot-rockchip-keyed.bin` (sha256
`0016e6a9c2f68b5e68983950e2907e54999438b3850eaaa9a4cd68a40a4f1ff9`).

**Flash recipe (lyra2 ONLY — never lyra1):**

```bash
# on board after scp of u-boot-rockchip.bin
sudo dd if=/home/lyra/uboot-backup-pre-keyed-16M.bin of=/dev/mmcblk0 bs=1M count=16  # restore if needed
sudo dd if=/home/lyra/u-boot-rockchip-keyed.bin of=/dev/mmcblk0 bs=32k seek=1 conv=notrunc
sudo sync && sudo reboot
```

Same `bs=32k seek=1` as `/usr/lib/u-boot/platform_install.sh`.

**Backups on lyra2:**
- `/home/lyra/uboot-backup-16M.bin` (stock, sha256 `61b8c43c…`)
- `/home/lyra/uboot-backup-pre-keyed-16M.bin` (pre-flash snapshot, same stock hash)

**Verified 2026-09-05:** lyra2 **hatless** reboot after KEYED flash → SSH OK,
kernel 6.1.115-vendor-rockchip, `user_overlays=lyra-zero-w-meshadv-mini`,
`radio_board=meshadv-mini`, `hat=meshadv-mini`.

**Verified 2026-09-05 (HAT seated):** KEYED U-Boot + Mini HAT boots to SSH.
TMP102 @ I2C 0x48 proves HAT present. GPS still EN-hogged LOW (LoRa-first).

### LoRa SX126x bring-up on lyra2 (2026-09-05) — WORKING

**Status:** `SX126xInterface[MeshAdv LoRa] Status: Up` on lyra2 with
`radio_board=meshadv-mini`, `pin_cs=-1`, overlay `lyra-zero-w-meshadv-mini`.
Params match lyra1 (915e6 / BW125k / SF7 / CR5 / tx22). RX counters climb
while lyra1 is on air (LoRa path alive; formal LXMF e2e still next).

**Three blockers fixed live on lyra2 (also baked into installer):**

1. **`files/sx126x_platforms` ConfigObj format** — `header_pin_to_line` MUST
   be a **single-quoted JSON string** with **full `/dev/gpiochipN` paths**.
   Unquoted `{...}` is split on commas → driver rejects overlay → platform
   `luckfox-lyra-zero-w` never loads → only bundled `luckfox-pico` /
   `raspberry-pi`. lyra1 already had the correct quoted form; installer had
   drifted to bare `gpiochip0` + unquoted JSON. Includes pin **24** (Mini CS).

2. **Missing Python deps** — gold image lacked `python3-spidev` and
   `python3-libgpiod`. Installed on lyra2 via apt; build script now installs
   both (+ `gpiod` CLI). lyra1 had them via earlier manual/pip path.

3. **`lyra` not in `spi`/`gpio` groups** — `/dev/spidev0.0` and
   `/dev/gpiochip*` are root:spi / root:gpio mode 660. `usermod -aG spi,gpio
   lyra` on lyra2; build script adds those groups at user creation.

**Do not “simplify” the platforms JSON** back to unquoted braces.

### LXMF path e2e (2026-09-05) — WORKING over LoRa

- lyra2 → lyra1 LXMF / rnsh: **1 hop** `SX126xInterface[MeshAdv LoRa]`
- lyra1 → lyra2 LXMF + NomadNet node: **1 hop** MeshAdv LoRa
- lyra2 ids (example): NomadNet `48c5712a…`, LXMF `8f0a6f5a…`, node `bc06f566…`

### RX LED solid red (not a bug)

MeshAdv Mini schematic: D8 “LoRa RX” MOSFET gate is hard-tied to net **RXEN**
(module pin6 + header pin32). Continuous RX keeps RXEN high → solid red while
listening. Not independently blinkable in software. TX LED is module TXEN only.

### GPS path closed on vendor kernel (2026-09-05)

| Attempt | Result |
|---|---|
| `&uart0` okay only | brick hang (even hatless) |
| `&fiq_debugger` disabled only | brick hang |
| fiq off + uart0 + GPS EN high | brick hang |

Ship **LoRa-only** Mini. Onboard GPS deferred until **mainline** RK3506 DT
(no FIQ on UART0). Documented in README + `dts-overlay/README.md`. USB GPS
is the interim option. KEYED U-Boot remains required for Mini HAT boot.

### Ship note (v1.1.0)

LoRa-only Mini + KEYED docs + platforms JSON + spidev/gpiod + GPS-deferred
mainline note. Push GitHub + rngit; gold image release.

### KEYED mandatory in gold builds (post-v1.1.0)

v1.1.0 release images bake KEYED, but self-builds previously **skipped** KEYED
when `files/u-boot-rockchip-keyed.bin` was missing (gitignored) → Mini HAT
solid-red hang (lyra4). Fix: binary is **git-tracked**; build script always
bakes KEYED (SHA256 verify); download fallback from GH release asset; **exit 1**
if unavailable. Repair already-flashed SD:

```bash
sudo dd if=files/u-boot-rockchip-keyed.bin of=/dev/sdX bs=32k seek=1 conv=notrunc
```

WiFi bake unchanged (`LYRA_WIFI_SSID` / `LYRA_WIFI_PSK`).

### INA3221 + env sensors baked (2026-09-06)

Verified on **lyra3** (solar enclosure): INA3221 @0x40 (ch1=solar ch2=bat
ch3=system), MeshAdv Mini TMP102 @0x48 (hat MOTD only), BME280 @0x77 (ambient
→ collector; temp supersedes TMP102).

**Image bake** (`build-lyra-gold-image.sh` §7d):
- apt: `python3-smbus` (+ existing `i2c-tools`); `lyra` in `i2c` group
- `/home/lyra/ina3221/` scripts + `config.json` (display_name=lyra, collector
  The Spot `da424e0f47657d7575df58a2b83b111b`)
- timers enabled: `ina3221-cache.timer` (1 min MOTD), `ina3221-beacon.timer`
  (10 min LXMF FIELD_TELEMETRY), `ina3221-powerguard.timer` (1 min soft-stop)
- first-boot wipes `~/.ina3221/identity` + lxmf_storage + cache
- MOTD via `motd-raspi.sh` reads `~/.cache/ina3221.json` (Power/Env/Hat + Bat Guard)

### Battery powerguard (two-stage, no OS poweroff) — 2026-09-08

After lyra3 overnight crash left `armbianEnv.txt` and LXMF ratchets all-zero
(bat telem ~2.8 V), soft-stop mesh before the charge board UVLO hard-cuts:

| | |
|---|---|
| Script | `ina3221-powerguard.py` (root oneshot) |
| Unit | `ina3221-powerguard.timer` every 60s (OnBootSec=90s) |
| Stop | `bat` ≤ **3.0 V** for 2 consecutive polls → `systemctl stop reticulum-mesh` + `sync` |
| Restore | `bat` ≥ **3.4 V** for 2 polls → `systemctl start reticulum-mesh` |
| Never | `poweroff` / `halt` / `shutdown` (UVLO still kills; board restores power) |
| State | `/var/lib/lyra/ina3221-powerguard.state` (atomic write) |
| Config | `config.json` → `powerguard` block (`enabled`, `bat_label`, thresholds) |

MOTD shows **Bat Guard** when cache has `powerguard_mode` (powerguard annotates
cache on each run). Disable: set `powerguard.enabled=false` or
`systemctl disable --now ina3221-powerguard.timer`.

Deploy live boards: scp script+units+config, `systemctl daemon-reload &&
systemctl enable --now ina3221-powerguard.timer`.

Absent chips are skipped (no hard fail). Edit labels/collector/display_name
on each node after first boot.
