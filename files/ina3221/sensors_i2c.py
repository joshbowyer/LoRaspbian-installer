#!/usr/bin/env python3
"""I2C env sensors: TMP102 (MeshAdv Mini) + BME/BMP280 (Qwiic).

TMP102 default 0x48. BME280 probed 0x76 then 0x77 (chip id 0x60);
BMP280 same addrs (chip id 0x58) — pressure+temp only.
"""
from __future__ import annotations

import time
from typing import Any, Optional


def _load_smbus():
    try:
        from smbus2 import SMBus  # type: ignore

        return SMBus
    except ImportError:
        pass
    from smbus import SMBus  # type: ignore

    return SMBus


def read_tmp102(bus_id: int = 0, addr: int = 0x48) -> Optional[float]:
    """Return °C or None if absent/unreadable."""
    SMBus = _load_smbus()
    bus = SMBus(bus_id)
    try:
        raw = bus.read_i2c_block_data(addr, 0x00, 2)
        val = (raw[0] << 8) | raw[1]
        val >>= 4  # 12-bit left-justified
        if val & 0x800:
            val -= 0x1000
        return round(val * 0.0625, 3)
    except OSError:
        return None
    finally:
        try:
            bus.close()
        except Exception:
            pass


def _u16(a: int, b: int) -> int:
    return a | (b << 8)


def _s16(a: int, b: int) -> int:
    v = _u16(a, b)
    return v - 65536 if v > 32767 else v


def _s8(v: int) -> int:
    return v - 256 if v > 127 else v


def read_bme280(bus_id: int = 0, addrs=(0x76, 0x77)) -> Optional[dict[str, Any]]:
    """Forced-mode BME280/BMP280 read. Returns dict or None.

    Keys: temp_c, humidity_pct (BME only), pressure_mbar, chip, address
    """
    SMBus = _load_smbus()
    bus = SMBus(bus_id)
    try:
        addr = None
        chip_id = None
        for a in addrs:
            try:
                chip_id = bus.read_byte_data(a, 0xD0)
            except OSError:
                continue
            if chip_id in (0x60, 0x58):  # BME280 / BMP280
                addr = a
                break
        if addr is None:
            return None

        is_bme = chip_id == 0x60

        c = bus.read_i2c_block_data(addr, 0x88, 24)
        dig_T1 = _u16(c[0], c[1])
        dig_T2 = _s16(c[2], c[3])
        dig_T3 = _s16(c[4], c[5])
        dig_P1 = _u16(c[6], c[7])
        dig_P2 = _s16(c[8], c[9])
        dig_P3 = _s16(c[10], c[11])
        dig_P4 = _s16(c[12], c[13])
        dig_P5 = _s16(c[14], c[15])
        dig_P6 = _s16(c[16], c[17])
        dig_P7 = _s16(c[18], c[19])
        dig_P8 = _s16(c[20], c[21])
        dig_P9 = _s16(c[22], c[23])

        dig_H1 = dig_H2 = dig_H3 = dig_H4 = dig_H5 = dig_H6 = 0
        if is_bme:
            dig_H1 = bus.read_byte_data(addr, 0xA1)
            e = bus.read_i2c_block_data(addr, 0xE1, 7)
            dig_H2 = _s16(e[0], e[1])
            dig_H3 = e[2]
            dig_H4 = (_s8(e[3]) << 4) | (e[4] & 0x0F)
            dig_H5 = (_s8(e[5]) << 4) | (e[4] >> 4)
            dig_H6 = _s8(e[6])
            bus.write_byte_data(addr, 0xF2, 0x01)  # ctrl_hum osrs_h=1

        # ctrl_meas: osrs_t=1, osrs_p=1, mode=forced
        bus.write_byte_data(addr, 0xF4, 0x25)
        time.sleep(0.05)
        # wait measuring bit clear
        for _ in range(20):
            status = bus.read_byte_data(addr, 0xF3)
            if not (status & 0x08):
                break
            time.sleep(0.01)

        d = bus.read_i2c_block_data(addr, 0xF7, 8)
        adc_p = (d[0] << 12) | (d[1] << 4) | (d[2] >> 4)
        adc_t = (d[3] << 12) | (d[4] << 4) | (d[5] >> 4)
        adc_h = (d[6] << 8) | d[7]

        # temperature (Bosch)
        var1 = (((adc_t >> 3) - (dig_T1 << 1)) * dig_T2) >> 11
        var2 = (
            ((((adc_t >> 4) - dig_T1) * ((adc_t >> 4) - dig_T1)) >> 12) * dig_T3
        ) >> 14
        t_fine = var1 + var2
        T = (t_fine * 5 + 128) >> 8
        temp_c = T / 100.0

        # pressure
        var1 = t_fine - 128000
        var2 = var1 * var1 * dig_P6
        var2 = var2 + ((var1 * dig_P5) << 17)
        var2 = var2 + (dig_P4 << 35)
        var1 = ((var1 * var1 * dig_P3) >> 8) + ((var1 * dig_P2) << 12)
        var1 = (((1 << 47) + var1) * dig_P1) >> 33
        if var1 == 0:
            press_hpa = 0.0
        else:
            p = 1048576 - adc_p
            p = (((p << 31) - var2) * 3125) // var1
            var1 = (dig_P9 * (p >> 13) * (p >> 13)) >> 25
            var2 = (dig_P8 * p) >> 19
            p = ((p + var1 + var2) >> 8) + (dig_P7 << 4)
            press_hpa = p / 25600.0

        out: dict[str, Any] = {
            "chip": "BME280" if is_bme else "BMP280",
            "address": f"0x{addr:02x}",
            "temp_c": round(temp_c, 2),
            "pressure_mbar": round(press_hpa, 2),  # hPa == mbar
        }

        if is_bme:
            v_x1 = t_fine - 76800
            v_x1 = (
                (
                    (
                        ((adc_h << 14) - (dig_H4 << 20) - (dig_H5 * v_x1)) + 16384
                    )
                    >> 15
                )
                * (
                    (
                        (
                            (
                                (
                                    ((v_x1 * dig_H6) >> 10)
                                    * (((v_x1 * dig_H3) >> 11) + 32768)
                                )
                                >> 10
                            )
                            + 2097152
                        )
                        * dig_H2
                        + 8192
                    )
                    >> 14
                )
            )
            v_x1 = v_x1 - (((((v_x1 >> 15) * (v_x1 >> 15)) >> 7) * dig_H1) >> 4)
            if v_x1 < 0:
                v_x1 = 0
            elif v_x1 > 419430400:
                v_x1 = 419430400
            hum = (v_x1 >> 12) / 1024.0
            out["humidity_pct"] = round(hum, 1)

        return out
    except OSError:
        return None
    finally:
        try:
            bus.close()
        except Exception:
            pass


def read_env(bus_id: int = 0, tmp_addr: int = 0x48) -> dict[str, Any]:
    """Read all env sensors. BME temp preferred for collector; TMP always local."""
    tmp = read_tmp102(bus_id, tmp_addr)
    bme = read_bme280(bus_id)
    out: dict[str, Any] = {
        "tmp102_c": tmp,
        "bme": bme,
        # collector / display preferred ambient
        "temp_c": None,
        "humidity_pct": None,
        "pressure_mbar": None,
        "temp_source": None,
    }
    if bme and bme.get("temp_c") is not None:
        out["temp_c"] = bme["temp_c"]
        out["temp_source"] = bme.get("chip", "BME")
        out["humidity_pct"] = bme.get("humidity_pct")
        out["pressure_mbar"] = bme.get("pressure_mbar")
    elif tmp is not None:
        out["temp_c"] = tmp
        out["temp_source"] = "TMP102"
    return out
