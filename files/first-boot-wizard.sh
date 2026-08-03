#!/bin/bash
# Lyra gold-image first-boot setup.
#
# Two modes:
#   --noninteractive-only   (run by systemd first-boot.service, headless, safe
#                             at boot before any TTY/SSH session exists)
#       - wipes any baked-in RNS/NomadNet/rngit identities so every flashed
#         card gets its own fresh hash, never runs the dialog wizard
#
#   (no args)                (run by /etc/profile.d/00-lyra-first-boot.sh on
#                             the FIRST interactive login - SSH or console -
#                             after the identity wipe has already happened)
#       - runs the actual dialog wizard: WiFi credentials, mode (Reticulum vs
#         Meshtastic), board/HAT selection
#       - marks first-boot fully complete so it never runs again

set -euo pipefail

MARKER_IDENTITY=/etc/lyra-first-boot-identity-done
MARKER_WIZARD=/etc/lyra-first-boot-done

if [ "${1:-}" = "--noninteractive-only" ]; then
    if [ -f "$MARKER_IDENTITY" ]; then
        exit 0
    fi
    echo "Wiping any pre-existing Reticulum/NomadNet/rngit identities..."
    rm -f /home/lyra/.reticulum/storage/identity 2>/dev/null || true
    rm -rf /home/lyra/.reticulum/storage/destination_table 2>/dev/null || true
    rm -f /home/lyra/.nomadnetwork/storage/identity 2>/dev/null || true
    rm -f /home/lyra/.rngit/client_identity /home/lyra/.rngit/repositories_identity 2>/dev/null || true
    date -Iseconds > "$MARKER_IDENTITY"
    exit 0
fi

# --- Interactive wizard (runs on first login, over SSH or console) ---------
if [ -f "$MARKER_WIZARD" ]; then
    exit 0
fi

echo ""
echo "=== Welcome! This looks like a fresh Lyra node - let's set it up. ==="
echo ""

# --- WiFi ---------------------------------------------------------------
# Skip if the build-time host script already baked in credentials - only
# offer this as a fallback/reconfigure path.
if [ -f /etc/netplan/20-wifi.yaml ]; then
    echo "WiFi already configured at build time, skipping."
elif dialog --yesno "Configure WiFi now?" 7 40 2>&1 >/dev/tty; then
    SSID=$(dialog --inputbox "WiFi SSID:" 8 50 3>&1 1>&2 2>&3)
    PSK=$(dialog --insecure --passwordbox "WiFi password:" 8 50 3>&1 1>&2 2>&3)
    clear
    cat > /etc/netplan/20-wifi.yaml << EOF
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: yes
      dhcp6: no
      access-points:
        "$SSID":
          password: "$PSK"
EOF
    chmod 600 /etc/netplan/20-wifi.yaml
    netplan apply || echo "netplan apply failed - check config manually"
fi

# --- Security (unattended deployment hardening) ---------------------------
# Skip if the build-time host script already hardened the image - only offer
# this as a fallback/reconfigure path (mirrors the WiFi section above).
if [ -f /etc/lyra-security-hardened ]; then
    echo "Security hardening already applied at build time, skipping."
elif dialog --yesno "Is this node being deployed as unattended field infrastructure (relay/repeater)? If yes, this will permanently disable WiFi and the serial console, and remove any saved WiFi credentials. Choose No for a dev/test node you'll keep local access to." 12 70 2>&1 >/dev/tty; then
    clear
    echo "Hardening for unattended deployment..."
    rm -f /etc/netplan/20-wifi.yaml
    rfkill block wifi 2>/dev/null || true
    systemctl mask serial-getty@ttyS2.service 2>/dev/null || true
    systemctl stop serial-getty@ttyS2.service 2>/dev/null || true
    date -Iseconds > /etc/lyra-security-hardened
    dialog --clear --backtitle "Lyra first-boot setup" --title "Deployed node - security guide" --msgbox "\
WiFi is now disabled and the serial console is masked. A few practices worth\n\
following for unattended field nodes:\n\
\n\
- Treat this node as an anonymous, throwaway relay - do not reuse your\n\
  personal Reticulum identity on it.\n\
- Don't store LXMF mailboxes or NomadNet vault data meant for you personally\n\
  on a node you can't physically retrieve on demand.\n\
- If this node goes missing or is recovered after being out of your control,\n\
  treat it as compromised: rotate/revoke its identity from any allowlists\n\
  rather than trusting it again.\n\
- Physical security (enclosure, mounting, discretion of placement) matters\n\
  more here than anything this wizard can configure.\n\
\n\
This can be reversed manually later (re-enable WiFi with 'rfkill unblock\n\
wifi' and 'sudo systemctl unmask serial-getty@ttyS2.service') if you need\n\
local access again." 20 74
    clear
fi

# --- Mode selection -------------------------------------------------------
MODE=$(dialog --clear --backtitle "Lyra first-boot setup" \
    --title "Choose network mode" \
    --menu "This node can run Reticulum or Meshtastic (mutually exclusive for now):" \
    15 60 2 \
    "reticulum"  "Reticulum mesh (NomadNet + rngit)" \
    "meshtastic" "Meshtastic mesh (meshtasticd)" \
    3>&1 1>&2 2>&3) || MODE=reticulum
clear

if [ "$MODE" = "reticulum" ]; then
    BOARD=$(dialog --clear --menu "Select board:" 12 60 1 \
        "lyra-zero-w" "Luckfox Lyra Zero W" \
        3>&1 1>&2 2>&3) || BOARD="lyra-zero-w"
    clear
    HAT=$(dialog --clear --menu "Select LoRa HAT (pinout still in progress - this just records your choice for now):" \
        14 70 1 \
        "wio-sx1262" "Seeed Wio SX1262 (pinout TBD)" \
        3>&1 1>&2 2>&3) || HAT="wio-sx1262"
    clear
    echo "board=$BOARD" > /etc/lyra-hardware.conf
    echo "hat=$HAT" >> /etc/lyra-hardware.conf
    systemctl enable --now nomadnet.service rngit.service
    systemctl disable --now meshtasticd.service 2>/dev/null || true
elif [ "$MODE" = "meshtastic" ]; then
    systemctl disable --now nomadnet.service rngit.service
    systemctl enable --now meshtasticd.service
fi

date -Iseconds > "$MARKER_WIZARD"
echo ""
echo "Setup complete. This wizard won't run again (remove $MARKER_WIZARD + reboot to re-run)."
echo ""
echo "=== Default login is lyra:lyra - please set your own password now. ==="
passwd lyra || echo "Password change skipped/failed - run 'sudo passwd lyra' later."
