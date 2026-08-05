# Lyra client setup

A user-side installer for connecting a regular Linux computer (x86_64 / arm64
/ armhf) to a Lyra node's Reticulum-based services — without needing any
local LoRa hardware. This is the counterpart to the `build-lyra-gold-image.sh`
in this repo, which builds the **SD card image** that runs on the Lyra node
itself; this script configures a separate machine as a **client** of that
node.

The two scripts are independent — you do **not** need to run this installer
on a Lyra gold-image card (it's already configured as a node). You run this
on your laptop / desktop / another SBC.

## What Lyra exposes, and how this script lets you use it

A Lyra node runs four Reticulum-based services behind a shared RNS instance,
reachable via three interfaces (TCP on the LAN, native I2P via a local
i2pd, and LoRa with a MeshAdv HAT — LoRa is out of scope for this client
script since you'd need the same hardware the node has):

| Service | What it is | How you use it from this client |
|---|---|---|
| **rngit** | git-over-Reticulum hosting (clone / push / browse git repos over the mesh) | `git clone rns://<dest-hash>/<repo-path>`, after `rnsd` has discovered Lyra's destination hash |
| **nomadnet** | LXMF messaging + Micron-page hosting (a TUI chat client, a wiki-style page browser, file sharing, etc) | `nomadnet` (TUI) — discover Lyra via the configured interface |
| **rrcd** | IRC-style chat hub (RRC protocol) | NomadNet has a built-in RRC client module that can connect to Lyra's rrcd |
| **telemetry-collector** | a custom LXMF listener that receives telemetry messages | Any LXMF-capable client works — NomadNet, lxmd, etc |

## What this installer does

Three things, on your machine:

1. **pip packages**, into a user-owned venv at
   `~/.local/share/lyra-client-venv` (with executable symlinks under
   `~/.local/bin`):
   - `rns` — Reticulum Network Stack daemon + utilities (`rnsd`, `rnpath`,
     `rnstatus`, `rnprobe`, `rnid`, `rnir`, `rnx`, `rnpkg`, `rnodeconf`,
     `rncp`, `rnsh`)
   - `lxmf` — LXMF messaging (`lxmd`)
   - `nomadnet` — Micron-page / chat client (`nomadnet`)
   - `git-remote-rns` — the git transport helper (`git-remote-rns`) that
     resolves `rns://...` URLs by talking to the local `rnsd`. **This is
     what makes `git clone rns://<hash>/<path>` work.**

2. **apt packages** (Debian / Ubuntu primary; best-effort `dnf` / `pacman`
   fallbacks for the same two packages):
   - `git` (always — required by `git-remote-rns`)
   - `i2pd` (only if you choose the I2P connection mode; needed to talk to
     Lyra's I2PInterface over a local SAM bridge at `127.0.0.1:7656`)

3. **`~/.reticulum/config`** — appends a managed section (delimited by
   `# --- Lyra client-setup managed section ---` markers, so re-runs
   replace cleanly without touching the rest of your config) containing:
   - Always: `[[Default Interface]]` (RNS's `AutoInterface`, for
     link-local IPv6 multicast discovery on your LAN)
   - LAN mode: `[[Lyra TCP Client]]` (`TCPClientInterface` →
     `$LYRA_HOST:4242`)
   - I2P mode: `[[Lyra I2P Client]]` (`I2PInterface`, `connectable = False`
     since you're a client not a server, with `peers = <Lyra b32>`)
   - Both modes are independent — pick either, both, or switch later

4. **`/etc/i2pd/i2pd.conf`** (only if I2P mode is chosen) — enables the
   SAM bridge in the `[sam]` section, exactly like
   `build-lyra-gold-image.sh` section 7b does on Lyra itself. Scoped sed so
   no other i2pd service's `enabled` key is touched.

You do **not** need root for anything except the `apt-get install` step;
this script uses `sudo` only there, not as a script-wide prefix.

## Quick start

```bash
cd client-setup
./install-client.sh                    # interactive prompts
# or non-interactively with sane defaults:
./install-client.sh -y                 # accept defaults (LAN=lyra.local, I2P=Lyra's real b32)
# or pre-set everything:
LYRA_MODE=both LYRA_HOST=192.168.1.50 ./install-client.sh -y
```

Re-running is safe and idempotent. Re-running with a different `LYRA_HOST`
or `LYRA_I2P_B32` cleanly replaces the previous block; re-running with the
same values is a no-op for the config (and only re-installs pip packages
that are missing / out of date).

## Connection modes

### `LYRA_MODE=lan` (TCPClient)

Adds this block to your RNS config:

```ini
[[Lyra TCP Client]]
  type = TCPClientInterface
  enabled = Yes
  target_host = <LYRA_HOST>
  target_port = 4242
```

- `LYRA_HOST` defaults to `lyra.local` (works on networks where Lyra
  advertises that mDNS name — most home LANs). Override with a real IP /
  hostname via prompt or env: `LYRA_HOST=192.168.1.50`.
- Port is fixed at **4242** (matches Lyra's `[[TCP Server on LAN]]`
  `TCPServerInterface`).
- Requires the client to be on the same IP-reachable network as Lyra
  (LAN, VPN, etc.) — Lyra's TCP server listens on `0.0.0.0:4242`.
- `git` is the only apt dependency.

### `LYRA_MODE=i2p` (I2PInterface)

Adds this block:

```ini
[[Lyra I2P Client]]
  type = I2PInterface
  enabled = True
  connectable = False      # client-only; do NOT advertise our I2P dest
  peers = <LYRA_I2P_B32>
```

- `LYRA_I2P_B32` defaults to Lyra's real public destination:
  `3j7pejc2hwnn4tqrl42bvnhchlqjck666efdfuip7wxsbjmmzctq.b32.i2p`. This is
  fine to bake in (I2P b32 addresses are designed to be public, unlike
  private LAN IPs).
- Requires `i2pd` installed and its SAM bridge enabled. The installer
  does both, and prints `sudo systemctl enable --now i2pd` as a follow-up
  step (the SAM bridge needs the i2pd daemon actually running, not just
  installed).
- Works from anywhere with internet egress — no LAN access required.
- Note: I2P tunnels take a few minutes to establish on first use, so the
  first `git clone rns://...` may show path-build retries for ~30-120s
  before succeeding.

### `LYRA_MODE=both`

Appends both blocks. Useful if you sometimes have LAN access (fast path)
and sometimes only have internet (I2P fallback) — RNS will pick whichever
works first per destination.

## Verifying it works

Once the installer finishes, start i2pd if you enabled I2P mode, then
sanity-check RNS can reach Lyra:

```bash
# 1. Make sure i2pd is running (only relevant for i2p / both modes):
sudo systemctl enable --now i2pd

# 2. Confirm RNS sees its interfaces and they're coming up:
rnstatus

# You should see entries like:
#   TCP Client [...]   : waiting for connect...
#   I2P Client [...]   : connecting to 127.0.0.1:7656 (sam)...
# once paths to Lyra are established:
#   TCP Client [...]   : <dest-hash> online via <host>
#   I2P Client [...]   : <dest-hash> online via i2p

# 3. Browse Lyra's Micron pages (requires Lyra's dest hash - usually
# discovered via rnpath within a few seconds once interfaces come up):
nomadnet
# (Use Ctrl-C to quit nomadnet)

# 4. Clone an rngit-hosted repo. Once you know Lyra's destination hash
# (shown in rnstatus / rnpath output), the git transport helper handles
# the rest automatically via the local rnsd:
git clone rns://<dest-hash>/<repo-path> my-clone
cd my-clone
git remote -v   # should show 'rns://<dest-hash>/<repo-path>'
```

If `git clone rns://...` fails with `fatal: unable to find remote helper
'rns'`, your shell session doesn't have `~/.local/bin` on `PATH` (or
`git-remote-rns` isn't on it). See "PATH" below.

## Architecture & distro coverage

- **Architectures:** the script detects `uname -m` and maps to
  `x86_64` / `arm64` / `armhf` for logging. The install path itself is
  architecture-agnostic because the four pip packages (`rns`, `lxmf`,
  `nomadnet`, `git-remote-rns`) are pure-Python, and `i2pd` is in
  Debian trixie `main` for `amd64`, `arm64`, `armel`, `armhf`, `i386`,
  `ppc64el`, `riscv64`, `s390x` (verified 2026-08-05 via the Debian
  package tracker), so it covers all three target arches plus more.
  Unknown architectures (e.g. RISC-V) are allowed through with a warning
  rather than refused — pip will still install cleanly.
- **Distros:** primary support is **Debian / Ubuntu family** (`apt-get`).
  Best-effort fallbacks for `dnf` (Fedora / RHEL) and `pacman` (Arch)
  install the same two packages (`git`, `i2pd`) via the native package
  manager; `i2pd` may or may not be in those repos depending on the
  specific distro version. The installer surfaces an error if `dnf
  install i2pd` fails, and the user can either skip I2P mode or build
  i2pd from source.
- **macOS / Windows:** not supported by this script — no apt / dnf /
  pacman, and Reticulum's native I2PInterface expects a Linux SAM
  bridge. For macOS, install Python from python.org, then use the
  equivalent commands in this script (create a venv, `pip install` the
  same four packages) plus a hand-written `~/.reticulum/config` (no
  `I2PInterface` block, since there's no SAM bridge on macOS by default).

## PATH

The pip-installed CLI tools (`nomadnet`, `git-remote-rns`, `rnsd`,
`rnstatus`, …) are symlinked into `~/.local/bin` so they appear on
`PATH` in any new shell. Most Linux distros add `~/.local/bin` to `PATH`
by default for interactive sessions; if yours doesn't, add this to your
shell rc:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Or invoke them via the venv directly:

```bash
~/.local/share/lyra-client-venv/bin/nomadnet
~/.local/share/lyra-client-venv/bin/git-remote-rns   # usually only used via git, never run directly
```

## Re-running / updating

Re-run any time. The installer is idempotent:

- Pip packages are reinstalled into the same venv (idempotent — pip
  skips up-to-date deps).
- The Reticulum config block between the `# --- Lyra client-setup
  managed section ---` markers is removed and re-appended, so changing
  `LYRA_HOST`, `LYRA_I2P_B32`, or `LYRA_MODE` cleanly replaces the
  previous block instead of duplicating it. Anything else in
  `~/.reticulum/config` is left alone.
- System packages are skipped if already installed.
- The i2pd `enabled = true` substitution is skipped if the `[sam]`
  section already has `enabled = true`.

To force a refresh of pip packages only:

```bash
~/.local/share/lyra-client-venv/bin/pip install --upgrade rns lxmf nomadnet git-remote-rns
```

## Limitations / known gaps

- **LoRa-only Lyra deployments** (no LAN, no I2P — a node with just a
  MeshAdv HAT and no other transport) can't be reached by this script:
  the client would also need its own SX126x/RNode hardware plugged in
  and tuned to the same LoRa parameters. The RNS config generated here
  intentionally does NOT include a `[[SX126x LoRa]]` block, since the
  HAT wiring / platform profile depends on the specific SBC + HAT pair
  and isn't usefully generic. If you have your own HAT, copy the
  equivalent block from Lyra's own `files/reticulum-config-base` into
  your `~/.reticulum/config` and adapt the `platform =` line.
- **No firewall / port forwarding instructions for `rnsd`.** If you're
  behind a restrictive outbound firewall, RNS may have trouble
  establishing paths. Default RNS behavior is fine for most home
  networks — the TCP and I2P modes both initiate outbound, so they
  work behind NAT.
- **No system-wide pip / `--break-system-packages` path.** Some users
  prefer installing into the system Python directly. This installer
  uses a venv because it's the most universally-clean option across
  distros (Debian PEP 668, Fedora's externally-managed Python, etc.).
  If you want the venv to survive `rm -rf $HOME/.local/share/...`,
  back it up before major Python upgrades.

## Files

- `install-client.sh` — the installer
- This README

See also: `../build-lyra-gold-image.sh` (Lyra server SD-card image
builder — different script, different purpose) and `../README.md`
(top-level project doc).
