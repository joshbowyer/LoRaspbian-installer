#!/bin/bash
# Build a customized Lyra Zero W Armbian image from a pristine download.
# Idempotent: safe to re-run after tweaking any of the steps below - always
# starts from a clean copy of the pristine downloaded image.
#
# Requires: wget, xz-utils, util-linux (losetup), qemu-user-static, e2fsprogs
# Run as: sudo ./build-lyra-gold-image.sh
#
# Output: ./out/lyra-gold.img (raw, ready to dd or compress)

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Must run as root (needs losetup/chroot). Try: sudo $0"
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/work"
OUT="$HERE/out"
mkdir -p "$WORK" "$OUT"

IMAGE_URL="https://github.com/armbian/community/releases/download/26.8.0-trunk.7/Armbian_community_26.8.0-trunk.7_Luckfox-lyra-zero-w_trixie_vendor_6.1.115_minimal.img.xz"
IMAGE_XZ="$WORK/armbian-lyra.img.xz"
IMAGE_RAW="$WORK/armbian-lyra.img"
MNT="$WORK/mnt"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519_minimax.pub}"

# WiFi baked into the image at build time (solves the chicken-and-egg problem:
# a freshly flashed card has no way to reach it over SSH to run the on-device
# wizard if it's never joined any network). Pass via env vars for automation,
# e.g. LYRA_WIFI_SSID="Foo" LYRA_WIFI_PSK="bar" sudo -E ./build-lyra-gold-image.sh
# Leave both empty (or run non-interactively with neither set) to skip - the
# on-device first-boot wizard still offers WiFi setup as a fallback.
LYRA_WIFI_SSID="${LYRA_WIFI_SSID-}"
LYRA_WIFI_PSK="${LYRA_WIFI_PSK-}"
if [ -z "$LYRA_WIFI_SSID" ] && [ -t 0 ]; then
    read -r -p "WiFi SSID to bake into the image (blank to skip, configure later via first-boot wizard): " LYRA_WIFI_SSID
    if [ -n "$LYRA_WIFI_SSID" ]; then
        read -r -s -p "WiFi password: " LYRA_WIFI_PSK
        echo
    fi
fi

# Security hardening for unattended field deployment (relay/repeater nodes):
# disables WiFi permanently, masks the serial console, and skips baking in
# WiFi credentials even if provided above. Pass LYRA_SECURITY_HARDEN=yes for
# automation, or leave unset in an interactive run to be prompted. Skip this
# entirely for dev/test images you want local console/WiFi access to - the
# on-device first-boot wizard offers this as an on-device fallback either way.
LYRA_SECURITY_HARDEN="${LYRA_SECURITY_HARDEN-}"
if [ -z "$LYRA_SECURITY_HARDEN" ] && [ -t 0 ]; then
    read -r -p "Harden this image for unattended field deployment (disables WiFi + serial console permanently)? [y/N]: " _harden_answer
    case "${_harden_answer,,}" in
        y|yes) LYRA_SECURITY_HARDEN=yes ;;
        *) LYRA_SECURITY_HARDEN=no ;;
    esac
fi

# --- 1. Download (cache-friendly: skip if already present) -----------------
if [ ! -f "$IMAGE_XZ" ]; then
    echo "Downloading base Armbian image..."
    wget -q --show-progress "$IMAGE_URL" -O "$IMAGE_XZ"
else
    echo "Using cached base image: $IMAGE_XZ"
fi

echo "Decompressing to a fresh working copy..."
rm -f "$IMAGE_RAW"
xz -dc "$IMAGE_XZ" > "$IMAGE_RAW"

# --- 1b. Grow the image before mounting --------------------------------------
# The stock Armbian minimal image ships with a tiny root partition (~1.6GB,
# already ~1.5GB used out of the box) - Armbian normally auto-grows this on
# the BOARD's own first real boot (growpart+resize2fs service), but our
# chroot-based build happens before that ever runs, so we're stuck with the
# original tiny size unless we grow it ourselves first. Confirmed live: stock
# image left ~14MB free, nowhere near enough for python3-dev/build-essential/
# rustc/cargo/meshtasticd. Pad by LYRA_IMAGE_GROW_GB (default 4) extra GB.
LYRA_IMAGE_GROW_GB="${LYRA_IMAGE_GROW_GB:-4}"
echo "Growing image by ${LYRA_IMAGE_GROW_GB}GB to make room for packages..."
truncate -s "+${LYRA_IMAGE_GROW_GB}G" "$IMAGE_RAW"

# --- 2. Loop-mount ----------------------------------------------------------
mkdir -p "$MNT"
LOOPDEV=$(losetup -Pf --show "$IMAGE_RAW")
echo "Loop device: $LOOPDEV"

echo "Expanding partition 1 and filesystem to use the new space..."
growpart "$LOOPDEV" 1
resize2fs "${LOOPDEV}p1"

cleanup() {
    set +e
    umount "$MNT/dev/pts" 2>/dev/null
    umount "$MNT/dev" 2>/dev/null
    umount "$MNT/proc" 2>/dev/null
    umount "$MNT/sys" 2>/dev/null
    umount "$MNT" 2>/dev/null
    [ -n "${LOOPDEV:-}" ] && losetup -d "$LOOPDEV" 2>/dev/null
}
trap cleanup EXIT

mount "${LOOPDEV}p1" "$MNT"

# --- 3. Prepare chroot -------------------------------------------------------
cp /usr/bin/qemu-arm-static "$MNT/usr/bin/"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
rm -f "$MNT/etc/resolv.conf"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

chroot_run() {
    chroot "$MNT" /usr/bin/qemu-arm-static /bin/bash -c "$1"
}

# --- 4. Base packages --------------------------------------------------------
echo "Installing base packages..."
chroot_run "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq"
chroot_run "export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev git i2c-tools dialog whiptail rustc cargo vim"
chroot_run "export DEBIAN_FRONTEND=noninteractive; apt-get purge -y -qq nano 2>/dev/null || true"

# --- 5. User + SSH ------------------------------------------------------------
echo "Creating lyra user..."
chroot_run "id -u lyra >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,dialout,plugdev,netdev lyra"
chroot_run "echo 'lyra:lyra' | chpasswd"
mkdir -p "$MNT/home/lyra/.ssh"
if [ -f "$SSH_PUBKEY_FILE" ]; then
    cp "$SSH_PUBKEY_FILE" "$MNT/home/lyra/.ssh/authorized_keys"
    chmod 600 "$MNT/home/lyra/.ssh/authorized_keys"
else
    echo "WARNING: $SSH_PUBKEY_FILE not found, no authorized_keys installed"
fi
chmod 700 "$MNT/home/lyra/.ssh"

# --- 6. Reticulum stack -------------------------------------------------------
echo "Installing RNS/LXMF/NomadNet/rngit..."
chroot_run "pip3 install --break-system-packages rns lxmf nomadnet"
chroot_run "rm -rf /tmp/rngit-src && git clone -q https://github.com/kc1awv/rrcd.git /tmp/rrcd-src"
# rrcd depends on cbor2>=5.6.0, which is a Rust/maturin extension. Debian
# Trixie's packaged rustc is too old to build it, and doing a real Rust build
# under qemu-arm-static emulation is fragile/slow anyway. Pull a prebuilt ARM
# wheel from piwheels instead of compiling from source.
chroot_run "pip3 install --break-system-packages --index-url https://www.piwheels.org/simple cbor2"
chroot_run "cd /tmp/rrcd-src && pip3 install --break-system-packages . || echo 'rrcd install failed even with piwheels cbor2 - inspect manually, see docs/15-lyra-gold-image-build-handoff.md'"
chroot_run "git clone -q https://github.com/joshbowyer/reticulum-hat-mod.git /tmp/reticulum-hat-mod || true"
mkdir -p "$MNT/home/lyra/.reticulum/interfaces"
if [ -d "$MNT/tmp/reticulum-hat-mod" ]; then
    cp "$MNT/tmp/reticulum-hat-mod/SX126xInterface.py" "$MNT/tmp/reticulum-hat-mod/vendored_sx126x.py" "$MNT/home/lyra/.reticulum/interfaces/" 2>/dev/null || true
fi
# Platform overlay teaching the driver this board's GPIO/SPI wiring, so the
# bundled "meshadv-pi-hat-v1.1" radio_board profile works unmodified. See
# files/sx126x_platforms and reticulum-config-base for details.
cp "$HERE/files/sx126x_platforms" "$MNT/home/lyra/.reticulum/interfaces/sx126x_platforms"

# --- 7. meshtasticd (installed, disabled) ------------------------------------
echo "Installing meshtasticd (disabled by default)..."
chroot_run "echo 'deb http://download.opensuse.org/repositories/network:/Meshtastic:/beta/Debian_13/ /' > /etc/apt/sources.list.d/network:Meshtastic:beta.list"
chroot_run "curl -fsSL https://download.opensuse.org/repositories/network:Meshtastic:beta/Debian_13/Release.key | gpg --dearmor > /etc/apt/trusted.gpg.d/network_Meshtastic_beta.gpg"
chroot_run "apt-get update -qq && apt-get install -y -qq meshtasticd"
chroot_run "systemctl disable meshtasticd 2>/dev/null || true"

# --- 8. systemd services ------------------------------------------------------
echo "Deploying systemd services..."
cp "$HERE/files/nomadnet.service" "$MNT/etc/systemd/system/nomadnet.service"
cp "$HERE/files/rngit.service" "$MNT/etc/systemd/system/rngit.service"
cp "$HERE/files/first-boot.service" "$MNT/etc/systemd/system/first-boot.service"
cp "$HERE/files/first-boot-wizard.sh" "$MNT/usr/local/sbin/lyra-first-boot-wizard.sh"
chmod +x "$MNT/usr/local/sbin/lyra-first-boot-wizard.sh"
# The full interactive wizard (mode/board/HAT selection) does NOT auto-launch
# on login - it's mentioned in the MOTD instead, and run manually via
# `sudo lyra-setup`. Only the noninteractive identity-wipe phase (invoked by
# first-boot.service below) still runs automatically at every first boot.
ln -sf /usr/local/sbin/lyra-first-boot-wizard.sh "$MNT/usr/local/bin/lyra-setup"
cp "$HERE/files/10-lyra-setup-motd" "$MNT/etc/update-motd.d/10-lyra-setup-motd"
chmod +x "$MNT/etc/update-motd.d/10-lyra-setup-motd"
chroot_run "systemctl enable nomadnet.service rngit.service first-boot.service"
# Disable (don't uninstall) the graphical boot target - this is a headless node.
chroot_run "systemctl set-default multi-user.target"

# SSH host keys: ensure they're generated fresh per-card at first boot rather
# than possibly missing (Armbian's own firstrun key-generation step appears to
# get skipped since we pre-grow the partition ourselves at build time instead
# of letting Armbian's firstrun growpart+keygen sequence do it) or shared
# across every flashed card.
cp "$HERE/files/lyra-ssh-hostkeys.service" "$MNT/etc/systemd/system/lyra-ssh-hostkeys.service"
chroot_run "rm -f /etc/ssh/ssh_host_*"
chroot_run "systemctl enable lyra-ssh-hostkeys.service"
mkdir -p "$MNT/etc/systemd/system/ssh.service.d"
cat > "$MNT/etc/systemd/system/ssh.service.d/override.conf" << 'EOF'
[Unit]
After=lyra-ssh-hostkeys.service
Wants=lyra-ssh-hostkeys.service
EOF

# systemd-networkd/netplan WiFi boot-race workaround (confirmed live on
# hardware: networkd reads its generated .network files too early on first
# boot, fails permission-denied, and never retries; a later restart picks up
# the config immediately). See dts-overlay-unrelated note in the .service
# file itself for full detail.
cp "$HERE/files/lyra-networkd-wifi-race-workaround.service" "$MNT/etc/systemd/system/lyra-networkd-wifi-race-workaround.service"
chroot_run "systemctl enable lyra-networkd-wifi-race-workaround.service"

# --- 9. Base Reticulum config (no LoRa interface yet - pinmux pending) ------
mkdir -p "$MNT/home/lyra/.reticulum"
cp "$HERE/files/reticulum-config-base" "$MNT/home/lyra/.reticulum/config"

# --- 9b. WiFi (baked in at build time, if provided above) -------------------
if [ "$LYRA_SECURITY_HARDEN" = "yes" ]; then
    echo "Security hardening enabled - skipping WiFi bake-in even if credentials were provided."
elif [ -n "$LYRA_WIFI_SSID" ]; then
    echo "Baking WiFi credentials into the image (SSID: $LYRA_WIFI_SSID)..."
    mkdir -p "$MNT/etc/netplan"
    cat > "$MNT/etc/netplan/20-wifi.yaml" << EOF
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: yes
      dhcp6: no
      access-points:
        "$LYRA_WIFI_SSID":
          password: "$LYRA_WIFI_PSK"
EOF
    chmod 600 "$MNT/etc/netplan/20-wifi.yaml"
else
    echo "No WiFi baked in - the on-device first-boot wizard will offer to configure it."
fi

# --- 9c. WiFi rfkill state ----------------------------------------------------
# The aic8800 combo chip ships soft-blocked; systemd-rfkill persists whatever
# state is on disk at /var/lib/systemd/rfkill/<device> across reboots, so we
# just need to pre-seed the desired state for the known device paths (confirmed
# live on hardware: platform-ff780000.usb-usb-0:1.1:wlan and the bluetooth
# counterparts) rather than actually calling `rfkill` here, since inside this
# qemu chroot that would touch the HOST build machine's real rfkill state, not
# the image's. Normally unblocked (0); permanently blocked (1) for WiFi only
# under security hardening, per the first-boot wizard's equivalent option.
mkdir -p "$MNT/var/lib/systemd/rfkill"
if [ "$LYRA_SECURITY_HARDEN" = "yes" ]; then
    echo "Security hardening enabled - permanently blocking WiFi via rfkill."
    echo 1 > "$MNT/var/lib/systemd/rfkill/platform-ff780000.usb-usb-0:1.1:wlan"
else
    echo 0 > "$MNT/var/lib/systemd/rfkill/platform-ff780000.usb-usb-0:1.1:wlan"
fi
echo 0 > "$MNT/var/lib/systemd/rfkill/platform-ff780000.usb-usb-0:1.1:1.0:bluetooth"
echo 0 > "$MNT/var/lib/systemd/rfkill/platform-wireless-bluetooth:bluetooth"

# --- 9e. Security hardening: mask serial console, mark done ------------------
if [ "$LYRA_SECURITY_HARDEN" = "yes" ]; then
    echo "Masking serial console for unattended deployment..."
    chroot_run "systemctl mask serial-getty@ttyS2.service 2>/dev/null || true"
    date -Iseconds | tee "$MNT/etc/lyra-security-hardened" >/dev/null
fi

# --- 9d. Pi-compatible header pinmux overlay (hardware-verified live) -------
# Remaps the 40-pin header to match the Raspberry Pi family layout: SPI0 +
# meshadv-HAT control lines (pins 12/19/21/23/36/38/40) plus the user I2C bus
# (pins 3/5, matching the Pi's I2C1 position - for RTC/power-monitor HATs).
# See dts-overlay/README.md for the full derivation and the real bugs found
# testing this live (cs-gpios required, pin groups need an intermediate
# subnode, one pin per node). Compiled here on the HOST (dtc is architecture-
# independent - no need for the qemu chroot).
echo "Compiling and installing the Pi-compatible header pinmux overlay (SPI0 + I2C)..."
if ! command -v dtc >/dev/null 2>&1; then
    echo "WARNING: dtc (device-tree-compiler) not found on host - skipping header overlay. Install with: sudo apt-get install -y device-tree-compiler"
else
    dtc -@ -I dts -O dtb \
        -o "$WORK/lyra-zero-w-pi-header.dtbo" \
        "$HERE/dts-overlay/lyra-zero-w-pi-header.dts"
    mkdir -p "$MNT/boot/overlay-user"
    cp "$WORK/lyra-zero-w-pi-header.dtbo" "$MNT/boot/overlay-user/lyra-zero-w-pi-header.dtbo"
    if grep -q '^user_overlays=' "$MNT/boot/armbianEnv.txt" 2>/dev/null; then
        sed -i 's/^user_overlays=.*/&  lyra-zero-w-pi-header/; s/^user_overlays=  /user_overlays=/' "$MNT/boot/armbianEnv.txt"
    else
        echo "user_overlays=lyra-zero-w-pi-header" >> "$MNT/boot/armbianEnv.txt"
    fi
fi

# --- 10. Hostname -------------------------------------------------------------
echo "lyra-node" > "$MNT/etc/hostname"
sed -i 's/127.0.1.1.*/127.0.1.1\tlyra-node/; s/luckfox-lyra-zero-w/lyra-node/g' "$MNT/etc/hosts" 2>/dev/null || true

# --- 11. Fix ping capability (known qemu-chroot issue) -----------------------
chroot_run "setcap cap_net_raw+ep /bin/ping || true"

# --- 12. Ownership + cleanup ---------------------------------------------------
chroot_run "chown -R lyra:lyra /home/lyra"
rm -f "$MNT/usr/bin/qemu-arm-static"

echo "Unmounting..."
umount "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys"
umount "$MNT"
losetup -d "$LOOPDEV"
trap - EXIT

cp "$IMAGE_RAW" "$OUT/lyra-gold.img"
echo "Done. Output image: $OUT/lyra-gold.img"
echo "Flash with: sudo dd if=$OUT/lyra-gold.img of=/dev/sdX bs=4M status=progress conv=fsync"
