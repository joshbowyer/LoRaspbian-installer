#!/usr/bin/env python3
"""One-shot LXMF FIELD_TELEMETRY beacon (INA rails + BME env).

Snapshot SIDs (Sideband / collector compatible):
  SID_TIME, SID_TEMPERATURE, SID_HUMIDITY, SID_PRESSURE, SID_INFORMATION
Temp/humidity/pressure from BME280 when present (supersedes TMP102 for
collector). TMP102 stays in local cache/MOTD only.
INA rails remain in SID_INFORMATION free text.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from read_ina3221 import (  # noqa: E402
    DEFAULT_CONFIG,
    info_string,
    load_config,
    read_channels,
    write_cache,
)

SID_TIME = 0x01
SID_PRESSURE = 0x03
SID_TEMPERATURE = 0x07
SID_HUMIDITY = 0x08
SID_INFORMATION = 0x0F


def _msgpack_pack(obj):
    try:
        import umsgpack

        return umsgpack.packb(obj)
    except ImportError:
        import msgpack

        return msgpack.packb(obj, use_bin_type=True)


def uptime_s() -> int:
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except OSError:
        return 0


def radio_state() -> str:
    try:
        import re
        import subprocess

        out = subprocess.check_output(
            ["timeout", "4", "rnstatus"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        lines = out.splitlines()
        for i, line in enumerate(lines):
            if "SX126x" not in line:
                continue
            chunk = "\n".join(lines[i : i + 10])
            m = re.search(r"Status\s*:\s*(Up|Down)", chunk, re.I)
            if m:
                return m.group(1).lower()
        return "unknown"
    except Exception:
        return "unknown"


def ensure_identity(path: Path):
    import RNS

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        return RNS.Identity.from_file(str(path))
    ident = RNS.Identity()
    ident.to_file(str(path))
    return ident


def build_snapshot(reading: dict) -> dict:
    """SID map for FIELD_TELEMETRY. BME supersedes TMP102 for temp SIDs."""
    extra = f"up={uptime_s()}s radio={radio_state()}"
    info = info_string(reading, extra)
    snap = {
        SID_TIME: uptime_s(),
        SID_INFORMATION: info.encode("utf-8"),
    }
    # Prefer BME/BMP ambient for collector SIDs
    if reading.get("temp_c") is not None and reading.get("temp_source") not in (
        None,
        "TMP102",
    ):
        # BME/BMP present
        snap[SID_TEMPERATURE] = [float(reading["temp_c"])]
    elif reading.get("temp_c") is not None and not reading.get("bme"):
        # TMP102-only node: still useful on collector
        snap[SID_TEMPERATURE] = [float(reading["temp_c"])]

    if reading.get("humidity_pct") is not None:
        snap[SID_HUMIDITY] = [float(reading["humidity_pct"])]
    if reading.get("pressure_mbar") is not None:
        snap[SID_PRESSURE] = [float(reading["pressure_mbar"])]
    return snap


def send_telemetry(cfg: dict, reading: dict, timeout: float) -> int:
    import RNS
    import LXMF

    rnsconfig = cfg.get("rnsconfig") or str(Path.home() / ".reticulum")
    identity_path = Path(
        cfg.get("identity_path") or (Path.home() / ".ina3221" / "identity")
    )
    storage = Path(
        cfg.get("lxmf_storage") or (Path.home() / ".ina3221" / "lxmf_storage")
    )
    storage.mkdir(parents=True, exist_ok=True)

    collector_hex = cfg.get("collector") or ""
    if len(collector_hex) != 32:
        print(f"beacon: bad collector hash {collector_hex!r}", file=sys.stderr)
        return 2

    display_name = cfg.get("display_name") or "lyra3"

    reticulum = RNS.Reticulum(configdir=rnsconfig)
    identity = ensure_identity(identity_path)

    router = LXMF.LXMRouter(identity=identity, storagepath=str(storage))
    local = router.register_delivery_identity(identity, display_name=display_name)
    router.announce(local.hash)
    RNS.log(
        f"ina3221-beacon: local lxmf {RNS.prettyhexrep(local.hash)} name={display_name}"
    )

    dest_hash = bytes.fromhex(collector_hex)
    deadline = time.time() + timeout
    if not RNS.Transport.has_path(dest_hash):
        RNS.Transport.request_path(dest_hash)
        while time.time() < deadline:
            if RNS.Transport.has_path(dest_hash):
                break
            time.sleep(0.25)
        else:
            print("beacon: no path to collector within timeout", file=sys.stderr)
            return 3

    identity_to = RNS.Identity.recall(dest_hash)
    t0 = time.time()
    while identity_to is None and time.time() < t0 + 5.0:
        time.sleep(0.2)
        identity_to = RNS.Identity.recall(dest_hash)
    if identity_to is None:
        print("beacon: path ok but collector identity not recalled", file=sys.stderr)
        return 5

    destination = RNS.Destination(
        identity_to,
        RNS.Destination.OUT,
        RNS.Destination.SINGLE,
        "lxmf",
        "delivery",
    )

    snapshot = build_snapshot(reading)
    blob = _msgpack_pack(snapshot)
    info = snapshot[SID_INFORMATION]
    if isinstance(info, bytes):
        info = info.decode("utf-8", errors="replace")

    lxm = LXMF.LXMessage(
        destination,
        local,
        "",
        title="Telemetry",
        fields={LXMF.FIELD_TELEMETRY: blob},
        desired_method=LXMF.LXMessage.DIRECT,
    )

    router.handle_outbound(lxm)

    send_deadline = time.time() + min(30.0, timeout)
    while time.time() < send_deadline:
        if lxm.state == LXMF.LXMessage.DELIVERED:
            print(
                f"beacon: DELIVERED → {collector_hex} "
                f"temp={reading.get('temp_c')} src={reading.get('temp_source')} "
                f"info={info!r}"
            )
            return 0
        if lxm.state == LXMF.LXMessage.FAILED:
            print(f"beacon: FAILED state={lxm.state}", file=sys.stderr)
            return 4
        if getattr(lxm, "state", None) in (getattr(LXMF.LXMessage, "SENT", object()),):
            break
        time.sleep(0.2)

    print(
        f"beacon: outbound queued/sent → {collector_hex} "
        f"temp={reading.get('temp_c')} src={reading.get('temp_source')} "
        f"info={info!r} state={getattr(lxm, 'state', None)}"
    )
    time.sleep(2.0)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="INA+BME → LXMF telemetry beacon")
    ap.add_argument("-c", "--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--timeout", type=float, default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    cfg = load_config(args.config)
    timeout = float(
        args.timeout if args.timeout is not None else cfg.get("send_timeout_s", 90)
    )

    try:
        reading = read_channels(cfg)
    except Exception as e:
        print(f"beacon: read failed: {e}", file=sys.stderr)
        return 1

    cache = Path(cfg.get("cache_path") or (Path.home() / ".cache" / "ina3221.json"))
    write_cache(reading, cache)

    snap = build_snapshot(reading)
    info = snap[SID_INFORMATION]
    if isinstance(info, bytes):
        info = info.decode()
    print(
        f"sensors: temp={reading.get('temp_c')}C "
        f"src={reading.get('temp_source')} "
        f"RH={reading.get('humidity_pct')} "
        f"P={reading.get('pressure_mbar')} "
        f"tmp102={reading.get('tmp102_c')} "
        f"info={info!r}"
    )

    if args.dry_run:
        return 0

    return send_telemetry(cfg, reading, timeout)


if __name__ == "__main__":
    sys.exit(main())
