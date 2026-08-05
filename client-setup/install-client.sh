#!/bin/bash
# Install the client-side dependencies needed to USE a Lyra node's services
# (rngit git hosting, NomadNet Micron pages, RRC chat hub, the telemetry
# collector's LXMF feed) from a regular Linux computer - without needing
# local LoRa hardware.
#
# What this installs:
#   - pip (into a user-owned venv at $HOME/.local/share/lyra-client-venv,
#     with executable symlinks under $HOME/.local/bin):
#       rns lxmf nomadnet git-remote-rns
#   - apt: git (always), i2pd (only if I2P mode is selected, since i2pd is
#     only needed to talk to Lyra's I2PInterface over a local SAM bridge)
#   - $HOME/.reticulum/config with a chosen interface block (TCPClient to
#     Lyra on LAN, I2PInterface to Lyra's b32, or both)
#   - /etc/i2pd/i2pd.conf: SAM bridge enabled (only when i2p mode selected)
#
# Connection modes (selectable via env or prompt):
#   lan  : TCPClientInterface to LYRA_HOST:4242 (default LYRA_HOST=lyra.local)
#   i2p  : I2PInterface (non-connectable client) with peers=<Lyra b32>
#          (default b32 = Lyra's real public b32)
#   both : enable both interface blocks simultaneously
#
# Does NOT require root except for the apt-get install step (uses sudo only
# there, not as a script-wide prefix). Most of this is user-level pip
# installs and editing $HOME/.reticulum/config.
#
# Idempotent: re-running just no-ops for things that are already installed
# or already configured. Safe to re-run after editing Lyra's I2P b32, etc.
#
# Run as:
#   ./install-client.sh                                   # interactive prompt
#   LYRA_MODE=both ./install-client.sh                    # non-interactive
#   LYRA_MODE=i2p LYRA_I2P_B32=foo.b32.i2p ./install-client.sh
#   ./install-client.sh -y                                # accept all defaults
#   ./install-client.sh --help

set -euo pipefail

# ----------------------------------------------------------------------------
# CLI / env parsing
# ----------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
YES_ALL=""
PRINT_HELP=""

print_help() {
    sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)        YES_ALL=1; shift ;;
        -h|--help|help)  PRINT_HELP=1; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Try: $SCRIPT_NAME --help" >&2
            exit 2
            ;;
    esac
done

if [ -n "$PRINT_HELP" ]; then
    print_help
fi

# Prompt helper: only prompts when on a TTY AND -y/--yes wasn't passed AND
# the env var isn't already set. Lets the same script work both
# interactively and in CI/automation.
prompt_or_default() {
    # $1 = prompt string, $2 = variable name to set, $3 = default value
    local _prompt="$1"
    local _var="$2"
    local _default="$3"
    if [ -n "${!_var:-}" ]; then
        # Already set via env - keep it
        :
    elif [ -n "$YES_ALL" ] || [ ! -t 0 ]; then
        printf -v "$_var" '%s' "$_default"
    else
        # -i gives a default in readline, but we don't want to require bash
        # 4+ for that; keep it portable.
        local _answer
        read -r -p "$_prompt [$_default]: " _answer
        if [ -z "$_answer" ]; then
            printf -v "$_var" '%s' "$_default"
        else
            printf -v "$_var" '%s' "$_answer"
        fi
    fi
}

# ----------------------------------------------------------------------------
# OS / architecture / package-manager detection
# ----------------------------------------------------------------------------

if [ "$(uname -s)" != "Linux" ]; then
    echo "This installer targets Linux only (tested on Debian/Ubuntu; best-effort" >&2
    echo "support for Fedora/Arch via dnf/pacman fallbacks). Detected:" >&2
    echo "  uname -s = $(uname -s)" >&2
    exit 1
fi

# uname -m -> our display labels (only used for logging; install path is
# arch-agnostic because pip packages are pure-Python and i2pd is published
# in Debian trixie main for amd64+arm64+armhf+more, verified 2026-08-05).
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    x86_64)  DISPLAY_ARCH="x86_64" ;;
    aarch64) DISPLAY_ARCH="arm64"  ;;
    armv7l|armv7) DISPLAY_ARCH="armhf" ;;
    *)
        DISPLAY_ARCH="$RAW_ARCH"
        echo "WARNING: uname -m=$RAW_ARCH is not in the x86_64/arm64/armhf trio this" >&2
        echo "         script was tested against. pip packages are pure-Python so" >&2
        echo "         should still work; i2pd availability depends on your distro." >&2
        ;;
esac
echo "Detected architecture: $DISPLAY_ARCH ($RAW_ARCH)"

PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
else
    echo "ERROR: no supported package manager found (need apt-get, dnf, or pacman)." >&2
    exit 1
fi
echo "Detected package manager: $PKG_MGR"

# ----------------------------------------------------------------------------
# Mode selection (lan / i2p / both)
# ----------------------------------------------------------------------------

# LYRA_MODE: lan / i2p / both. Default 'both' for non-interactive; prompt on TTY.
if [ -z "${LYRA_MODE:-}" ] && [ -z "$YES_ALL" ] && [ -t 0 ]; then
    echo
    echo "How do you want to reach your Lyra node?"
    echo "  1 = LAN TCP only  (TCPClientInterface to LYRA_HOST:4242)"
    echo "  2 = I2P only      (I2PInterface via local i2pd SAM bridge)"
    echo "  3 = BOTH          (TCPClient + I2P; recommended if you sometimes have"
    echo "                    LAN access and want I2P as a fallback)"
    read -r -p "Choice [3]: " _mode_answer
    case "${_mode_answer:-3}" in
        1|lan)  LYRA_MODE=lan  ;;
        2|i2p)  LYRA_MODE=i2p  ;;
        3|both|*) LYRA_MODE=both ;;
    esac
elif [ -z "${LYRA_MODE:-}" ]; then
    LYRA_MODE=both
fi

case "$LYRA_MODE" in
    lan|i2p|both) ;;
    *)
        echo "ERROR: LYRA_MODE must be one of: lan, i2p, both (got: $LYRA_MODE)" >&2
        exit 2
        ;;
esac
echo "Selected connection mode: $LYRA_MODE"

# Defaults for the two sub-modes. Lyra's I2P b32 IS meant to be public (that
# is the entire point of an I2P destination address, unlike a LAN IP), so
# baking it in as the default is fine and is what users actually want by
# default. LYRA_HOST has no such default - the placeholder 'lyra.local' just
# gives a mDNS hint for networks where Lyra advertises that name; user can
# override with the real LAN IP via prompt or env.
LYRA_DEFAULT_B32="3j7pejc2hwnn4tqrl42bvnhchlqjck666efdfuip7wxsbjmmzctq.b32.i2p"
LYRA_DEFAULT_HOST="lyra.local"

if [ "$LYRA_MODE" = lan ] || [ "$LYRA_MODE" = both ]; then
    prompt_or_default "LAN host/IP of your Lyra node (TCP port is fixed at 4242)" LYRA_HOST "$LYRA_DEFAULT_HOST"
fi
if [ "$LYRA_MODE" = i2p ] || [ "$LYRA_MODE" = both ]; then
    prompt_or_default "Lyra's I2P b32 destination address" LYRA_I2P_B32 "$LYRA_DEFAULT_B32"
fi

# ----------------------------------------------------------------------------
# System packages
# ----------------------------------------------------------------------------

# We only need root for the apt-get install line; everything else is
# user-level. Detect sudo once so we can skip it cleanly on systems that
# already have it (or where the user is running as root in a container).
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "ERROR: this installer needs root only for 'apt-get install', but" >&2
        echo "you're not root and 'sudo' isn't installed. Either run as root," >&2
        echo "install sudo, or install the system packages manually first." >&2
        exit 1
    fi
fi

# Build the list of system packages we need. git is always needed (the
# git-remote-rns transport helper is invoked BY git, so git itself must be
# present - on most systems it already is, but be explicit for fresh
# minimal installs). i2pd is only needed if I2P mode is selected.
#
# Use the detected package manager's native query command so this works on
# apt / dnf / pacman systems alike (not just Debian).
pkg_installed() {
    case "$PKG_MGR" in
        apt)    dpkg -s "$1" >/dev/null 2>&1 ;;
        dnf)    rpm -q  "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
    esac
}

APT_PKGS_NEEDED=()
APT_PKGS_ALREADY=()
for _pkg in git; do
    if pkg_installed "$_pkg"; then
        APT_PKGS_ALREADY+=("$_pkg")
    else
        APT_PKGS_NEEDED+=("$_pkg")
    fi
done

if [ "$LYRA_MODE" = i2p ] || [ "$LYRA_MODE" = both ]; then
    if pkg_installed i2pd; then
        APT_PKGS_ALREADY+=("i2pd")
    else
        APT_PKGS_NEEDED+=("i2pd")
    fi
fi

if [ ${#APT_PKGS_ALREADY[@]} -gt 0 ]; then
    echo "System packages already installed: ${APT_PKGS_ALREADY[*]}"
fi

if [ ${#APT_PKGS_NEEDED[@]} -gt 0 ]; then
    echo "System packages to install: ${APT_PKGS_NEEDED[*]}"
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            $SUDO apt-get update -qq
            # shellcheck disable=SC2086
            $SUDO apt-get install -y -qq ${APT_PKGS_NEEDED[*]}
            ;;
        dnf)
            # shellcheck disable=SC2086
            $SUDO dnf install -y ${APT_PKGS_NEEDED[*]}
            ;;
        pacman)
            # shellcheck disable=SC2086
            $SUDO pacman -S --noconfirm ${APT_PKGS_NEEDED[*]}
            ;;
    esac
else
    echo "No new system packages needed."
fi

# ----------------------------------------------------------------------------
# Enable i2pd SAM bridge (only if I2P mode selected)
# ----------------------------------------------------------------------------

enable_i2pd_sam_bridge() {
    # Mirror exactly what the Lyra gold-image build does in
    # build-lyra-gold-image.sh section 7b: scope a sed to the [sam] section
    # so we only touch the SAM-bridge directive (not any other i2pd service
    # that might also have an 'enabled' key, like HTTPProxy or I2PControl).
    # The substitution normalizes BOTH 'enabled = false' (live) and
    # '# enabled = false' (commented) to 'enabled = true'.
    local _conf="/etc/i2pd/i2pd.conf"
    if [ ! -f "$_conf" ]; then
        echo "WARNING: $_conf not found; skipping SAM-bridge enable." >&2
        echo "         (If you installed i2pd via a different distro package," >&2
        echo "         enable SAM manually and restart i2pd.)" >&2
        return 0
    fi
    # Idempotent: skip if [sam] already has a live 'enabled = true'.
    if awk '/^\[sam\]/{p=1; next} /^\[/{p=0} p && /^[[:space:]]*enabled[[:space:]]*=/{v=$0} END{exit !(v ~ /^enabled[[:space:]]*=[[:space:]]*true/)}' "$_conf"; then
        echo "i2pd SAM bridge already enabled."
        return 0
    fi
    echo "Enabling i2pd SAM bridge in $_conf ..."
    # Same sed as build-lyra-gold-image.sh section 7b. Make a .bak first so
    # the user can revert if they want.
    $SUDO cp -a "$_conf" "$_conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    $SUDO sed -i '/^\[sam\]/,/^\[/ { s/^[[:space:]]*#[[:space:]]*enabled[[:space:]]*=.*/enabled = true/; s/^[[:space:]]*enabled[[:space:]]*=.*/enabled = true/; }' "$_conf"
}

if [ "$LYRA_MODE" = i2p ] || [ "$LYRA_MODE" = both ]; then
    enable_i2pd_sam_bridge
fi

# ----------------------------------------------------------------------------
# Python venv + pip packages (user-level, no sudo)
# ----------------------------------------------------------------------------

PYTHON_BIN="$(command -v python3 || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR: python3 not found on PATH." >&2
    exit 1
fi
echo "Using python3: $PYTHON_BIN ($(${PYTHON_BIN} --version 2>&1))"

VENV_DIR="${LYRA_VENV_DIR:-$HOME/.local/share/lyra-client-venv}"
mkdir -p "$(dirname "$VENV_DIR")"

if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "Creating venv at $VENV_DIR ..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# Upgrade pip inside our venv (the venv is OUR OWN, so PEP 668 doesn't
# apply - we don't need --break-system-packages here).
"$VENV_PIP" install --quiet --upgrade pip wheel

# Pip packages. Pure-Python, architecture-agnostic, so the same install
# command works on x86_64 / arm64 / armhf / etc. - hence no per-arch
# branching here, just a single install line.
PIP_PKGS=(rns lxmf nomadnet git-remote-rns)

echo "Installing pip packages into venv: ${PIP_PKGS[*]}"
# --quiet keeps the output clean; remove if debugging. No --break-system-packages
# because we're installing into our OWN venv (PEP 668 is about the system
# Python, not venvs).
"$VENV_PIP" install --quiet "${PIP_PKGS[@]}"

# Symlink executables from venv/bin into ~/.local/bin so they're on PATH
# (most distros put ~/.local/bin on PATH by default - if yours doesn't,
# add it manually; the script's final instructions will say so).
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
symlinked=()
for _tool in "$VENV_DIR/bin/"*; do
    _name="$(basename "$_tool")"
    # Skip the Python interpreter itself - users have a system python3.
    case "$_name" in
        python|python3|python3.*|pip|pip3|pip3.*|wheel|qr) continue ;;
    esac
    # Skip venv activation scripts - users activate the venv themselves if
    # they want to import RNS/LXMF from their own scripts (no need for
    # these to clutter $HOME/.local/bin). Capital-A variants like
    # Activate.ps1/Activate.fish come from venv creation on case-sensitive
    # filesystems, so use shopt for case-insensitive matching.
    shopt -s nocasematch
    case "$_name" in
        activate|activate.*) shopt -u nocasematch; continue ;;
    esac
    shopt -u nocasematch
    # Skip server-side rngit tools - the user is a CLIENT, not running an
    # rngit git host. (They ship with the rns package as a side-effect of
    # the git-remote-rns dep tree, but we don't want them shadowing
    # anything or confusing the user with server commands.)
    case "$_name" in
        rngit|rngit-web|rngcs) continue ;;
    esac
    # Skip pyserial helpers - those are useful for serial-port debugging
    # but not part of the Lyra client workflow, and would just clutter
    # ~/.local/bin.
    case "$_name" in
        cffi-*|pyserial-miniterm|pyserial-ports) continue ;;
    esac
    if [ ! -e "$LOCAL_BIN/$_name" ]; then
        ln -s "$_tool" "$LOCAL_BIN/$_name"
        symlinked+=("$_name")
    fi
done
if [ ${#symlinked[@]} -gt 0 ]; then
    echo "Linked ${#symlinked[@]} CLI tools from venv into $LOCAL_BIN:"
    printf '  %s\n' "${symlinked[@]}"
fi

# Sanity check PATH - ~/.local/bin needs to be on it for the symlinks to be
# useful in a fresh shell.
case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *)
        echo
        echo "NOTE: $LOCAL_BIN is not on your PATH. Add it to your shell rc:"
        echo "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
        echo "  or symlink the venv tools directly:"
        echo "      ln -sf \"$VENV_DIR/bin\"/* \"$LOCAL_BIN\"/   # already done above; PATH issue only"
        echo
        ;;
esac

# ----------------------------------------------------------------------------
# Generate ~/.reticulum/config
# ----------------------------------------------------------------------------

RETICULUM_DIR="$HOME/.reticulum"
RETICULUM_CFG="$RETICULUM_DIR/config"
mkdir -p "$RETICULUM_DIR"

# We REPLACE any existing [interfaces] block this script owns (i.e. any
# block named like "Lyra *") but leave everything else alone - users may
# already have hand-curated interfaces for other Reticulum peers, custom
# logging settings, transport-node config, etc. and we don't want to nuke
# that.
#
# If $RETICULUM_CFG doesn't exist at all, write a fresh one with the
# minimum [reticulum] / [logging] / [interfaces] skeleton.
#
# Idempotency: re-running this script with the same LYRA_* env will produce
# the same config blocks, and the removal-by-name step means we replace
# stale Lyra blocks rather than accumulating duplicates.

markers_present=0
if [ -f "$RETICULUM_CFG" ]; then
    # Check whether our marker line is already there (idempotency check).
    if grep -q '^# --- Lyra client-setup managed section ---$' "$RETICULUM_CFG"; then
        markers_present=1
    fi
fi

if [ "$markers_present" -eq 1 ]; then
    echo "Removing previously-managed Lyra blocks from $RETICULUM_CFG ..."
    # Strip from the start marker through (and including) the end marker.
    # Use a Python helper for multi-line range deletion because sed -i
    # pattern ranges get awkward with multi-line blocks and we want this
    # script to be reliably idempotent across sed versions.
    "$VENV_PY" - "$RETICULUM_CFG" <<'PYEOF'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
text = p.read_text()
start = re.compile(r"^# --- Lyra client-setup managed section ---\n", re.M)
end   = re.compile(r"^# --- end Lyra client-setup managed section ---\n", re.M)
m1 = start.search(text)
if not m1:
    sys.exit(0)
m2 = end.search(text, m1.end())
if not m2:
    sys.exit(0)
new = text[:m1.start()] + text[m2.end():]
# Tidy up: collapse runs of >2 blank lines to exactly 2, and strip trailing
# whitespace; also ensure the file ends with a single newline.
new = re.sub(r"\n{3,}", "\n\n", new).rstrip() + "\n"
p.write_text(new)
PYEOF
else
    echo "Creating fresh $RETICULUM_CFG ..."
    if [ ! -f "$RETICULUM_CFG" ]; then
        cat > "$RETICULUM_CFG" <<'EOF'
# Reticulum configuration - generated by LoRaspbian client-setup installer.
# Hand-edit anything below the 'managed section' markers freely; the
# installer will only touch the block between the markers on re-runs.

[reticulum]
  # Clients generally shouldn't be Transport Nodes (routing traffic for
  # other peers burns CPU and bandwidth for no benefit on a typical end-user
  # machine). Flip to Yes if you specifically want to act as a relay.
  enable_transport = No
  share_instance = Yes

[logging]
  loglevel = 4

[interfaces]
EOF
    fi
fi

# Build the Lyra-managed block to append. Use a heredoc so the values stay
# readable, and Python to do the final write so we handle quoting safely.
#
# I2PInterface peer syntax (confirmed by reading RNS source at
# /home/josh/reticulum-stack/venv/lib/python3.13/site-packages/RNS/Interfaces/I2PInterface.py
# line ~730): peers = c.as_list("peers"), and configobj's as_list() wraps a
# scalar in a single-element list - so the config syntax is just a single
# value: `peers = <b32>`. The example shipped by RNS itself
# (rnsd --exampleconfig) uses exactly that single-scalar form.

LYRA_BLOCK_FILE="$(mktemp)"
{
    printf '%s\n' "# --- Lyra client-setup managed section ---"
    printf '%s\n' "# Generated by: LoRaspbian client-setup/install-client.sh"
    printf '%s\n' "# Mode: $LYRA_MODE"
    if [ "$LYRA_MODE" = lan ] || [ "$LYRA_MODE" = both ]; then
        printf '%s\n' "# Re-edit LYRA_HOST and re-run the installer to change the LAN target."
    fi
    if [ "$LYRA_MODE" = i2p ] || [ "$LYRA_MODE" = both ]; then
        printf '%s\n' "# Re-edit LYRA_I2P_B32 and re-run the installer to change the I2P peer."
    fi
    printf '%s\n' "#"
    printf '%s\n' "# AutoInterface stays enabled so you can also discover/be discovered"
    printf '%s\n' "# by other Reticulum nodes on the local network (link-local IPv6"
    printf '%s\n' "# multicast - works without any infra, often useful on LANs)."
    printf '%s\n' "  [[Default Interface]]"
    printf '%s\n' "    type = AutoInterface"
    printf '%s\n' "    enabled = Yes"
    printf '%s\n' ""

    if [ "$LYRA_MODE" = lan ] || [ "$LYRA_MODE" = both ]; then
        printf '%s\n' "  [[Lyra TCP Client]]"
        printf '%s\n' "    type = TCPClientInterface"
        printf '%s\n' "    enabled = Yes"
        printf '%s\n' "    target_host = ${LYRA_HOST}"
        printf '%s\n' "    target_port = 4242"
        printf '%s\n' ""
    fi

    if [ "$LYRA_MODE" = i2p ] || [ "$LYRA_MODE" = both ]; then
        printf '%s\n' "  [[Lyra I2P Client]]"
        printf '%s\n' "    type = I2PInterface"
        printf '%s\n' "    enabled = True"
        printf '%s\n' "    # Client-only: do NOT advertise our I2P destination to others."
        printf '%s\n' "    connectable = False"
        printf '%s\n' "    peers = ${LYRA_I2P_B32}"
        printf '%s\n' ""
    fi

    printf '%s\n' "# --- end Lyra client-setup managed section ---"
} > "$LYRA_BLOCK_FILE"

# Append the block to the config file (or, more accurately: append after the
# last non-empty line, with a leading blank-line separator). Also make sure
# the file ends with a newline before we append.
"$VENV_PY" - "$RETICULUM_CFG" "$LYRA_BLOCK_FILE" <<'PYEOF'
import sys, pathlib
cfg = pathlib.Path(sys.argv[1])
block = pathlib.Path(sys.argv[2]).read_text()

text = cfg.read_text() if cfg.exists() else ""
# Normalize: strip trailing whitespace, ensure exactly one trailing newline.
text = text.rstrip() + "\n"
# Append with a blank-line separator between existing content and the block.
text += "\n" + block
cfg.write_text(text)
PYEOF
rm -f "$LYRA_BLOCK_FILE"
echo "Wrote Lyra interface block(s) to $RETICULUM_CFG"

# ----------------------------------------------------------------------------
# Done - print verification hints
# ----------------------------------------------------------------------------

echo
echo "================================================================"
echo "  Lyra client setup complete (mode=$LYRA_MODE, arch=$DISPLAY_ARCH)"
echo "================================================================"
echo
echo "Quick verification:"
echo "  rnstatus                       # should show at least one interface UP"
echo "  rnsd --exampleconfig >/dev/null  # sanity-check rns CLI is on PATH"
if [ "$LYRA_MODE" = lan ] || [ "$LYRA_MODE" = both ]; then
    echo "  # Try Lyra's NomadNet Micron page once a path is established:"
    echo "  nomadnet                       # TUI browser; connects to whatever it finds"
fi
if [ "$LYRA_MODE" = i2p ] || [ "$LYRA_MODE" = both ]; then
    echo "  # Start i2pd so the SAM bridge is reachable by RNS:"
    echo "  sudo systemctl enable --now i2pd"
fi
echo "  # Clone an rngit repo (Lyra-side git-over-Reticulum hosting):"
echo "  git clone rns://<destination-hash>/<path-on-lyra>"
echo
echo "Notes:"
echo "  - ~/.local/bin needs to be on PATH for the CLI tools. Most distros"
echo "    already do this; if not, add: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "  - Re-run this installer any time to update pip packages, swap modes,"
echo "    or change LYRA_HOST / LYRA_I2P_B32. The installer only rewrites the"
echo "    block between the 'Lyra client-setup managed section' markers."
echo "  - For LoRa-only Lyra deployments (no LAN/IP), this script can't help"
echo "    on its own - a client needs either an SX126x/RNode interface or"
echo "    some other shared Reticulum transport. See README.md."
echo
