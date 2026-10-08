"""ahbu-template/1 örnek dosyalarını üretir (README.md "Örnek dosyalar").

Çalıştırma: python docs/contracts/template/gen_fixtures.py
Geçerli şablonlar (ok_*) ve her biri tek bir kuralı bozan hatalı şablonlar (bad_*: {"expect": kod, "template": ...}) yazılır.
Sunucu, firmware ve servis yazılımı testleri bu dosyaları okur; elle düzenlemeyin, burayı değiştirip yeniden üretin.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "fixtures"

TID = "3f2a9c1e-5b7d-4e8f-9a01-23456789abcd"
SITE = "8c1d2e3f-4a5b-4c6d-8e7f-0123456789ab"


def meta(name: str, flat: str, version: int = 1, site: str | None = SITE) -> dict:
    return {"template_id": TID, "version": version, "name": name, "flat_type": flat, "site_id": site}


def shutter_pair(ch: int, room: str, runtime: int = 25) -> list[dict]:
    return [
        {"ch": ch, "name": f"{room} Panjur Yukarı", "room": room, "type": "shutter_up", "runtime_s": runtime,
         "load": f"{room} panjur motoru (yukarı)"},
        {"ch": ch + 1, "name": f"{room} Panjur Aşağı", "room": room, "type": "shutter_down", "runtime_s": runtime,
         "load": f"{room} panjur motoru (aşağı)"},
    ]


def light(ch: int, name: str, room: str, load: str = "") -> dict:
    return {"ch": ch, "name": name, "room": room, "type": "light", "load": load or f"{name} lamba hattı"}


def di(ch: int, name: str, target: int = 0, mode: str = "toggle", wiring: str = "") -> dict:
    return {"ch": ch, "name": name, "target_relay": target, "mode": mode, "wiring": wiring}


def base_safety() -> dict:
    return {"policy": {"on": True, "dry_hold_ms": 10000}, "zones": [{"id": 1, "name": "Ev"}],
            "sensors": [], "actuators": [], "lights": []}


def t_1p1() -> dict:
    """1+1: tek panjur (salon), 6 lamba; girişler duvar anahtarı."""
    relays = shutter_pair(1, "Salon") + [
        light(3, "Salon Aydınlatma", "Salon"), light(4, "Yatak Odası", "Yatak Odası"),
        light(5, "Mutfak", "Mutfak"), light(6, "Banyo", "Banyo"),
        light(7, "Antre", "Antre"), light(8, "Balkon", "Balkon"),
    ]
    dis = [di(1, "Salon Panjur Butonu", 1, "shutter_step", "Salon pencere yanı"),
           di(2, "Salon Anahtar", 3, "toggle", "Salon kapı yanı"),
           di(3, "Yatak Odası Anahtar", 4), di(4, "Mutfak Anahtar", 5), di(5, "Banyo Anahtar", 6),
           di(6, "Antre Anahtar", 7), di(7, "Balkon Anahtar", 8), di(8, "Boşta")]
    return {"schema": "ahbu-template/1", "meta": meta("A Tipi 1+1", "1+1"),
            "ext_module": {"enabled": False, "channels": 0, "address": 1},
            "relays": relays, "dis": dis, "safety": base_safety()}


def t_2p1() -> dict:
    """2+1: fabrika varsayılanına yakın (iki panjur + dört lamba), genel şablon (site yok)."""
    relays = shutter_pair(1, "Salon") + shutter_pair(3, "Oda", 30) + [
        light(5, "Salon Aydınlatma", "Salon"), light(6, "Mutfak Aydınlatma", "Mutfak"),
        light(7, "Koridor Aydınlatma", "Koridor"), light(8, "Balkon Aydınlatma", "Balkon"),
    ]
    dis = [di(1, "Salon Panjur Butonu", 1, "shutter_step"), di(2, "Boşta"),
           di(3, "Oda Panjur Butonu", 3, "shutter_step"), di(4, "Boşta"),
           di(5, "Salon Anahtar", 5), di(6, "Mutfak Anahtar", 6), di(7, "Koridor Anahtar", 7), di(8, "Balkon Anahtar", 8)]
    return {"schema": "ahbu-template/1", "meta": meta("Standart 2+1", "2+1", site=None),
            "ext_module": {"enabled": False, "channels": 0, "address": 1},
            "relays": relays, "dis": dis, "safety": base_safety()}


def t_3p1_valve_dimmer() -> dict:
    """3+1: iki panjur, su vanası (röle 8, enerjide kapanır), su sensörleri (d7, d8), salon dimmer (Modbus)."""
    relays = shutter_pair(1, "Salon") + shutter_pair(3, "Yatak Odası", 30) + [
        light(5, "Salon Aydınlatma", "Salon"), light(6, "Mutfak Aydınlatma", "Mutfak"),
        light(7, "Çocuk Odası", "Çocuk Odası"),
        {"ch": 8, "name": "Su Vanası", "room": "Mutfak", "type": "light", "load": "Motorlu su vanası (kapama)"},
    ]
    dis = [di(1, "Salon Panjur Butonu", 1, "shutter_step"), di(2, "Yatak Panjur Butonu", 3, "shutter_step"),
           di(3, "Salon Anahtar", 5), di(4, "Mutfak Anahtar", 6), di(5, "Çocuk Odası Anahtar", 7),
           di(6, "Boşta"), di(7, "Mutfak Su Sensörü", 0, "toggle", "Evye altı"),
           di(8, "Banyo Su Sensörü", 0, "toggle", "Lavabo altı")]
    safety = base_safety()
    safety["zones"] = [{"id": 1, "name": "Ev"}]
    safety["sensors"] = [
        {"id": "d7", "kind": "water", "zone": 1, "active_open": 0, "name": "Mutfak Su"},
        {"id": "d8", "kind": "water", "zone": 1, "active_open": 0, "name": "Banyo Su"},
    ]
    safety["actuators"] = [
        {"relay": 8, "kind": "valve", "close_mode": "energize", "medium": "water", "zones": [1], "name": "Ana Su Vanası"},
    ]
    safety["lights"] = [{"relay": 5, "dimmable": 1, "src": 1, "addr": 2, "ch": 1}]
    return {"schema": "ahbu-template/1", "meta": meta("B Tipi 3+1", "3+1", version=4),
            "ext_module": {"enabled": False, "channels": 0, "address": 1},
            "relays": relays, "dis": dis, "safety": safety}


def t_ext16() -> dict:
    """Dubleks: 8 kanallı ek modül (toplam 16 röle/16 giriş), gaz sensörü (NC) + siren + gaz vanası."""
    relays = shutter_pair(1, "Salon") + shutter_pair(3, "Yatak Odası") + shutter_pair(5, "Çalışma") + [
        light(7, "Salon Aydınlatma", "Salon"), light(8, "Mutfak Aydınlatma", "Mutfak"),
    ] + [light(9 + i, f"Üst Kat Lamba {i + 1}", "Üst Kat") for i in range(6)] + [
        {"ch": 15, "name": "Siren", "room": "Antre", "type": "light", "load": "İç siren 12 V"},
        {"ch": 16, "name": "Gaz Vanası", "room": "Mutfak", "type": "light", "load": "Gaz selenoid vanası"},
    ]
    dis = [di(i + 1, f"Anahtar {i + 1}", 7 + i if i < 8 else 0) for i in range(16)]
    dis[0] = di(1, "Salon Panjur Butonu", 1, "shutter_step")
    dis[15] = di(16, "Mutfak Gaz Dedektörü", 0, "toggle", "Sertifikalı dedektör röle çıkışı (NC)")
    safety = base_safety()
    safety["zones"] = [{"id": 1, "name": "Alt Kat"}, {"id": 2, "name": "Üst Kat"}]
    safety["sensors"] = [{"id": "d16", "kind": "gas", "zone": 1, "active_open": 1, "name": "Mutfak Gaz"}]
    safety["actuators"] = [
        {"relay": 16, "kind": "valve", "close_mode": "deenergize", "medium": "gas", "zones": [1], "name": "Gaz Vanası"},
        {"relay": 15, "kind": "siren", "zones": [1, 2], "name": "İç Siren"},
    ]
    return {"schema": "ahbu-template/1", "meta": meta("Dubleks 4+1", "dubleks", version=2),
            "ext_module": {"enabled": True, "channels": 8, "address": 1},
            "relays": relays, "dis": dis, "safety": safety}


OK = {"ok_1p1.json": t_1p1, "ok_2p1_genel.json": t_2p1, "ok_3p1_vana_dimmer.json": t_3p1_valve_dimmer,
      "ok_dubleks_ekmodul16.json": t_ext16}


def bad(name: str, expect: str, mutate) -> tuple[str, dict]:
    src = {"ok_1p1": t_1p1, "ok_3p1": t_3p1_valve_dimmer, "ok_ext": t_ext16}
    key, fn = mutate
    t = copy.deepcopy(src[key]())
    fn(t)
    return name, {"expect": expect, "template": t}


def _set(path: list, value):
    def f(t):
        cur = t
        for p in path[:-1]:
            cur = cur[p]
        cur[path[-1]] = value
    return f


def _del(path: list):
    def f(t):
        cur = t
        for p in path[:-1]:
            cur = cur[p]
        del cur[path[-1]]
    return f


def _chain(*fns):
    def f(t):
        for fn in fns:
            fn(t)
    return f


BAD = [
    bad("bad_schema.json", "schema", ("ok_1p1", _set(["schema"], "ahbu-template/2"))),
    bad("bad_extra_field.json", "bad_field", ("ok_1p1", _set(["fazla"], 1))),
    bad("bad_relay_count.json", "relay_count", ("ok_1p1", lambda t: t["relays"].pop())),
    bad("bad_relay_ch_order.json", "relay_count", ("ok_1p1", _set(["relays", 2, "ch"], 9))),
    bad("bad_di_count.json", "di_count", ("ok_1p1", lambda t: t["dis"].pop())),
    bad("bad_shutter_orphan.json", "invalid_shutter_pair", ("ok_1p1", _chain(
        _set(["relays", 1, "type"], "light"), _del(["relays", 1, "runtime_s"])))),
    bad("bad_shutter_swapped.json", "invalid_shutter_pair", ("ok_1p1", _chain(
        _set(["relays", 0, "type"], "shutter_down"), _set(["relays", 1, "type"], "shutter_up")))),
    bad("bad_shutter_runtime_range.json", "invalid_runtime", ("ok_1p1", _chain(
        _set(["relays", 0, "runtime_s"], 301), _set(["relays", 1, "runtime_s"], 301)))),
    bad("bad_shutter_runtime_mismatch.json", "invalid_runtime", ("ok_1p1", _set(["relays", 1, "runtime_s"], 26))),
    bad("bad_light_runtime.json", "invalid_runtime", ("ok_1p1", _set(["relays", 2, "runtime_s"], 5))),
    bad("bad_impulse_no_pulse.json", "invalid_runtime", ("ok_1p1", _set(["relays", 7, "type"], "impulse"))),
    bad("bad_type.json", "invalid_type", ("ok_1p1", _set(["relays", 2, "type"], "dimmer"))),
    bad("bad_name_empty.json", "invalid_name", ("ok_1p1", _set(["relays", 3, "name"], ""))),
    bad("bad_name_long.json", "invalid_name", ("ok_1p1", _set(["relays", 3, "name"], "Ç" * 16))),
    bad("bad_target_relay.json", "invalid_target_relay", ("ok_1p1", _set(["dis", 2, "target_relay"], 9))),
    bad("bad_shutter_di_target.json", "invalid_target_relay", ("ok_1p1", _set(["dis", 0, "target_relay"], 2))),
    bad("bad_mode.json", "invalid_mode", ("ok_1p1", _set(["dis", 2, "mode"], "dimmer"))),
    bad("bad_ext_channels.json", "invalid_ext_channels", ("ok_ext", _set(["ext_module", "channels"], 6))),
    bad("bad_ext_disabled_channels.json", "invalid_ext_channels", ("ok_1p1", _set(["ext_module", "channels"], 8))),
    bad("bad_ext_address.json", "invalid_ext_address", ("ok_ext", _set(["ext_module", "address"], 0))),
    bad("bad_gas_not_nc.json", "gas_smoke_not_nc", ("ok_ext", _set(["safety", "sensors", 0, "active_open"], 0))),
    bad("bad_sensor_dup.json", "sensor_dup", ("ok_3p1", lambda t: t["safety"]["sensors"].append(
        {"id": "d7", "kind": "water", "zone": 1, "active_open": 0, "name": "Tekrar"}))),
    bad("bad_sensor_di_is_button.json", "sensor_di_is_button", ("ok_3p1", _set(["dis", 6, "target_relay"], 5))),
    bad("bad_sensor_zone.json", "sensor_zone", ("ok_3p1", _set(["safety", "sensors", 0, "zone"], 3))),
    bad("bad_act_relay_shutter.json", "act_relay_shutter", ("ok_3p1", _set(["safety", "actuators", 0, "relay"], 1))),
    bad("bad_act_relay_dup.json", "act_relay_dup", ("ok_ext", _set(["safety", "actuators", 1, "relay"], 16))),
    bad("bad_dry_hold.json", "dry_hold", ("ok_1p1", _set(["safety", "policy", "dry_hold_ms"], 999))),
]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()
    for name, fn in OK.items():
        (OUT / name).write_text(json.dumps(fn(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for name, body in BAD:
        (OUT / name).write_text(json.dumps(body, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{len(OK)} geçerli, {len(BAD)} hatalı örnek yazıldı: {OUT}")


if __name__ == "__main__":
    main()
