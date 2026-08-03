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

# --- 2. Loop-mount ----------------------------------------------------------
mkdir -p "$MNT"
LOOPDEV=$(losetup -Pf --show "$IMAGE_RAW")
echo "Loop device: $LOOPDEV"

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
chroot_run "export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev git i2c-tools dialog whiptail rustc cargo"

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
cp "$HERE/files/00-lyra-first-boot.sh" "$MNT/etc/profile.d/00-lyra-first-boot.sh"
chmod +x "$MNT/etc/profile.d/00-lyra-first-boot.sh"
chroot_run "systemctl enable nomadnet.service rngit.service first-boot.service"

# --- 9. Base Reticulum config (no LoRa interface yet - pinmux pending) ------
mkdir -p "$MNT/home/lyra/.reticulum"
cp "$HERE/files/reticulum-config-base" "$MNT/home/lyra/.reticulum/config"

# --- 9b. WiFi (baked in at build time, if provided above) -------------------
if [ -n "$LYRA_WIFI_SSID" ]; then
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

# --- 9c. Permanently unblock WiFi/BT rfkill soft-block -----------------------
# The aic8800 combo chip ships soft-blocked; systemd-rfkill persists whatever
# state is on disk at /var/lib/systemd/rfkill/<device> across reboots, so we
# just need to pre-seed "0" (unblocked) for the known device paths (confirmed
# live on hardware: platform-ff780000.usb-usb-0:1.1:wlan and the bluetooth
# counterparts) rather than actually calling `rfkill` here, since inside this
# qemu chroot that would touch the HOST build machine's real rfkill state, not
# the image's.
mkdir -p "$MNT/var/lib/systemd/rfkill"
for f in "platform-ff780000.usb-usb-0:1.1:1.0:bluetooth" \
         "platform-ff780000.usb-usb-0:1.1:wlan" \
         "platform-wireless-bluetooth:bluetooth"; do
    echo 0 > "$MNT/var/lib/systemd/rfkill/$f"
done

# --- 9d. LoRa HAT SPI0 pinmux overlay (hardware-verified live on the board) -
# Remaps the 40-pin header to the Pi's SPI0 + meshadv-HAT control-line layout.
# See dts-overlay/README.md for the full derivation and the 3 real bugs found
# testing this live (cs-gpios required, pin groups need an intermediate
# subnode, one pin per node). Compiled here on the HOST (dtc is architecture-
# independent - no need for the qemu chroot).
echo "Compiling and installing the LoRa HAT SPI0 pinmux overlay..."
if ! command -v dtc >/dev/null 2>&1; then
    echo "WARNING: dtc (device-tree-compiler) not found on host - skipping LoRa overlay. Install with: sudo apt-get install -y device-tree-compiler"
else
    dtc -@ -I dts -O dtb \
        -o "$WORK/lyra-zero-w-pi-spi0-lora.dtbo" \
        "$HERE/dts-overlay/lyra-zero-w-pi-spi0-lora.dts"
    mkdir -p "$MNT/boot/overlay-user"
    cp "$WORK/lyra-zero-w-pi-spi0-lora.dtbo" "$MNT/boot/overlay-user/lyra-zero-w-pi-spi0-lora.dtbo"
    if grep -q '^user_overlays=' "$MNT/boot/armbianEnv.txt" 2>/dev/null; then
        sed -i 's/^user_overlays=.*/&  lyra-zero-w-pi-spi0-lora/; s/^user_overlays=  /user_overlays=/' "$MNT/boot/armbianEnv.txt"
    else
        echo "user_overlays=lyra-zero-w-pi-spi0-lora" >> "$MNT/boot/armbianEnv.txt"
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
