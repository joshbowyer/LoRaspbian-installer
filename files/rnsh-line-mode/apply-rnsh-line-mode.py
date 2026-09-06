#!/usr/bin/env python3
"""Idempotent patch: add -L/--line-mode + RNSH_LINE_MODE + ~/.rnsh/line_mode
to the RNS-bundled rnsh initiator (RNS.Utilities.rnsh).

Does NOT fork rnsh. Re-run after `pip install -U rns` if the upgrade overwrote
site-packages. Safe to run multiple times.

Usage:
  python3 apply-rnsh-line-mode.py              # patch the active Python's rns
  python3 apply-rnsh-line-mode.py --status     # report only
  python3 apply-rnsh-line-mode.py --undo       # restore .loraspbian-line-mode.bak
  python3 apply-rnsh-line-mode.py --python /usr/bin/python3
"""
from __future__ import annotations

import argparse
import os
import py_compile
import shutil
import subprocess
import sys
from pathlib import Path

MARKER = "loraspbian-rnsh-line-mode"
BACKUP_SUFFIX = ".loraspbian-line-mode.bak"

# ---------------------------------------------------------------------------
# Patch fragments (matched/replaced as whole blocks so re-runs are no-ops)
# ---------------------------------------------------------------------------

ARGS_NEEDLE = 'parser.add_argument("-w", "--timeout"'
ARGS_FLAG = (
    '    parser.add_argument("-L", "--line-mode", action="store_true", default=False,\n'
    '                        help="start in line-interactive mode (send on Enter; '\
    'better over slow LoRa; toggle mid-session with ~L)")\n'
)

# Signature: add line_mode kw-only-ish trailing default param
INIT_SIG_OLD = (
    "async def initiate(configdir: str, rnsconfigdir:str, identitypath: str, logfile:str, "
    "verbosity: int, quietness: int, noid: bool, destination: str,\n"
    "                   timeout: float, command: [str] | None = None):"
)
INIT_SIG_NEW = (
    "async def initiate(configdir: str, rnsconfigdir:str, identitypath: str, logfile:str, "
    "verbosity: int, quietness: int, noid: bool, destination: str,\n"
    "                   timeout: float, command: [str] | None = None, "
    "line_mode: bool = False):  # " + MARKER
)

# Some installs may have slightly different spacing — also try compact form
INIT_SIG_OLD_ALT = (
    "async def initiate(configdir: str, rnsconfigdir:str, identitypath: str, logfile:str, "
    "verbosity: int, quietness: int, noid: bool, destination: str,\n"
    "                   timeout: float, command: [str] | None = None):"
)

INIT_LINE_OLD = "        line_mode = False\n"
INIT_LINE_NEW = (
    "        # " + MARKER + ": honor -L / RNSH_LINE_MODE / ~/.rnsh/line_mode\n"
    "        if not line_mode:\n"
    "            _env = os.environ.get(\"RNSH_LINE_MODE\", \"\").strip().lower()\n"
    "            if _env in (\"1\", \"true\", \"yes\", \"on\"):\n"
    "                line_mode = True\n"
    "        if not line_mode:\n"
    "            for _p in (\n"
    "                os.path.expanduser(\"~/.rnsh/line_mode\"),\n"
    "                os.path.join(configdir, \"line_mode\") if configdir else \"\",\n"
    "            ):\n"
    "                if _p and os.path.isfile(_p):\n"
    "                    line_mode = True\n"
    "                    break\n"
    "        if line_mode:\n"
    "            with contextlib.suppress(Exception):\n"
    "                os.write(1, \"\\n\\rLine-interactive mode enabled "
    "(-L / RNSH_LINE_MODE; ~L toggles)\\n\\r\".encode(\"utf-8\"))\n"
)

RNSH_CALL_OLD = (
    "        return_code = await initiator.initiate(configdir=configdir,\n"
    "                                               rnsconfigdir=args.rnsconfig,\n"
    "                                               identitypath=args.identity,\n"
    "                                               logfile=f\"{logfile}.initiator\",\n"
    "                                               verbosity=args.verbose,\n"
    "                                               quietness=args.quiet,\n"
    "                                               noid=args.no_id,\n"
    "                                               destination=args.destination,\n"
    "                                               timeout=args.timeout,\n"
    "                                               command=args.command\n"
    "        )"
)
RNSH_CALL_NEW = (
    "        return_code = await initiator.initiate(configdir=configdir,\n"
    "                                               rnsconfigdir=args.rnsconfig,\n"
    "                                               identitypath=args.identity,\n"
    "                                               logfile=f\"{logfile}.initiator\",\n"
    "                                               verbosity=args.verbose,\n"
    "                                               quietness=args.quiet,\n"
    "                                               noid=args.no_id,\n"
    "                                               destination=args.destination,\n"
    "                                               timeout=args.timeout,\n"
    "                                               command=args.command,\n"
    "                                               line_mode=bool(getattr(args, \"line_mode\", False)),  # "
    + MARKER + "\n"
    "        )"
)


def find_rnsh_dir(python: str) -> Path:
    code = (
        "import os, RNS.Utilities.rnsh as m\n"
        "p = getattr(m, '__path__', None)\n"
        "print(list(p)[0] if p else os.path.dirname(m.__file__))\n"
    )
    out = subprocess.check_output([python, "-c", code], text=True).strip()
    path = Path(out)
    if not path.is_dir():
        raise SystemExit(f"rnsh package dir not found: {path}")
    for name in ("args.py", "rnsh.py", "initiator.py"):
        if not (path / name).is_file():
            raise SystemExit(f"missing {path / name}")
    return path


def backup_once(path: Path) -> None:
    bak = Path(str(path) + BACKUP_SUFFIX)
    if not bak.exists():
        shutil.copy2(path, bak)


def already_patched(text: str) -> bool:
    return MARKER in text


def patch_args(text: str) -> str:
    if already_patched(text) or "--line-mode" in text:
        return text
    if ARGS_NEEDLE not in text:
        raise SystemExit("args.py: could not find -w/--timeout option to anchor insert")
    # Insert -L just before -w/--timeout (initiator options block)
    return text.replace(
        '    parser.add_argument("-w", "--timeout"',
        ARGS_FLAG + '    parser.add_argument("-w", "--timeout"',
        1,
    )


def patch_initiator(text: str) -> str:
    if already_patched(text):
        return text
    if "line_mode: bool = False" in text and "RNSH_LINE_MODE" in text:
        return text

    new = text
    if INIT_SIG_OLD in new:
        new = new.replace(INIT_SIG_OLD, INIT_SIG_NEW, 1)
    elif "command: [str] | None = None):" in new and "async def initiate(" in new:
        # fallback: only replace the closing of the signature once
        new = new.replace(
            "command: [str] | None = None):",
            f"command: [str] | None = None, line_mode: bool = False):  # {MARKER}",
            1,
        )
    else:
        raise SystemExit("initiator.py: could not match initiate() signature")

    if INIT_LINE_OLD not in new:
        raise SystemExit("initiator.py: could not find 'line_mode = False' assignment")
    # Only replace the first assignment (the init default), not later toggles
    new = new.replace(INIT_LINE_OLD, INIT_LINE_NEW, 1)
    return new


def patch_rnsh(text: str) -> str:
    if already_patched(text) or "line_mode=bool(getattr(args" in text:
        return text
    if RNSH_CALL_OLD in text:
        return text.replace(RNSH_CALL_OLD, RNSH_CALL_NEW, 1)
    # tolerant: command=args.command without trailing comma block
    old2 = "                                               command=args.command\n        )"
    new2 = (
        "                                               command=args.command,\n"
        f"                                               line_mode=bool(getattr(args, \"line_mode\", False)),  # {MARKER}\n"
        "        )"
    )
    if old2 in text:
        return text.replace(old2, new2, 1)
    raise SystemExit("rnsh.py: could not match initiator.initiate(...) call")


def write_patched(path: Path, new_text: str, dry_run: bool) -> bool:
    old = path.read_text(encoding="utf-8")
    if old == new_text:
        return False
    if dry_run:
        print(f"  would patch {path}")
        return True
    backup_once(path)
    path.write_text(new_text, encoding="utf-8")
    py_compile.compile(str(path), doraise=True)
    print(f"  patched {path}")
    return True


def undo(rnsh_dir: Path, dry_run: bool) -> int:
    n = 0
    for name in ("args.py", "rnsh.py", "initiator.py"):
        path = rnsh_dir / name
        bak = Path(str(path) + BACKUP_SUFFIX)
        if not bak.is_file():
            print(f"  no backup for {path.name}")
            continue
        if dry_run:
            print(f"  would restore {path}")
            n += 1
            continue
        shutil.copy2(bak, path)
        print(f"  restored {path}")
        n += 1
    return 0 if n else 1


def status(rnsh_dir: Path) -> int:
    print(f"rnsh dir: {rnsh_dir}")
    ok = True
    for name in ("args.py", "rnsh.py", "initiator.py"):
        text = (rnsh_dir / name).read_text(encoding="utf-8")
        patched = MARKER in text or (name == "args.py" and "--line-mode" in text)
        print(f"  {name}: {'PATCHED' if patched else 'stock'}")
        if not patched:
            ok = False
    return 0 if ok else 2


def apply(rnsh_dir: Path, dry_run: bool) -> int:
    print(f"rnsh dir: {rnsh_dir}")
    changed = False
    for name, fn in (
        ("args.py", patch_args),
        ("initiator.py", patch_initiator),
        ("rnsh.py", patch_rnsh),
    ):
        path = rnsh_dir / name
        old = path.read_text(encoding="utf-8")
        try:
            new = fn(old)
        except SystemExit as e:
            print(f"  FAIL {name}: {e}", file=sys.stderr)
            return 1
        if write_patched(path, new, dry_run):
            changed = True
        else:
            print(f"  ok (already patched) {path.name}")
    if not dry_run and changed:
        print("Done. Try: rnsh -h | grep -i line")
        print("  rnsh -L <dest>          # one-shot")
        print("  export RNSH_LINE_MODE=1 # default for shell")
        print("  touch ~/.rnsh/line_mode # default for user")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--python", default=sys.executable, help="Python that has rns installed")
    ap.add_argument("--rnsh-dir", default=None, help="override path to RNS/Utilities/rnsh")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--undo", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    rnsh_dir = Path(args.rnsh_dir) if args.rnsh_dir else find_rnsh_dir(args.python)

    if args.status:
        return status(rnsh_dir)
    if args.undo:
        return undo(rnsh_dir, args.dry_run)
    return apply(rnsh_dir, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
