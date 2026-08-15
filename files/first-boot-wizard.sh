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
    echo "Wiping any pre-existing Reticulum/NomadNet/rngit/telemetry/retibbs identities..."
    rm -f /home/lyra/.reticulum/storage/identity 2>/dev/null || true
    rm -rf /home/lyra/.reticulum/storage/destination_table 2>/dev/null || true
    rm -f /home/lyra/.nomadnetwork/storage/identity 2>/dev/null || true
    rm -f /home/lyra/.rngit/client_identity /home/lyra/.rngit/repositories_identity 2>/dev/null || true
    # telemetry-collector + RetiBBS identities (baked apps; must not share hashes across cards)
    rm -f /home/lyra/.telemetry-collector/identity 2>/dev/null || true
    rm -f /home/lyra/.telemetry-collector/state.json 2>/dev/null || true
    rm -rf /home/lyra/.telemetry-collector/lxmf_storage 2>/dev/null || true
    rm -f /home/lyra/.retibbs/identity.pem 2>/dev/null || true
    runuser -u lyra -- /usr/local/bin/rrcd --configdir /home/lyra/.reticulum --hub-name "The Spot" --greeting "Welcome to The Spot's chat lounge." >/dev/null 2>&1 || true
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

# Apply the chosen HAT (writes lyra-hardware.conf, updates RNS config if
# needed, and runs lyra-hat-pinmux apply to switch /boot/armbianEnv.txt's
# user_overlays). $1 is the chosen HAT key (e.g. "meshadv-pi-hat-v1.1" or
# "station-g3"); $2 is the RNS radio_board name to write (same key in
# practice); $3 is the pinmux-overlay profile name to apply
# ("meshadv" or "station-g3"). Echoes the chosen radio_board name.
apply_hat_choice() {
    local choice="$1"          # wizard key, used as radio_board
    local rns_rb="$2"          # alias for radio_board line (same here)
    local pinmux_profile="$3"  # pinmux profile to apply

    if [ -z "$choice" ]; then
        choice="meshadv-pi-hat-v1.1"
        rns_rb="meshadv-pi-hat-v1.1"
        pinmux_profile="meshadv"
    fi

    echo "board=lyra-zero-w" > /etc/lyra-hardware.conf
    echo "hat=$choice"        >> /etc/lyra-hardware.conf
    echo "radio_board=$choice" >> /etc/lyra-hardware.conf

    # Update /home/lyra/.reticulum/config's [[SX126xInterface]] radio_board
    # line if present (preserving pin_cs=-1 and any other keys - sed updates
    # only the radio_board value, doesn't invent a block if missing).
    if [ -f /home/lyra/.reticulum/config ] && grep -q '^[[:space:]]*radio_board[[:space:]]*=' /home/lyra/.reticulum/config; then
        sed -i "s/^\([[:space:]]*\)radio_board[[:space:]]*=.*/\\1radio_board = ${rns_rb}/" /home/lyra/.reticulum/config
        chown lyra:lyra /home/lyra/.reticulum/config
    fi

    # Apply the pinmux overlay switch (writes /boot/armbianEnv.txt and sets
    # a reboot-required flag). Must be root - the wizard is invoked
    # interactively from a root shell (sudo lyra-setup), so this is fine.
    local pinmux_ran=0
    if [ -x /usr/local/sbin/lyra-hat-pinmux ]; then
        if /usr/local/sbin/lyra-hat-pinmux apply "$pinmux_profile"; then
            pinmux_ran=1
        fi
    fi

    if [ "$pinmux_ran" -eq 1 ]; then
        dialog --clear --backtitle "Lyra first-boot setup" --title "Reboot required" --msgbox "\
Pinmux overlay updated to ${choice}. The LoRa radio will not be wired correctly\n\
until you REBOOT, even though the rest of this wizard is finishing now.\n\
\n\
Reboot now (or manually) before relying on LoRa to avoid driving pin16 in\n\
the wrong direction." 11 70
        clear
    fi

    echo "$choice"
}

# Map a wizard HAT key to the lyra-hat-pinmux profile name.
pinmux_profile_for_hat() {
    printf '%s' "$1" | sed -E 's/meshadv-pi-hat.*/meshadv/; s/station[-_]g3.*/station-g3/'
}

if [ "$MODE" = "reticulum" ]; then
    BOARD=$(dialog --clear --menu "Select board:" 12 60 1 \
        "lyra-zero-w" "Luckfox Lyra Zero W" \
        3>&1 1>&2 2>&3) || BOARD="lyra-zero-w"
    clear
    # Both HATs share the SPI0+I2C pinout, only the LoRa control lines differ.
    # pin16 direction is the discriminator - switching requires rebooting
    # and is handled by /usr/local/sbin/lyra-hat-pinmux.
    HAT=$(dialog --clear --menu "Select LoRa HAT:" \
        14 78 2 \
        "meshadv-pi-hat-v1.1" "MeshAdv Pi HAT v1.1 (+ optional GPS PPS on pin 16)" \
        "station-g3"         "BQ/Uniteng Station G3 (pin16 = RXEN - different overlay)" \
        3>&1 1>&2 2>&3) || HAT="meshadv-pi-hat-v1.1"
    clear
    HAT=$(apply_hat_choice "$HAT" "$HAT" "$(pinmux_profile_for_hat "$HAT")")
    echo "board=$BOARD hat=$HAT -> /etc/lyra-hardware.conf written; Reticulum radio_board updated"

    # --- rnsh remote-shell access -------------------------------------
    # rnsh's allowlist is empty by default (accepts no connections at
    # all until a hash is added), so ask now if the operator wants to
    # seed it - this is the only point in setup where an interactive
    # human is guaranteed to be present to type a hash in. Skippable;
    # a hash can always be added later with:
    #   echo <hash> >> /home/lyra/.rnsh/allowed_identities
    if dialog --yesno "Enable remote shell access (rnsh) now? This lets you SSH-like into this node over Reticulum from a specific client identity - useful for nodes with no other network access (e.g. LoRa-only field deployments). You'll need your client's rnsh identity hash (run 'rnsh -p' on your own machine to get it)." 12 74 2>&1 >/dev/tty; then
        clear
        CLIENT_HASH=$(dialog --inputbox "Client identity hash to allow (32 hex chars, from 'rnsh -p' on your machine). Leave blank to skip and add one later." 10 70 3>&1 1>&2 2>&3) || CLIENT_HASH=""
        clear
        if [ -n "$CLIENT_HASH" ]; then
            if [[ "$CLIENT_HASH" =~ ^[0-9a-fA-F]{32}$ ]]; then
                echo "$CLIENT_HASH" >> /home/lyra/.rnsh/allowed_identities
                chown lyra:lyra /home/lyra/.rnsh/allowed_identities
                echo "Added $CLIENT_HASH to /home/lyra/.rnsh/allowed_identities"
            else
                echo "WARNING: '$CLIENT_HASH' doesn't look like a valid 32-hex-char identity hash - not added. Add it manually later if needed."
            fi
        else
            echo "No client hash provided - rnsh will refuse all connections until you add one:"
            echo "  echo <hash> >> /home/lyra/.rnsh/allowed_identities"
        fi
    fi

    systemctl enable --now reticulum-mesh.service
    # Children are started only via reticulum-mesh-ctl (ordered bringup).
    systemctl disable nomadnet.service rngit.service rrcd.service telemetry-collector.service retibbs.service rnsh.service 2>/dev/null || true
    systemctl disable --now meshtasticd.service 2>/dev/null || true

    # rnsh only generates its listener identity (and therefore its
    # destination hash) on first run - wait briefly for
    # reticulum-mesh.service's oneshot startup to reach it, then show
    # the hash so the operator can record it / hand it out.
    echo "Waiting for rnsh to generate its identity..."
    RNSH_HASH=""
    for _attempt in $(seq 1 15); do
        if [ -f /home/lyra/.rnsh/identity.default ]; then
            RNSH_HASH=$(runuser -u lyra -- /usr/local/bin/rnsh --config /home/lyra/.rnsh --rnsconfig /home/lyra/.reticulum -p -l 2>/dev/null | awk -F'[<>]' '/Listening on/{print $2}')
            [ -n "$RNSH_HASH" ] && break
        fi
        sleep 1
    done
    if [ -n "$RNSH_HASH" ]; then
        dialog --clear --backtitle "Lyra first-boot setup" --title "rnsh remote shell address" \
            --msgbox "This node's rnsh destination hash is:\n\n  $RNSH_HASH\n\nUse this to connect from an allowed client:\n  rnsh $RNSH_HASH\n\nManage who can connect by editing:\n  /home/lyra/.rnsh/allowed_identities" 14 70
        clear
    else
        echo "NOTE: could not read the rnsh destination hash yet - check later with:"
        echo "  rnsh --config /home/lyra/.rnsh --rnsconfig /home/lyra/.reticulum -p -l"
    fi
elif [ "$MODE" = "meshtastic" ]; then
    # Meshtastic mode still benefits from a sensible default pinmux overlay
    # for whichever HAT the user is running. Offer the same choice so a
    # future LoRa-capable Meshtastic build doesn't need its own wizard path.
    HAT=$(dialog --clear --menu "Select LoRa HAT (Meshtastic mode):" \
        14 78 2 \
        "meshadv-pi-hat-v1.1" "MeshAdv Pi HAT v1.1 (+ optional GPS PPS on pin 16)" \
        "station-g3"         "BQ/Uniteng Station G3 (pin16 = RXEN - different overlay)" \
        3>&1 1>&2 2>&3) || HAT="meshadv-pi-hat-v1.1"
    clear
    HAT=$(apply_hat_choice "$HAT" "$HAT" "$(pinmux_profile_for_hat "$HAT")")
    echo "board=lyra-zero-w hat=$HAT -> /etc/lyra-hardware.conf written; Meshtastic HAT selected"
    systemctl disable --now reticulum-mesh.service
    systemctl disable nomadnet.service rngit.service rrcd.service telemetry-collector.service retibbs.service rnsh.service 2>/dev/null || true
    systemctl enable --now meshtasticd.service
fi

date -Iseconds > "$MARKER_WIZARD"
echo ""
echo "Setup complete. This wizard won't run again (remove $MARKER_WIZARD + reboot to re-run)."
echo ""
echo "=== Default login is lyra:lyra - please set your own password now. ==="
passwd lyra || echo "Password change skipped/failed - run 'sudo passwd lyra' later."
