# rnsh line-interactive mode patch

## Why

Over LoRa (e.g. SX126x SF7 ~5.5 kbps), stock `rnsh` is character-mode: every
keystroke is a mesh packet. That feels unusable (~20s to shell, ~60s for `ls`).

Upstream already has **line-interactive mode** (local echo, send on Enter).
Mid-session toggle: after a newline, type `~` then `L` (sequential, not a chord).

There is no CLI flag or default today — `line_mode = False` is hard-coded in
the initiator. This patch adds defaults **without forking rnsh**, so you stay
on stock `pip install rns` and re-apply after upgrades.

## What it adds

| Mechanism | Effect |
|-----------|--------|
| `rnsh -L <dest>` / `rnsh --line-mode <dest>` | Start this session in line mode |
| `export RNSH_LINE_MODE=1` | Default on for that shell |
| `touch ~/.rnsh/line_mode` | Default on for that user |
| `~L` (after newline) | Toggle mid-session (unchanged upstream) |

Server/listener side is unchanged — this is initiator-only.

## Apply (any machine with rns installed)

```bash
# from this directory, or after copying the script
python3 apply-rnsh-line-mode.py
python3 apply-rnsh-line-mode.py --status
rnsh -h | grep -i line

# LoRa session example
rnsh -L <rnsh-destination-hash>
```

On a Lyra (system site-packages, needs write access):

```bash
sudo python3 apply-rnsh-line-mode.py --python /usr/bin/python3
```

### After `pip install -U rns`

Upgrades replace site-packages and wipe the patch. Re-run the apply script.
Backups are kept next to each file as `*.loraspbian-line-mode.bak`.

```bash
python3 apply-rnsh-line-mode.py --undo    # restore stock from backups
```

## Design notes

- Touches only three files under `RNS/Utilities/rnsh/`: `args.py`, `rnsh.py`,
  `initiator.py`.
- Idempotent (marker `loraspbian-rnsh-line-mode`); safe to re-run.
- Compiles each file with `py_compile` after write.
- Does **not** change airtime math — line mode only batches keystrokes into
  fewer packets. Path/link setup still costs multi-second RTTs on LoRa.
- Prefer TCP (LAN hub) for interactive admin; use `-L` when you must rnsh over RF.

## Not a full fork

No separate rnsh package, no pinned RNS version, no divergent feature branch.
If upstream adds `-L` natively, `--status` will still show patched until you
`--undo` or stop re-applying; the flag help text may then duplicate — drop this
patch when upstream lands the equivalent.
