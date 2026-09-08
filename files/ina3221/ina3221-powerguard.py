#!/usr/bin/env python3
"""Battery soft-stop / restore for solar Lyras (no OS poweroff).

Two-stage hysteresis on the INA channel labeled "bat" (configurable):
  - bat <= stop_v for N consecutive polls  → stop reticulum-mesh + sync
  - bat >= restore_v for N consecutive polls → start reticulum-mesh again

Never calls poweroff/halt/shutdown. The charge board UVLO still kills power
when empty; when sun returns the board restores power and this unit restarts
the mesh if voltage is healthy.

Run as root (systemd oneshot). Safe if INA absent (exits 0).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from read_ina3221 import load_config, read_channels, write_cache

DEFAULT_CONFIG = Path(__file__).resolve().parent / "config.json"
DEFAULT_STATE = Path("/var/lib/lyra/ina3221-powerguard.state")
MESH_UNIT = "reticulum-mesh.service"
MESH_CTL = "/usr/local/bin/reticulum-mesh-ctl"
LOG_TAG = "ina3221-powerguard"


def log(msg: str) -> None:
    line = f"{LOG_TAG}: {msg}"
    print(line, flush=True)
    try:
        subprocess.run(
            ["logger", "-t", LOG_TAG, msg],
            check=False,
            timeout=5,
        )
    except Exception:
        pass


def _defaults(cfg: dict) -> dict:
    pg = dict(cfg.get("powerguard") or {})
    return {
        "enabled": bool(pg.get("enabled", True)),
        "bat_label": str(pg.get("bat_label") or "bat"),
        # Loaded pack often hit ~2.8V before crash; 3.2V cut useful dusk runtime.
        "stop_v": float(pg.get("stop_v", 3.0)),
        "restore_v": float(pg.get("restore_v", 3.4)),
        "stop_samples": int(pg.get("stop_samples", 2)),
        "restore_samples": int(pg.get("restore_samples", 2)),
        "state_path": Path(
            pg.get("state_path")
            or cfg.get("powerguard_state_path")
            or DEFAULT_STATE
        ),
        "mesh_unit": str(pg.get("mesh_unit") or MESH_UNIT),
        # Keep MOTD/cache alive while mesh is stopped.
        "update_cache": bool(pg.get("update_cache", True)),
    }


def load_state(path: Path) -> dict:
    if not path.is_file():
        return {
            "mode": "running",  # running | stopped
            "low_streak": 0,
            "high_streak": 0,
            "last_v": None,
            "last_action": None,
            "last_ts": None,
        }
    try:
        with open(path) as f:
            st = json.load(f)
        st.setdefault("mode", "running")
        st.setdefault("low_streak", 0)
        st.setdefault("high_streak", 0)
        return st
    except Exception as e:
        log(f"state load failed ({e}); resetting")
        return {
            "mode": "running",
            "low_streak": 0,
            "high_streak": 0,
            "last_v": None,
            "last_action": None,
            "last_ts": None,
        }


def save_state(path: Path, st: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    st["last_ts"] = time.time()
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w") as f:
        json.dump(st, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def bat_voltage(reading: dict, label: str) -> float | None:
    for ch in reading.get("channels") or []:
        if str(ch.get("label", "")).lower() == label.lower():
            try:
                return float(ch["v"])
            except (KeyError, TypeError, ValueError):
                return None
    return None


def mesh_is_active(unit: str) -> bool:
    r = subprocess.run(
        ["systemctl", "is-active", "--quiet", unit],
        check=False,
    )
    return r.returncode == 0


def stop_mesh(unit: str) -> None:
    log(f"stopping mesh ({unit}) — battery soft-stop (no OS poweroff)")
    # Prefer unit stop so RemainAfterExit + ExecStop run mesh-ctl stop.
    r = subprocess.run(
        ["systemctl", "stop", unit],
        check=False,
        capture_output=True,
        text=True,
        timeout=90,
    )
    if r.returncode != 0:
        log(f"systemctl stop {unit} rc={r.returncode}: {r.stderr.strip()}")
        if Path(MESH_CTL).is_file():
            subprocess.run([MESH_CTL, "stop"], check=False, timeout=90)
    # Flush FS before charge board may cut power.
    subprocess.run(["sync"], check=False, timeout=30)
    try:
        with open("/proc/sys/vm/drop_caches", "w") as f:
            f.write("1\n")
    except OSError:
        pass
    subprocess.run(["sync"], check=False, timeout=30)
    log("mesh stopped; filesystems synced (board UVLO may still kill power)")


def start_mesh(unit: str) -> None:
    log(f"starting mesh ({unit}) — battery restored")
    r = subprocess.run(
        ["systemctl", "start", unit],
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if r.returncode != 0:
        log(f"systemctl start {unit} rc={r.returncode}: {r.stderr.strip()}")
        if Path(MESH_CTL).is_file():
            subprocess.run([MESH_CTL, "start"], check=False, timeout=120)
    log("mesh start requested")


def run_once(cfg_path: Path, dry_run: bool = False) -> int:
    cfg = load_config(cfg_path)
    pg = _defaults(cfg)
    if not pg["enabled"]:
        log("disabled in config")
        return 0

    if pg["stop_v"] >= pg["restore_v"]:
        log(
            f"invalid thresholds stop_v={pg['stop_v']} >= restore_v={pg['restore_v']}"
        )
        return 2

    try:
        reading = read_channels(cfg)
    except Exception as e:
        log(f"INA read failed (no action): {e}")
        return 0

    v = bat_voltage(reading, pg["bat_label"])
    if v is None:
        labels = [c.get("label") for c in reading.get("channels") or []]
        log(f"no channel label={pg['bat_label']!r} in {labels}; no action")
        return 0

    st = load_state(pg["state_path"])
    st["last_v"] = v
    mode = st.get("mode") or "running"

    # Reconcile mode with actual unit if state drifted after reboot.
    active = mesh_is_active(pg["mesh_unit"])
    if mode == "stopped" and active:
        # User or boot brought mesh back while state said stopped.
        mode = "running"
        st["mode"] = "running"
        st["low_streak"] = 0
    elif mode == "running" and not active and st.get("last_action") == "stop":
        # Stay stopped until restore hysteresis met.
        pass

    log(
        f"bat={v:.3f}V mode={mode} "
        f"stop<={pg['stop_v']} restore>={pg['restore_v']} "
        f"mesh_active={active}"
    )

    def finish(final_mode: str) -> int:
        st["mode"] = final_mode
        save_state(pg["state_path"], st)
        if pg["update_cache"]:
            try:
                cache = Path(
                    cfg.get("cache_path")
                    or (Path.home() / ".cache" / "ina3221.json")
                )
                annotated = dict(reading)
                annotated["powerguard_mode"] = final_mode
                annotated["powerguard_bat_v"] = v
                annotated["powerguard_stop_v"] = pg["stop_v"]
                annotated["powerguard_restore_v"] = pg["restore_v"]
                write_cache(annotated, cache)
                if str(cache).startswith("/home/lyra"):
                    try:
                        os.chown(cache, 1000, 1000)  # lyra typical uid
                    except OSError:
                        pass
            except Exception as e:
                log(f"cache update failed: {e}")
        return 0

    if mode != "stopped":
        # Looking for low battery → stop
        if v <= pg["stop_v"]:
            st["low_streak"] = int(st.get("low_streak") or 0) + 1
            st["high_streak"] = 0
        else:
            st["low_streak"] = 0

        if st["low_streak"] >= pg["stop_samples"]:
            if dry_run:
                log(f"DRY-RUN would STOP mesh at bat={v:.3f}V")
                return finish("running")
            stop_mesh(pg["mesh_unit"])
            st["last_action"] = "stop"
            st["low_streak"] = 0
            st["high_streak"] = 0
            return finish("stopped")

        return finish("running")

    # mode == stopped — looking for restore
    if v >= pg["restore_v"]:
        st["high_streak"] = int(st.get("high_streak") or 0) + 1
        st["low_streak"] = 0
    else:
        st["high_streak"] = 0

    if st["high_streak"] >= pg["restore_samples"]:
        if dry_run:
            log(f"DRY-RUN would START mesh at bat={v:.3f}V")
            return finish("stopped")
        start_mesh(pg["mesh_unit"])
        st["last_action"] = "start"
        st["high_streak"] = 0
        st["low_streak"] = 0
        return finish("running")

    return finish("stopped")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="INA3221 battery soft-stop powerguard")
    ap.add_argument("-c", "--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true", help="print state + bat and exit")
    args = ap.parse_args(argv)

    if os.geteuid() != 0 and not args.status and not args.dry_run:
        log("must run as root (systemd unit)")
        return 1

    if args.status:
        cfg = load_config(args.config)
        pg = _defaults(cfg)
        st = load_state(pg["state_path"])
        try:
            reading = read_channels(cfg)
            v = bat_voltage(reading, pg["bat_label"])
        except Exception as e:
            v = None
            print(f"read_error: {e}")
        print(
            json.dumps(
                {
                    "bat_v": v,
                    "thresholds": {
                        "stop_v": pg["stop_v"],
                        "restore_v": pg["restore_v"],
                        "stop_samples": pg["stop_samples"],
                        "restore_samples": pg["restore_samples"],
                        "bat_label": pg["bat_label"],
                        "enabled": pg["enabled"],
                    },
                    "state": st,
                    "mesh_active": mesh_is_active(pg["mesh_unit"]),
                },
                indent=2,
            )
        )
        return 0

    return run_once(args.config, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
