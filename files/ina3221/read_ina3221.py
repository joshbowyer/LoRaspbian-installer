#!/usr/bin/env python3
"""Read TI INA3221 + optional TMP102/BME280. CLI + JSON + MOTD cache.

Correct INA decode: shunt/bus raw must arithmetic >> 3 before scale
(shunt 40 uV/bit, bus 8 mV/bit). See docs/21-ina3221-wiring-and-telemetry.md.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from sensors_i2c import read_env

DEFAULT_CONFIG = Path(__file__).resolve().parent / "config.json"
DEFAULT_CACHE = Path.home() / ".cache" / "ina3221.json"

REG_CONFIG = 0x00
REG_SHUNT = (0x01, 0x03, 0x05)
REG_BUS = (0x02, 0x04, 0x06)
REG_MFG = 0xFE
REG_DIE = 0xFF

MFG_TI = 0x5449
DIE_3221 = 0x3220


def _load_smbus():
    try:
        from smbus2 import SMBus  # type: ignore

        return SMBus
    except ImportError:
        pass
    try:
        from smbus import SMBus  # type: ignore

        return SMBus
    except ImportError as e:
        raise SystemExit(
            "Need python3-smbus or smbus2 (apt install python3-smbus)"
        ) from e


def load_config(path: Path) -> dict:
    cfg = {
        "bus": 0,
        "address": 0x40,
        "shunt_ohms": [0.1, 0.1, 0.1],
        "labels": ["solar", "bat", "system"],
        "cache_path": str(DEFAULT_CACHE),
        "tmp102_address": 0x48,
        "read_env_sensors": True,
    }
    if path.is_file():
        with open(path) as f:
            user = json.load(f)
        cfg.update(user)
    if isinstance(cfg["address"], str):
        cfg["address"] = int(cfg["address"], 0)
    if isinstance(cfg.get("tmp102_address"), str):
        cfg["tmp102_address"] = int(cfg["tmp102_address"], 0)
    if isinstance(cfg["shunt_ohms"], (int, float)):
        cfg["shunt_ohms"] = [float(cfg["shunt_ohms"])] * 3
    while len(cfg["shunt_ohms"]) < 3:
        cfg["shunt_ohms"].append(0.1)
    while len(cfg["labels"]) < 3:
        cfg["labels"].append(f"ch{len(cfg['labels'])+1}")
    return cfg


def _read_u16(bus, addr: int, reg: int) -> int:
    data = bus.read_i2c_block_data(addr, reg, 2)
    return (data[0] << 8) | data[1]


def _read_s16_shifted(bus, addr: int, reg: int) -> int:
    raw = _read_u16(bus, addr, reg)
    if raw & 0x8000:
        raw -= 0x10000
    return raw >> 3


def read_channels(cfg: dict) -> dict:
    SMBus = _load_smbus()
    bus_id = int(cfg["bus"])
    addr = int(cfg["address"])
    labels = list(cfg["labels"][:3])
    shunts = [float(x) for x in cfg["shunt_ohms"][:3]]

    bus = SMBus(bus_id)
    try:
        mfg = _read_u16(bus, addr, REG_MFG)
        die = _read_u16(bus, addr, REG_DIE)
        if mfg != MFG_TI or die != DIE_3221:
            raise RuntimeError(
                f"unexpected ID mfg=0x{mfg:04x} die=0x{die:04x} "
                f"(want TI/0x3220) — wrong device at 0x{addr:02x}?"
            )
        channels = []
        for i in range(3):
            shunt_lsb = _read_s16_shifted(bus, addr, REG_SHUNT[i])
            bus_lsb = _read_s16_shifted(bus, addr, REG_BUS[i])
            v_shunt = shunt_lsb * 40e-6
            v_bus = bus_lsb * 8e-3
            r = shunts[i] if shunts[i] else 0.1
            i_a = v_shunt / r
            channels.append(
                {
                    "ch": i + 1,
                    "label": labels[i],
                    "v": round(v_bus, 3),
                    "ma": round(i_a * 1000.0, 1),
                    "mw": round(v_bus * i_a * 1000.0, 1),
                    "shunt_ohms": r,
                }
            )
    finally:
        try:
            bus.close()
        except Exception:
            pass

    reading = {
        "ok": True,
        "ts": time.time(),
        "bus": bus_id,
        "address": f"0x{addr:02x}",
        "mfg": f"0x{mfg:04x}",
        "die": f"0x{die:04x}",
        "channels": channels,
    }

    if cfg.get("read_env_sensors", True):
        env = read_env(bus_id, int(cfg.get("tmp102_address") or 0x48))
        reading["tmp102_c"] = env.get("tmp102_c")
        reading["bme"] = env.get("bme")
        reading["temp_c"] = env.get("temp_c")
        reading["humidity_pct"] = env.get("humidity_pct")
        reading["pressure_mbar"] = env.get("pressure_mbar")
        reading["temp_source"] = env.get("temp_source")

    return reading


def info_string(reading: dict, extra: str = "") -> str:
    """Collector-safe SID_INFORMATION: rails + optional tmp102 note."""
    parts = []
    if extra:
        parts.append(extra.strip())
    for ch in reading["channels"]:
        lab = ch["label"]
        parts.append(f"{lab}_v={ch['v']:.2f}V/{lab}_i={ch['ma']:.1f}mA")
    # TMP102 is local/secondary — note only if BME absent for collector clarity
    if reading.get("tmp102_c") is not None and not reading.get("bme"):
        parts.append(f"tmp102_c={reading['tmp102_c']:.2f}C")
    return " ".join(parts)


def write_cache(reading: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w") as f:
        json.dump(reading, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def format_motd(reading: dict) -> str:
    lines = []
    for ch in reading["channels"]:
        lines.append(
            f"{ch['label']:>6}: {ch['v']:6.3f}V  {ch['ma']:7.1f}mA  ({ch['mw']:.0f}mW)"
        )
    tmp = reading.get("tmp102_c")
    if tmp is not None:
        lines.append(f" TMP102: {tmp:6.2f}C  (hat)")
    bme = reading.get("bme") or {}
    if bme:
        hum = bme.get("humidity_pct")
        pr = bme.get("pressure_mbar")
        tc = bme.get("temp_c")
        bits = [f"{bme.get('chip','BME')}:"]
        if tc is not None:
            bits.append(f"{tc:.2f}C")
        if hum is not None:
            bits.append(f"{hum:.0f}%RH")
        if pr is not None:
            bits.append(f"{pr:.0f}mb")
        lines.append("  " + " ".join(bits))
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Read INA3221 + env sensors")
    ap.add_argument("-c", "--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("--motd", action="store_true")
    ap.add_argument("--cache", action="store_true")
    ap.add_argument("--cache-path", type=Path, default=None)
    ap.add_argument("--extra", default="")
    args = ap.parse_args(argv)

    cfg = load_config(args.config)
    try:
        reading = read_channels(cfg)
    except Exception as e:
        err = {"ok": False, "error": str(e), "ts": time.time()}
        if args.json:
            print(json.dumps(err))
        else:
            print(f"ina3221: {e}", file=sys.stderr)
        return 1

    cache_path = args.cache_path or Path(cfg.get("cache_path") or DEFAULT_CACHE)
    if args.cache or args.motd:
        write_cache(reading, cache_path)

    if args.json:
        print(json.dumps(reading, indent=2))
    elif args.info:
        print(info_string(reading, args.extra))
    elif args.motd:
        print(format_motd(reading))
    else:
        print(
            f"INA3221 bus={reading['bus']} addr={reading['address']} "
            f"mfg={reading['mfg']} die={reading['die']}"
        )
        for ch in reading["channels"]:
            print(
                f"  CH{ch['ch']} {ch['label']:8s}  "
                f"{ch['v']:7.3f} V  {ch['ma']:8.1f} mA  {ch['mw']:8.1f} mW"
            )
        if reading.get("tmp102_c") is not None:
            print(f"  TMP102          {reading['tmp102_c']:7.3f} C")
        bme = reading.get("bme")
        if bme:
            hum = bme.get("humidity_pct")
            print(
                f"  {bme.get('chip','BME'):8s} @{bme.get('address')}  "
                f"{bme.get('temp_c'):.2f} C  "
                f"{(str(hum)+'%RH') if hum is not None else 'n/a'}  "
                f"{bme.get('pressure_mbar'):.1f} mbar"
            )
            print(f"  ambient source: {reading.get('temp_source')}")
        if args.cache:
            print(f"cache → {cache_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
