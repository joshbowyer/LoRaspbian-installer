#!/bin/bash
# Ensure onboard AIC8800 (WiFi+BT) is powered at boot.
#
# Luckfox Lyra Zero W: USB AIC is powered via BT rfkill GPIO (bt_default_poweron).
# If systemd-rfkill state under /var/lib/systemd/rfkill/ is missing, all-zero, or
# soft-blocked (e.g. after power-loss corruption), BT stays off → AIC never
# enumerates → no wlan0 → network-online hangs / no SSH.
#
# Gold image seeds these files to "0\n". This script re-heals them and unblocks.

set -euo pipefail

RFKILL_DIR=/var/lib/systemd/rfkill
mkdir -p "$RFKILL_DIR"

# Known device keys on Luckfox Lyra Zero W (vendor 6.1 + AIC8800DC USB).
KEYS=(
  "platform-wireless-bluetooth:bluetooth"
  "platform-ff780000.usb-usb-0:1.1:1.0:bluetooth"
  "platform-ff780000.usb-usb-0:1.1:wlan"
)

# Security harden may intentionally block WiFi only — respect that marker.
WIFI_BLOCKED=0
if [[ -f /etc/lyra-security-hardened ]]; then
  WIFI_BLOCKED=1
fi

heal_file() {
  local f="$1"
  local want="$2"
  # Accept only a single 0 or 1 optionally followed by newline.
  if [[ -f "$f" ]] && grep -qxE '[01]' "$f" 2>/dev/null; then
    # Already a valid single-digit state; still force desired if mismatched.
    local cur
    cur=$(tr -d '\n' <"$f" || true)
    if [[ "$cur" == "$want" ]]; then
      return 0
    fi
  fi
  # Atomic rewrite (power-loss safe-ish).
  local tmp
  tmp=$(mktemp "$RFKILL_DIR/.tmp.XXXXXX")
  printf '%s\n' "$want" >"$tmp"
  sync "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
  sync "$RFKILL_DIR" 2>/dev/null || true
}

for key in "${KEYS[@]}"; do
  want=0
  if [[ "$WIFI_BLOCKED" -eq 1 && "$key" == *":wlan" ]]; then
    want=1
  fi
  heal_file "$RFKILL_DIR/$key" "$want"
done

# Apply live unblock so GPIO powers AIC even if state restore already ran.
RFKILL_BIN=""
for c in /usr/sbin/rfkill /sbin/rfkill rfkill; do
  if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
    RFKILL_BIN=$c
    break
  fi
done

if [[ -n "$RFKILL_BIN" ]]; then
  if [[ "$WIFI_BLOCKED" -eq 1 ]]; then
    "$RFKILL_BIN" unblock bluetooth 2>/dev/null || true
    "$RFKILL_BIN" block wifi 2>/dev/null || true
  else
    "$RFKILL_BIN" unblock bluetooth 2>/dev/null || true
    "$RFKILL_BIN" unblock wifi 2>/dev/null || true
    "$RFKILL_BIN" unblock all 2>/dev/null || true
  fi
fi

# Also poke sysfs soft flags for any existing rfkill nodes (0=unblocked).
for soft in /sys/class/rfkill/*/soft; do
  [[ -e "$soft" ]] || continue
  name=$(cat "$(dirname "$soft")/name" 2>/dev/null || true)
  type=$(cat "$(dirname "$soft")/type" 2>/dev/null || true)
  if [[ "$WIFI_BLOCKED" -eq 1 && ( "$type" == "wlan" || "$name" == "phy0" ) ]]; then
    echo 1 >"$soft" 2>/dev/null || true
  else
    echo 0 >"$soft" 2>/dev/null || true
  fi
done

exit 0
