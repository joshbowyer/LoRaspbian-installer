# /etc/profile.d/motd-raspi.sh
# ─────────────────────────────────────────────────────────────────────────────
# Ornate colored login banner for a personal Raspberry Pi.
#   • Cyan primary, full accent palette (magenta/blue/green/gold/coral)
#   • Docker container count (running / total) as the "Services" line
#   • Portainer status chip (it manages the containers)
#   • fail2ban: currently-banned IP count for the sshd/ssh jail
#   • Standalone — no /etc/clio-env dependency (this is your personal box)
#
# INSTALL:
#   sudo cp motd-raspi.sh /etc/profile.d/
#   # (optional) silence Debian/RPi default motd noise:
#   sudo chmod -x /etc/update-motd.d/* 2>/dev/null; sudo : > /etc/motd
#
# Docker/fail2ban queries run with short timeouts and degrade gracefully, so a
# stopped daemon or a slow socket NEVER hangs your login. If `docker`/`fail2ban`
# need sudo on your box, a passwordless sudoers rule for just those two read-only
# commands keeps this snappy (see NOTE at bottom).

# --- only run for interactive shells (skip scp/rsync/cron/non-tty) ------------
case $- in
  *i*) : ;;
  *)   return 2>/dev/null || exit ;;
esac
[ -t 1 ] || { return 2>/dev/null || exit; }

# --- palette (256-color; bright/ornate) ---------------------------------------
_R=$'\033[0m'                 # reset
_B=$'\033[1m'                 # bold
_D=$'\033[2m'                 # dim
_CYAN=$'\033[38;5;51m'        # primary
_CYAN2=$'\033[38;5;44m'       # deep cyan (rule accents)
_MAG=$'\033[38;5;171m'        # magenta
_BLUE=$'\033[38;5;75m'        # sky blue
_GREEN=$'\033[38;5;84m'       # up / good
_GOLD=$'\033[38;5;220m'       # labels highlight / warn
_CORAL=$'\033[38;5;210m'      # coral (values pop)
_RED=$'\033[38;5;203m'        # down / bad
_GREY=$'\033[38;5;245m'       # dim accents
_WHITE=$'\033[38;5;255m'      # labels (bright white)
_PINK=$'\033[38;5;213m'

# --- facts --------------------------------------------------------------------
_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
_HOSTSHORT="${_HOSTNAME%%.*}"
# Exclude docker/bridge vnets: 172.16.0.0/12 (172.16–172.31.x.x) and the
# 172.17–172.20 bridges specifically, so only real LAN IPs show.
_LOCAL_IP="$(ip -4 -o addr show scope global 2>/dev/null \
  | awk '{print $4}' | cut -d/ -f1 \
  | grep -Ev '^172\.(1[6-9]|2[0-9]|3[0-1])\.' \
  | paste -sd, - )"
[ -z "$_LOCAL_IP" ] && _LOCAL_IP="n/a"

# External IPv4, cached ~10 min so repeated logins don't hit the network.
_IP_CACHE="/tmp/.raspi_pubip_cache"
_PUBIP=""
if [ -r "$_IP_CACHE" ] && [ "$(( $(date +%s) - $(stat -c %Y "$_IP_CACHE" 2>/dev/null || echo 0) ))" -lt 600 ]; then
  _PUBIP="$(cat "$_IP_CACHE" 2>/dev/null)"
fi
if [ -z "$_PUBIP" ]; then
  _PUBIP="$(curl -4 -fsS --max-time 2 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')"
  [ -n "$_PUBIP" ] && printf '%s' "$_PUBIP" > "$_IP_CACHE" 2>/dev/null
fi
[ -z "$_PUBIP" ] && _PUBIP="(unreachable)"

_UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //')"
_LOAD="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
_CPUS="$(nproc 2>/dev/null || echo '?')"
_KERNEL="$(uname -r)"
_USERS="$(who 2>/dev/null | wc -l | tr -d ' ')"
_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
[ -z "$_MODEL" ] && _MODEL="$(uname -m)"

# CPU temperature (Pi): prefer vcgencmd, fall back to thermal_zone millidegrees.
_TEMP=""
if command -v vcgencmd >/dev/null 2>&1; then
  _TEMP="$(vcgencmd measure_temp 2>/dev/null | sed -E "s/temp=([0-9.]+).*/\1°C/")"
fi
if [ -z "$_TEMP" ] && [ -r /sys/class/thermal/thermal_zone0/temp ]; then
  _t="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
  [ -n "$_t" ] && _TEMP="$(awk -v t="$_t" 'BEGIN{printf "%.1f°C", t/1000}')"
fi
[ -z "$_TEMP" ] && _TEMP="n/a"

_MEM="$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2" ("$7" avail)"}')"
_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5" used, "$4" free)"}')"

# Last login for THIS user, rendered inside the box (PAM's own "Last login:"
# line is suppressed via ~/.hushlogin — see install notes). `lastlog` shows the
# most recent prior login: time + originating host/IP.
_LASTLOG="$(lastlog -u "$USER" 2>/dev/null | awk 'NR==2{
  if ($0 ~ /\*\*Never/) { print "first login"; next }
  # columns: Username Port From Latest...  (From may be blank for local tty)
  $1=""; sub(/^ +/,""); print
}')"
[ -z "$_LASTLOG" ] && _LASTLOG="n/a"

# --- rngit + nomadnet: shared Reticulum instance + NomadNet client ------------
# `systemctl is-active <unit>` is a regular D-Bus property query and is readable
# by any user — no sudo required. Short timeouts so a stuck systemd bus never
# hangs login.
#   rngit     — owns the shared RNS instance (rngit/rngit.service). If this is
#               not active, NomadNet and any other rngit-shared clients have no
#               Reticulum to talk to.
#   nomadnet  — the LXMF messenger + page-host client that rides on top of the
#               shared instance. May be down independently of rngit (e.g. its
#               own config error) without breaking the underlying mesh.
#   meshtasticd — the parallel Meshtastic stack daemon. Only one of (rngit,
#               meshtasticd) is expected to be the active mesh mode at a time
#               — Lyra is dual-mode via `sudo lyra-setup`. If the unit file
#               doesn't exist at all, systemctl is-active returns "inactive"
#               or "unknown", which we treat as "down" (no absent concept for
#               a daemon — it's either running or it isn't).
_RNGIT_STATE="down"
_NOMADNET_STATE="down"
_MESHTASTICD_STATE="down"
_MESH_SVC_STATE="Stopped"
if command -v systemctl >/dev/null 2>&1; then
  _ra="$(timeout 5 systemctl is-active rngit 2>/dev/null)"
  [ "$_ra" = "active" ] && _RNGIT_STATE="up"
  _na="$(timeout 5 systemctl is-active nomadnet 2>/dev/null)"
  [ "$_na" = "active" ] && _NOMADNET_STATE="up"
  _ma="$(timeout 5 systemctl is-active meshtasticd 2>/dev/null)"
  [ "$_ma" = "active" ] && _MESHTASTICD_STATE="up"
  # reticulum-mesh.service is the ordered wrapper that brings up/down all of
  # rngit+nomadnet+rrcd+telemetry-collector together (see docs/18). Surface
  # it plainly here so nobody has to remember it exists.
  _rm="$(timeout 5 systemctl is-active reticulum-mesh 2>/dev/null)"
  [ "$_rm" = "active" ] && _MESH_SVC_STATE="Running"
fi

# --- rnstatus: capture the live Reticulum interface tree ----------------------
# `rnstatus` ships with rnsd (pip-installed for the running user); it normally
# lives on PATH or at ~/.local/bin/rnstatus. We do ONE cached capture here and
# reuse it for every interface lookup below. `sudo -n` falls back silently if
# the local control socket is root-owned; never prompts.
_RNSTATUS_BIN=""
if command -v rnstatus >/dev/null 2>&1; then
  _RNSTATUS_BIN="$(command -v rnstatus)"
elif [ -x "$HOME/.local/bin/rnstatus" ]; then
  _RNSTATUS_BIN="$HOME/.local/bin/rnstatus"
fi
_RNSTATUS_OUT=""
if [ -n "$_RNSTATUS_BIN" ]; then
  _RNSTATUS_OUT="$(timeout 6 "$_RNSTATUS_BIN" 2>/dev/null)"
  if [ -z "$_RNSTATUS_OUT" ] && command -v sudo >/dev/null 2>&1; then
    _RNSTATUS_OUT="$(timeout 6 sudo -n "$_RNSTATUS_BIN" 2>/dev/null)"
  fi
fi

# --- helper: parse one interface's Status out of the rnstatus dump ------------
# Usage: _iface_state "HeaderSubstring" -> prints "up"|"down"|"absent" on stdout
#   up      = interface block found, its Status line says Up
#   down    = interface block found, its Status line says Down (configured but
#             not up — e.g., SPI device missing or peer unreachable)
#   absent  = header never matched, rnstatus errored/timed out, or the
#             interface isn't registered with rnsd at all
_iface_state() {
  local hdr="$1" out="$2"
  [ -z "$out" ] && { printf 'absent\n'; return; }
  printf '%s\n' "$out" | awk -v h="$hdr" '
    index($0, h) > 0 && !found { found=1; next }
    found {
      if ($0 ~ /Status/) {
        if      ($0 ~ /Up/)        { print "up";     exit }
        else if ($0 ~ /Down/)      { print "down";   exit }
        else                       { print "absent"; exit }
      }
      # Reached the next interface header without seeing a Status line —
      # treat as absent so a malformed block never silently reports "up".
      if ($0 ~ /^[[:space:]]+[A-Za-z]+Interface([^A-Za-z]|$)/) {
        print "absent"; exit
      }
    }
    END { if (!found) print "absent" }
  '
}

_LORA_STATE="$(_iface_state 'SX126xInterface'    "$_RNSTATUS_OUT")"
_TCP_STATE="$(_iface_state 'TCPServerInterface'  "$_RNSTATUS_OUT")"

# --- chip renderers -----------------------------------------------------------
_chip() { # $1=label $2=state(up|down|absent) [$3=up-color]
  local label="$1" state="$2" upc="${3:-$_GREEN}"
  case "$state" in
    up)     printf '%s%s%s up%s'     "$upc"   "$_B" "$label" "$_R" ;;
    down)   printf '%s%s%s down%s'   "$_RED"  "$_B" "$label" "$_R" ;;
    absent) printf '%s%s%s absent%s' "$_GREY" "$_B" "$label" "$_R" ;;
  esac
}
_RNGIT_CHIP="$(_chip rngit    "$_RNGIT_STATE"    "$_CYAN")"
_NOMADNET_CHIP="$(_chip nomadnet "$_NOMADNET_STATE" "$_GOLD")"
_LORA_CHIP="$(_chip lora    "$_LORA_STATE" "$_MAG")"
_MESHTASTICD_CHIP="$(_chip meshtasticd "$_MESHTASTICD_STATE" "$_PINK")"
_TCP_CHIP="$(_chip "tcp srv" "$_TCP_STATE" "$_BLUE")"

# --- render -------------------------------------------------------------------
# Double-line box drawing for extra bougie. Cyan frame, magenta title accents.
_TOP='╔══════════════════════════════════════════════════════════════╗'
_MID='╠══════════════════════════════════════════════════════════════╣'
_BOT='╚══════════════════════════════════════════════════════════════╝'
_row() { printf '%s║%s %b%*s %s║%s\n' "$_CYAN" "$_R" "$1" 0 "" "$_CYAN" "$_R"; }

printf '\n'
printf '%s%s%s%s\n' "$_CYAN" "$_B" "$_TOP" "$_R"
# Title line — gradient-ish accents around the hostname.
printf '%s%s║%s   %s✦%s %s%s%s %s✦%s   %s%s%s\n' \
  "$_CYAN" "$_B" "$_R" \
  "$_GOLD" "$_R" \
  "$_MAG$_B" "$_HOSTSHORT" "$_R" \
  "$_GOLD" "$_R" \
  "$_D$_PINK" "$_MODEL" "$_R"
printf '%s%s%s%s\n' "$_CYAN" "$_B" "$_MID" "$_R"

_kv() { # $1=label $2=value [$3=value-color]
  local vc="${3:-$_CORAL}"
  printf '%s%s║%s  %s%-10s%s %s%s%s\n' "$_CYAN" "$_B" "$_R" "$_WHITE" "$1" "$_R" "$vc" "$2" "$_R"
}

_kv "Public IP" "$_PUBIP"    "$_MAG$_B"
_kv "Local IP"  "$_LOCAL_IP" "$_CYAN"
_kv "Kernel"    "$_KERNEL"   "$_BLUE"
_kv "Uptime"    "$_UPTIME"   "$_GREEN"
_kv "Load"      "$_LOAD  ${_D}(${_CPUS} CPUs)${_R}${_CORAL}" "$_CORAL"
_kv "CPU Temp"  "$_TEMP"     "$_GOLD"
_kv "Memory"    "$_MEM"      "$_CORAL"
_kv "Disk"      "$_DISK"     "$_CORAL"
_kv "Sessions"  "$_USERS user(s) logged in" "$_BLUE"

printf '%s%s║%s  %s%-10s%s %s%s%s\n' \
  "$_CYAN" "$_B" "$_R" "$_WHITE" "Last Login" "$_R" "$_D$_PINK" "$_LASTLOG" "$_R"
printf '%s%s%s%s\n' "$_CYAN" "$_B" "$_MID" "$_R"
# Mesh stack line: the reticulum-mesh.service wrapper owns ordered bringup/
# teardown of rngit+nomadnet+rrcd+telemetry-collector (see docs/18). Shown
# plainly so nobody has to remember/discover it — just `systemctl
# restart|stop|start reticulum-mesh` for the whole stack.
_MESH_SVC_COLOR="$_RED"; [ "$_MESH_SVC_STATE" = "Running" ] && _MESH_SVC_COLOR="$_GREEN"
printf '%s%s║%s  %s%-10s%s %sreticulum-mesh.service %s%s%s\n' \
  "$_CYAN" "$_B" "$_R" "$_WHITE" "Mesh Stack" "$_R" "$_D" "$_MESH_SVC_COLOR$_B" "$_MESH_SVC_STATE" "$_R"
# Reticulum line: rngit (shared instance) + nomadnet (LXMF client) + LoRa radio.
printf '%s%s║%s  %s%-10s%s %s %s|%s %s %s|%s %s\n' \
  "$_CYAN" "$_B" "$_R" "$_WHITE" "Reticulum" "$_R" \
  "$_RNGIT_CHIP" "$_GREY" "$_R" "$_NOMADNET_CHIP" "$_GREY" "$_R" "$_LORA_CHIP"
# Meshtastic line: parallel Meshtastic stack daemon (one of rngit/meshtasticd
# is the active mesh mode on this dual-mode board).
printf '%s%s║%s  %s%-10s%s %s\n' \
  "$_CYAN" "$_B" "$_R" "$_WHITE" "Meshtastic" "$_R" "$_MESHTASTICD_CHIP"
# Interfaces line: TCP Server interface status (LAN-side Reticulum listener).
printf '%s%s║%s  %s%-10s%s %s\n' \
  "$_CYAN" "$_B" "$_R" "$_WHITE" "Interfaces" "$_R" "$_TCP_CHIP"
printf '%s%s%s%s\n' "$_CYAN" "$_B" "$_BOT" "$_R"
printf '\n'

# --- cleanup ------------------------------------------------------------------
unset _R _B _D _CYAN _CYAN2 _MAG _BLUE _GREEN _GOLD _CORAL _RED _GREY _WHITE _PINK _LASTLOG \
      _HOSTNAME _HOSTSHORT _LOCAL_IP _PUBIP _UPTIME _LOAD _CPUS _KERNEL _USERS \
      _MODEL _TEMP _MEM _DISK _IP_CACHE _t _run_ids _rc \
      _ra _na _ma _RNGIT_STATE _NOMADNET_STATE _MESHTASTICD_STATE _LORA_STATE _TCP_STATE \
      _RNSTATUS_BIN _RNSTATUS_OUT \
      _RNGIT_CHIP _NOMADNET_CHIP _LORA_CHIP _MESHTASTICD_CHIP _TCP_CHIP _TOP _MID _BOT
unset -f _iface_state _chip _kv _row 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# NOTE on sudo: docker + fail2ban-client often need root/socket access. This
# script tries the plain command first and only falls back to `sudo -n` (non-
# interactive — never prompts). To make the chips populate without you being in
# the docker group / running as root, add a read-only sudoers drop-in, e.g.:
#
#   # /etc/sudoers.d/motd-readonly   (chmod 440, edit via visudo -f)
#   youruser ALL=(root) NOPASSWD: /usr/bin/docker info, /usr/bin/docker ps *, \
#                                 /usr/bin/fail2ban-client status *
#
# Adjust binary paths to match `command -v docker` / `command -v fail2ban-client`.
# ─────────────────────────────────────────────────────────────────────────────
