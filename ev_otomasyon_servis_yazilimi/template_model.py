# -*- coding: utf-8 -*-
"""
Kurulum şablonu (``ahbu-template/1``) modeli ve doğrulayıcısı - Tk'siz, ağsız, saf mantık.

Tek kaynak: ``docs/contracts/template/README.md`` (K-Ş2). Sunucu (``template_schema.js``) ve firmware (``src/template/``) aynı
kuralları uygular; üçü de ``docs/contracts/template/fixtures/`` örnekleriyle sınanır ve örneklerde AYNI kodu döndürmelidir.
Firmware son söz sahibidir; bu doğrulayıcı kaydetmeden/yazmadan önce erken uyarıdır.

İçerik:
* ``validate_template(t)``: README doğrulama sırasıyla ilk hatayı ``TemplateIssue(code, path)`` olarak döndürür (geçerliyse None).
* Düzenleyici yardımcıları: boş şablon, ek modül değişince tabloların yeniden boyutlanması, panjur çifti kurma/bozma,
  DI güvenlik rolü (sensör) atama, uygulama zarfı (``{"template": ..., "label": ...}``) ve seri ``TPL`` parçalama.
* Türkçe metinler: hata kodu açıklamaları (kart/sunucu/araç) ve K4 dimmer (parlaklık) yönergesi.
"""

from __future__ import annotations

import base64
import copy
import json
import re
import zlib
from dataclasses import dataclass
from typing import Any, Optional

SCHEMA = "ahbu-template/1"
ROOT_KEYS = ("schema", "meta", "ext_module", "relays", "dis", "safety")
META_KEYS = ("template_id", "version", "name", "flat_type", "site_id")
EXT_KEYS = ("enabled", "channels", "address")
RELAY_KEYS = ("ch", "name", "room", "type", "runtime_s", "pulse_ms", "load")
DI_KEYS = ("ch", "name", "target_relay", "mode", "wiring")
SAFETY_KEYS = ("policy", "intrusion", "zones", "sensors", "actuators", "lights")
SENSOR_KEYS = ("id", "kind", "zone", "active_open", "flags", "confirm_ms", "name")
ACTUATOR_KEYS = ("relay", "relay2", "kind", "close_mode", "medium", "zones", "fb_di", "fb_closed_active", "fb_timeout_s",
                 "run_limit_s", "exproof", "name")
LIGHT_KEYS = ("relay", "dimmable", "src", "addr", "ch")

EXT_CHANNELS = (0, 2, 4, 8, 12, 16, 24, 32)
BASE_CHANNELS = 8
MAX_CHANNELS = 40
RELAY_TYPES = ("light", "shutter_up", "shutter_down", "impulse")
DI_MODES = ("toggle", "momentary", "shutter_step", "shutter_up", "shutter_down")
SHUTTER_RUNTIME = (1, 300)
PULSE_MS = (100, 60000)
DRY_HOLD = (1000, 600000)
MAX_ZONES = 4
MAX_SENSORS = 56
MAX_ACTUATORS = 16
MAX_BRIDGE = 16
NAME_BYTES = 31
ROOM_BYTES = 31
NOTE_BYTES = 48
META_NAME_BYTES = 48
FLAT_TYPE_BYTES = 16
ZONE_NAME_BYTES = 15
SAFETY_NAME_BYTES = 19
LABEL_BYTES = 31
MAX_ENVELOPE_BYTES = 24576
SERIAL_CHUNK_BYTES = 111           # 111 bayt -> 148 base64 karakteri (README: <=150; "TPL DATA " ile satır <= 159)

HAZARD_KINDS = ("water", "gas", "smoke")
OTHER_SENSOR_KINDS = ("door", "window", "motion", "generic")
CONTROL_KINDS = ("alarm_ack", "valve_close", "gas_reset", "arm_key")
SENSOR_KINDS = HAZARD_KINDS + OTHER_SENSOR_KINDS + CONTROL_KINDS
ACT_KINDS = ("valve", "siren", "fan", "generic")
CLOSE_MODES = ("energize", "deenergize", "pulse")
MEDIUMS = ("water", "gas", "none")
SF_ALL = 0x1F
FB_TIMEOUT = (2, 300)
SIREN_RUN = (10, 1800)
SIREN_RUN_DEFAULT = 180
PULSE_MAX_S = 120
PULSE_DEFAULT_S = 15
CONFIRM = (100, 10000)
PLACEHOLDER_ID = "00000000-0000-0000-0000-000000000000"   # sunucu kaydetmeden önceki taslak kimliği

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_SENSOR_ID = re.compile(r"^([db])([1-9][0-9]?)$")


@dataclass(frozen=True)
class TemplateIssue:
    """Doğrulama sonucu: README hata kodu ve alan yolu (ör. ``relays[3].runtime_s``)."""

    code: str
    path: str = ""

    def __str__(self) -> str:
        return describe_error(self.code, self.path)


# ---------------------------------------------------------------------------
# Küçük yardımcılar
# ---------------------------------------------------------------------------
def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _utf8_len(text: str) -> int:
    return len(text.encode("utf-8"))


def _clean_text(value: Any, lo: int, hi: int) -> bool:
    """Metin mi, UTF-8 bayt uzunluğu [lo, hi] mi, kontrol karakteri yok mu."""
    if not isinstance(value, str):
        return False
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        return False
    return lo <= _utf8_len(value) <= hi


def _flag(value: Any) -> Optional[int]:
    """0/1 tamsayı ya da boolean -> 0/1; başka her şey None (firmware getFlag)."""
    if isinstance(value, bool):
        return 1 if value else 0
    if _is_int(value) and value in (0, 1):
        return value
    return None


def total_channels(template: dict[str, Any]) -> int:
    """README: ``N = 8 + (enabled ? channels : 0)`` (en çok 40)."""
    ext = template.get("ext_module") if isinstance(template, dict) else None
    if isinstance(ext, dict) and ext.get("enabled") is True and _is_int(ext.get("channels")):
        return min(MAX_CHANNELS, BASE_CHANNELS + max(0, ext["channels"]))
    return BASE_CHANNELS


def default_confirm_ms(kind: str) -> int:
    if kind == "water":
        return 1000
    if kind in ("gas", "smoke"):
        return 300
    return 0


def parse_sensor_id(value: Any) -> Optional[tuple[str, int]]:
    """``d1..d40`` -> ("di", n); ``b1..b16`` -> ("bridge", n); başka her şey None (baştaki sıfır yok)."""
    if not isinstance(value, str):
        return None
    match = _SENSOR_ID.match(value)
    if not match:
        return None
    number = int(match.group(2))
    if match.group(1) == "d":
        return ("di", number) if 1 <= number <= MAX_CHANNELS else None
    return ("bridge", number) if 1 <= number <= MAX_BRIDGE else None


# ---------------------------------------------------------------------------
# Doğrulayıcı (README "Doğrulama sırası"; ilk hata döner)
# ---------------------------------------------------------------------------
class _Fail(Exception):
    def __init__(self, code: str, path: str = "") -> None:
        super().__init__(code)
        self.issue = TemplateIssue(code, path)


def _only_keys(obj: Any, allowed: tuple[str, ...], path: str, required: tuple[str, ...] = ()) -> None:
    if not isinstance(obj, dict):
        raise _Fail("bad_field", path)
    for key in obj:
        if key not in allowed:
            raise _Fail("bad_field", f"{path}.{key}" if path else str(key))
    for key in required:
        if key not in obj:
            raise _Fail("bad_field", f"{path}.{key}" if path else key)


def _check_meta(meta: Any) -> None:
    _only_keys(meta, META_KEYS, "meta", META_KEYS)
    if not isinstance(meta["template_id"], str) or not _UUID.match(meta["template_id"]):
        raise _Fail("invalid_template_id", "meta.template_id")
    if not _is_int(meta["version"]) or not 1 <= meta["version"] <= 2**31 - 1:
        raise _Fail("invalid_version", "meta.version")
    if not _clean_text(meta["name"], 1, META_NAME_BYTES):
        raise _Fail("invalid_name", "meta.name")
    if not _clean_text(meta["flat_type"], 1, FLAT_TYPE_BYTES):
        raise _Fail("invalid_flat_type", "meta.flat_type")
    site = meta["site_id"]
    if site is not None and (not isinstance(site, str) or not _UUID.match(site)):
        raise _Fail("invalid_site_id", "meta.site_id")


def _check_ext(ext: Any) -> int:
    _only_keys(ext, EXT_KEYS, "ext_module", EXT_KEYS)
    if not isinstance(ext["enabled"], bool):
        raise _Fail("bad_field", "ext_module.enabled")
    channels = ext["channels"]
    if not _is_int(channels) or channels not in EXT_CHANNELS:
        raise _Fail("invalid_ext_channels", "ext_module.channels")
    if (ext["enabled"] and channels == 0) or (not ext["enabled"] and channels != 0):
        raise _Fail("invalid_ext_channels", "ext_module.channels")
    address = ext["address"]
    if not _is_int(address) or not 1 <= address <= 247:
        raise _Fail("invalid_ext_address", "ext_module.address")
    return BASE_CHANNELS + (channels if ext["enabled"] else 0)


def _check_relays(relays: Any, n: int) -> list[str]:
    if not isinstance(relays, list) or len(relays) != n:
        raise _Fail("relay_count", "relays")
    for index, relay in enumerate(relays):
        if not isinstance(relay, dict) or relay.get("ch") != index + 1 or not _is_int(relay.get("ch")):
            raise _Fail("relay_count", f"relays[{index}].ch")
    types: list[str] = []
    for index, relay in enumerate(relays):
        path = f"relays[{index}]"
        _only_keys(relay, RELAY_KEYS, path, ("ch", "name", "type"))
        if not _clean_text(relay["name"], 1, NAME_BYTES):
            raise _Fail("invalid_name", f"{path}.name")
        kind = relay["type"]
        if kind not in RELAY_TYPES:
            raise _Fail("invalid_type", f"{path}.type")
        shutter = kind in ("shutter_up", "shutter_down")
        if shutter:
            runtime = relay.get("runtime_s")
            if not _is_int(runtime) or not SHUTTER_RUNTIME[0] <= runtime <= SHUTTER_RUNTIME[1]:
                raise _Fail("invalid_runtime", f"{path}.runtime_s")
        elif "runtime_s" in relay:
            raise _Fail("invalid_runtime", f"{path}.runtime_s")
        if kind == "impulse":
            pulse = relay.get("pulse_ms")
            if not _is_int(pulse) or not PULSE_MS[0] <= pulse <= PULSE_MS[1]:
                raise _Fail("invalid_runtime", f"{path}.pulse_ms")
        elif "pulse_ms" in relay:
            raise _Fail("invalid_runtime", f"{path}.pulse_ms")
        if "room" in relay and not _clean_text(relay["room"], 0, ROOM_BYTES):
            raise _Fail("invalid_room", f"{path}.room")
        if "load" in relay and not _clean_text(relay["load"], 0, NOTE_BYTES):
            raise _Fail("invalid_load", f"{path}.load")
        types.append(kind)
    for index, kind in enumerate(types):  # panjur çifti (2p-1, 2p) = (yukarı, aşağı)
        ch = index + 1
        if kind == "shutter_up" and (ch % 2 == 0 or types[index + 1] != "shutter_down"):
            raise _Fail("invalid_shutter_pair", f"relays[{index}].type")
        if kind == "shutter_down" and (ch % 2 == 1 or types[index - 1] != "shutter_up"):
            raise _Fail("invalid_shutter_pair", f"relays[{index}].type")
    for index, kind in enumerate(types):
        if kind == "shutter_up" and relays[index]["runtime_s"] != relays[index + 1]["runtime_s"]:
            raise _Fail("invalid_runtime", f"relays[{index + 1}].runtime_s")
    return types


def _check_dis(dis: Any, n: int, types: list[str]) -> None:
    if not isinstance(dis, list) or len(dis) != n:
        raise _Fail("di_count", "dis")
    for index, item in enumerate(dis):
        if not isinstance(item, dict) or item.get("ch") != index + 1 or not _is_int(item.get("ch")):
            raise _Fail("di_count", f"dis[{index}].ch")
    for index, item in enumerate(dis):
        path = f"dis[{index}]"
        _only_keys(item, DI_KEYS, path, ("ch", "name", "target_relay", "mode"))
        if not _clean_text(item["name"], 1, NAME_BYTES):
            raise _Fail("invalid_name", f"{path}.name")
        target = item["target_relay"]
        if not _is_int(target) or not 0 <= target <= n:
            raise _Fail("invalid_target_relay", f"{path}.target_relay")
        mode = item["mode"]
        if mode not in DI_MODES:
            raise _Fail("invalid_mode", f"{path}.mode")
        if mode.startswith("shutter_") and (target == 0 or types[target - 1] != "shutter_up"):
            raise _Fail("invalid_target_relay", f"{path}.target_relay")
        if "wiring" in item and not _clean_text(item["wiring"], 0, NOTE_BYTES):
            raise _Fail("invalid_wiring", f"{path}.wiring")


def _check_safety(safety: Any, n: int, types: list[str], dis: list[dict[str, Any]]) -> None:
    _only_keys(safety, SAFETY_KEYS, "safety", ("policy", "zones"))
    policy = safety["policy"]
    _only_keys(policy, ("on", "dry_hold_ms"), "safety.policy", ("on", "dry_hold_ms"))
    if not isinstance(policy["on"], bool):
        raise _Fail("bad_field", "safety.policy.on")
    hold = policy["dry_hold_ms"]
    if not _is_int(hold) or not DRY_HOLD[0] <= hold <= DRY_HOLD[1]:
        raise _Fail("dry_hold", "safety.policy.dry_hold_ms")
    if "intrusion" in safety:
        intrusion = safety["intrusion"]
        _only_keys(intrusion, ("exit_s", "entry_s"), "safety.intrusion")
        for key in ("exit_s", "entry_s"):
            if key in intrusion and (not _is_int(intrusion[key]) or not 0 <= intrusion[key] <= 255):
                raise _Fail("bad_value", f"safety.intrusion.{key}")

    zones = safety["zones"]
    if not isinstance(zones, list):
        raise _Fail("bad_field", "safety.zones")
    if len(zones) > MAX_ZONES:
        raise _Fail("count", "safety.zones")
    zone_ids: set[int] = set()
    for index, zone in enumerate(zones):
        path = f"safety.zones[{index}]"
        _only_keys(zone, ("id", "name"), path, ("id", "name"))
        if not _is_int(zone["id"]) or not 1 <= zone["id"] <= MAX_ZONES or zone["id"] in zone_ids:
            raise _Fail("bad_zone", f"{path}.id")
        if not _clean_text(zone["name"], 1, ZONE_NAME_BYTES):
            raise _Fail("bad_name", f"{path}.name")
        zone_ids.add(zone["id"])
    if 1 not in zone_ids:
        raise _Fail("bad_zone", "safety.zones")

    sensors = safety.get("sensors", [])
    if not isinstance(sensors, list):
        raise _Fail("bad_field", "safety.sensors")
    if len(sensors) > MAX_SENSORS:
        raise _Fail("count", "safety.sensors")
    seen_di: set[int] = set()
    seen_bridge: set[int] = set()
    for index, sensor in enumerate(sensors):
        path = f"safety.sensors[{index}]"
        _only_keys(sensor, SENSOR_KEYS, path, ("id", "kind", "zone"))
        parsed = parse_sensor_id(sensor["id"])
        if parsed is None:
            raise _Fail("bad_id", f"{path}.id")
        kind = sensor["kind"]
        if kind not in SENSOR_KINDS:
            raise _Fail("bad_kind", f"{path}.kind")
        zone = sensor["zone"]
        if not _is_int(zone) or not 0 <= zone <= MAX_ZONES:
            raise _Fail("bad_zone", f"{path}.zone")
        active_open = _flag(sensor.get("active_open", 0))
        if active_open is None:
            raise _Fail("bad_value", f"{path}.active_open")
        flags = sensor.get("flags", 0)
        if not _is_int(flags) or not 0 <= flags <= SF_ALL:
            raise _Fail("bad_value", f"{path}.flags")
        confirm = sensor.get("confirm_ms", default_confirm_ms(kind))
        if not _is_int(confirm) or not 0 <= confirm <= 60000:
            raise _Fail("bad_value", f"{path}.confirm_ms")
        if "name" in sensor and not _clean_text(sensor["name"], 0, SAFETY_NAME_BYTES):
            raise _Fail("bad_name", f"{path}.name")
        control = kind in CONTROL_KINDS
        src, number = parsed
        if src == "di":
            if number > n:
                raise _Fail("sensor_di_range", f"{path}.id")
            if number in seen_di:
                raise _Fail("sensor_dup", f"{path}.id")
            seen_di.add(number)
            if dis[number - 1]["target_relay"] != 0:
                raise _Fail("sensor_di_is_button", f"dis[{number - 1}].target_relay")
        else:
            if control:
                raise _Fail("sensor_src", f"{path}.id")
            if number in seen_bridge:
                raise _Fail("sensor_dup", f"{path}.id")
            seen_bridge.add(number)
        if control:
            if zone != 0 and zone not in zone_ids:
                raise _Fail("sensor_zone", f"{path}.zone")
        elif zone not in zone_ids:
            raise _Fail("sensor_zone", f"{path}.zone")
        if kind in ("gas", "smoke") and not active_open:
            raise _Fail("gas_smoke_not_nc", f"{path}.active_open")
        if kind == "arm_key" and not active_open:
            raise _Fail("arm_key_not_nc", f"{path}.active_open")
        if kind in HAZARD_KINDS and not CONFIRM[0] <= confirm <= CONFIRM[1]:
            raise _Fail("confirm_range", f"{path}.confirm_ms")
        if kind not in HAZARD_KINDS and confirm > CONFIRM[1]:
            raise _Fail("confirm_range", f"{path}.confirm_ms")

    actuators = safety.get("actuators", [])
    if not isinstance(actuators, list):
        raise _Fail("bad_field", "safety.actuators")
    if len(actuators) > MAX_ACTUATORS:
        raise _Fail("count", "safety.actuators")
    used: set[int] = set()

    def usable(relay: Any, field_path: str) -> None:
        if not _is_int(relay) or not 1 <= relay <= MAX_CHANNELS:
            raise _Fail("bad_relay", field_path)
        if relay > n:
            raise _Fail("act_relay_range", field_path)
        if types[relay - 1] in ("shutter_up", "shutter_down"):
            raise _Fail("act_relay_shutter", field_path)
        if types[relay - 1] == "impulse":
            raise _Fail("act_relay_impulse", field_path)
        if relay in used:
            raise _Fail("act_relay_dup", field_path)
        used.add(relay)

    for index, act in enumerate(actuators):
        path = f"safety.actuators[{index}]"
        _only_keys(act, ACTUATOR_KEYS, path, ("relay", "kind"))
        if not _is_int(act["relay"]) or not 1 <= act["relay"] <= MAX_CHANNELS:
            raise _Fail("bad_relay", f"{path}.relay")
        kind = act["kind"]
        if kind not in ACT_KINDS:
            raise _Fail("bad_kind", f"{path}.kind")
        close_mode = act.get("close_mode", "energize")
        if close_mode not in CLOSE_MODES:
            raise _Fail("bad_value", f"{path}.close_mode")
        medium = act.get("medium", "none")
        if medium not in MEDIUMS:
            raise _Fail("bad_value", f"{path}.medium")
        zone_list = act.get("zones", [])
        if not isinstance(zone_list, list) or any(not _is_int(z) or not 1 <= z <= MAX_ZONES for z in zone_list):
            raise _Fail("bad_zone", f"{path}.zones")
        if "relay2" in act and (not _is_int(act["relay2"]) or not 0 <= act["relay2"] <= MAX_CHANNELS):
            raise _Fail("bad_relay", f"{path}.relay2")
        if "name" in act and not _clean_text(act["name"], 0, SAFETY_NAME_BYTES):
            raise _Fail("bad_name", f"{path}.name")
        if any(z not in zone_ids for z in zone_list):
            raise _Fail("act_zone", f"{path}.zones")
        usable(act["relay"], f"{path}.relay")
        if kind != "generic" and not zone_list:
            raise _Fail("act_zone", f"{path}.zones")
        for key, hi in (("fb_di", MAX_CHANNELS), ("fb_timeout_s", 65535), ("run_limit_s", 65535)):
            if key in act and (not _is_int(act[key]) or not 0 <= act[key] <= hi):
                raise _Fail("bad_value", f"{path}.{key}")
        if act.get("fb_di", 0) > n:
            raise _Fail("fb_di_range", f"{path}.fb_di")
        if "fb_closed_active" in act and _flag(act["fb_closed_active"]) is None:
            raise _Fail("bad_value", f"{path}.fb_closed_active")
        if "exproof" in act and not isinstance(act["exproof"], bool):
            raise _Fail("bad_value", f"{path}.exproof")
        if kind == "valve":
            if medium not in ("water", "gas"):
                raise _Fail("valve_medium", f"{path}.medium")
            if close_mode == "pulse":
                relay2 = act.get("relay2", 0)
                if not _is_int(relay2) or relay2 == 0 or relay2 == act["relay"]:
                    raise _Fail("pulse_relay2", f"{path}.relay2")
                usable(relay2, f"{path}.relay2")
                if act.get("run_limit_s", PULSE_DEFAULT_S) > PULSE_MAX_S:
                    raise _Fail("pulse_time", f"{path}.run_limit_s")
            fb_di = act.get("fb_di", 0)
            if fb_di:
                if fb_di in seen_di or dis[fb_di - 1]["target_relay"] != 0:
                    raise _Fail("fb_di_conflict", f"{path}.fb_di")
                timeout = act.get("fb_timeout_s", 60)
                if not FB_TIMEOUT[0] <= timeout <= FB_TIMEOUT[1]:
                    raise _Fail("fb_timeout_range", f"{path}.fb_timeout_s")
        elif kind == "siren":
            run = act.get("run_limit_s", SIREN_RUN_DEFAULT)
            if not SIREN_RUN[0] <= run <= SIREN_RUN[1]:
                raise _Fail("siren_run_limit", f"{path}.run_limit_s")

    lights = safety.get("lights", [])
    if not isinstance(lights, list):
        raise _Fail("bad_field", "safety.lights")
    if len(lights) > n:
        raise _Fail("count", "safety.lights")
    light_relays: set[int] = set()
    for index, light in enumerate(lights):
        path = f"safety.lights[{index}]"
        _only_keys(light, LIGHT_KEYS, path, ("relay",))
        relay = light["relay"]
        if not _is_int(relay) or not 1 <= relay <= MAX_CHANNELS:
            raise _Fail("bad_relay", f"{path}.relay")
        if relay > n or types[relay - 1] != "light" or relay in light_relays:
            raise _Fail("invalid_light", f"{path}.relay")
        light_relays.add(relay)
        if "dimmable" in light and _flag(light["dimmable"]) is None:
            raise _Fail("bad_value", f"{path}.dimmable")
        for key, hi in (("src", 2), ("addr", 247), ("ch", 255)):
            if key in light and (not _is_int(light[key]) or not 0 <= light[key] <= hi):
                raise _Fail("bad_value", f"{path}.{key}")


def validate_template(template: Any) -> Optional[TemplateIssue]:
    """README doğrulama sırası: ``schema`` -> kök alanlar -> ``meta`` -> ``ext_module`` -> ``relays`` -> ``dis`` -> ``safety``.
    Geçerliyse None; değilse ilk hata."""
    try:
        if not isinstance(template, dict) or template.get("schema") != SCHEMA:
            raise _Fail("schema", "schema")
        _only_keys(template, ROOT_KEYS, "", ROOT_KEYS)
        _check_meta(template["meta"])
        n = _check_ext(template["ext_module"])
        types = _check_relays(template["relays"], n)
        _check_dis(template["dis"], n, types)
        _check_safety(template["safety"], n, types, template["dis"])
    except _Fail as fail:
        return fail.issue
    return None


# ---------------------------------------------------------------------------
# Türkçe hata metinleri (araç, sunucu ve kart kodları)
# ---------------------------------------------------------------------------
ERROR_TEXTS: dict[str, str] = {
    "schema": "Şablon biçimi tanınmadı (ahbu-template/1 bekleniyordu).",
    "bad_field": "Şablonda tanınmayan ya da eksik bir alan var.",
    "invalid_template_id": "Şablon kimliği geçersiz (sunucuda kayıtlı bir şablon olmalı).",
    "invalid_version": "Şablon sürümü geçersiz.",
    "invalid_flat_type": "Daire tipi 1-16 bayt olmalı (ör. 2+1, dubleks).",
    "invalid_site_id": "Şablonun site kimliği geçersiz.",
    "invalid_room": "Oda adı en çok 31 bayt olabilir ve kontrol karakteri içeremez.",
    "invalid_load": "Bağlanacak yük notu en çok 48 bayt olabilir.",
    "invalid_wiring": "Kablolama notu en çok 48 bayt olabilir.",
    "invalid_light": "Parlaklık (dimmer) ayarı yalnız 'Lamba/Priz' tipindeki rölelere, her röleye bir kez verilebilir.",
    "bad_zone": "Bölge geçersiz (1-4, tekrarsız; Bölge 1 zorunlu).",
    "bad_name": "Güvenlik adı geçersiz (bölge adı en çok 15, sensör/cihaz adı en çok 19 bayt).",
    "bad_kind": "Sensör ya da güvenlik cihazı türü geçersiz.",
    "bad_relay": "Güvenlik ayarındaki röle numarası geçersiz.",
    "tpl_b64": "Aktarım verisi bozuk (base64); hiçbir şey değişmedi. Yeniden deneyin.",
    "invalid_json": "Kart gönderilen veriyi çözümleyemedi (bozuk JSON). Yeniden deneyin.",
    "invalid_label": "Kart adı (etiket) geçersiz: en çok 31 bayt olmalı.",
    "unprovisioned": "Kart henüz provizyonlanmamış. Önce FACTORYINIT (provizyon) yapın ya da USB ile yazın.",
    "invalid_ext_channels": "Ek modül kanal sayısı geçersiz (0, 2, 4, 8, 12, 16, 24, 32; etkinse 0 olamaz).",
    "invalid_ext_address": "Ek modül adresi 1-247 arasında olmalı.",
    "relay_count": "Röle tablosu kanal sayısıyla uyuşmuyor (ek modül ayarını kontrol edin).",
    "di_count": "Giriş (DI) tablosu kanal sayısıyla uyuşmuyor (ek modül ayarını kontrol edin).",
    "invalid_name": "Bir ad çok uzun, boş ya da geçersiz karakter içeriyor (röle/giriş adı en çok 31, şablon adı en çok 48 bayt).",
    "invalid_type": "Röle tipi geçersiz.",
    "invalid_runtime": "Süre geçersiz: panjur 1-300 sn (çiftin iki rölesi aynı), darbe 100-60000 ms; diğer tiplerde süre olmaz.",
    "invalid_shutter_pair": "Panjur çifti bozuk: yukarı rölesi tek numaralı, aşağı rölesi hemen ardından gelmeli.",
    "invalid_target_relay": "Girişin hedef rölesi geçersiz (panjur kipleri bir panjurun YUKARI rölesini hedeflemeli).",
    "invalid_mode": "Giriş kipi geçersiz.",
    "dry_hold": "Kuruluk bekleme süresi 1-600 sn arasında olmalı.",
    "count": "Güvenlik tablosunda çok fazla öğe var.",
    "bad_id": "Sensör kimliği geçersiz.",
    "bad_value": "Güvenlik ayarlarında aralık dışı bir değer var.",
    "sensor_kind": "Sensör türü geçersiz.",
    "sensor_zone": "Sensör bölgesi tanımlı bir bölge olmalı.",
    "sensor_src": "Yerel kumanda rolleri yalnız panodaki girişlerden (DI) kullanılabilir.",
    "sensor_di_range": "Sensör girişi kanal sayısının dışında.",
    "sensor_dup": "Aynı giriş iki kez sensör olarak tanımlanmış.",
    "sensor_di_is_button": "Sensör olarak kullanılan girişin hedef rölesi 'boşta' (0) olmalı.",
    "gas_smoke_not_nc": "Gaz/duman dedektörü NC (normalde kapalı) kontakla bağlanmalı.",
    "arm_key_not_nc": "Anahtarlı kontak NC (normalde kapalı) bağlanmalı.",
    "confirm_range": "Sensör onay süresi aralık dışında.",
    "act_kind": "Güvenlik cihazı türü geçersiz.",
    "act_relay_range": "Güvenlik cihazının rölesi kanal sayısının dışında.",
    "act_relay_dup": "Aynı röle iki güvenlik cihazına atanmış.",
    "act_relay_shutter": "Güvenlik cihazı panjur rölesine bağlanamaz.",
    "act_relay_impulse": "Güvenlik cihazı darbe (impulse) rölesine bağlanamaz.",
    "act_zone": "Güvenlik cihazının bölgeleri tanımlı bölgeler olmalı (vana/siren/fan için en az bir bölge).",
    "valve_medium": "Vananın akışkanı (su/gaz) seçilmeli.",
    "valve_mode": "Vana kapanma kipi geçersiz.",
    "pulse_relay2": "İki röleli vanada ikinci (AÇ) rölesi farklı bir röle olmalı.",
    "pulse_time": "İki röleli vana darbe süresi en çok 120 sn.",
    "siren_run_limit": "Siren çalma süresi 10-1800 sn arasında olmalı.",
    "fb_di_range": "Vana geri bildirim girişi kanal sayısının dışında.",
    "fb_di_conflict": "Vana geri bildirim girişi başka bir işte (sensör/anahtar) kullanılıyor.",
    "fb_timeout_range": "Vana geri bildirim zaman aşımı 2-300 sn arasında olmalı.",
    # Kart (seri TPL / LAN) kodları
    "tpl_no_begin": "Kart aktarımı başlatılmadan veri aldı (TPL BEGIN yok). Yeniden deneyin.",
    "tpl_size": "Şablon karta göre çok büyük (en çok 24 KB).",
    "tpl_crc": "Aktarım bozuldu (CRC uyuşmadı); hiçbir şey değişmedi. USB kabloyu kontrol edip yeniden deneyin.",
    "tpl_overflow": "Kart beklenenden fazla veri aldı; aktarım iptal edildi. Yeniden deneyin.",
    "tpl_timeout": "Aktarım zaman aşımına uğradı (30 sn); hiçbir şey değişmedi. Yeniden deneyin.",
    "bad_json": "Kart şablonu çözümleyemedi (bozuk veri). Yeniden deneyin.",
    "local_loosen_forbidden": "Kart bu değişikliği ağ üzerinden kabul etmiyor (güvenlik ayarları gevşiyor). USB ile yazın.",
    "zone_latched": "Kartta kilitli (alarmdaki) bir bölge var; alarm onaylanıp kuruluk sağlanana kadar yazılamaz.",
    "armed": "Hırsız alarmı kurulu; önce alarmı kapatın.",
    "busy": "Kart meşgul (panjur hareket halinde olabilir ya da bellek yetersiz). Birkaç saniye bekleyip yeniden deneyin.",
    "storage": "Kartın kalıcı belleğinde yer yok; şablon uygulanmadı (hiçbir şey değişmedi).",
    "unsupported_fw": "Kartın firmware'i şablon yazmayı desteklemiyor (v1.3.0+ gerekli). Önce firmware'i güncelleyin.",
    "key_mismatch": "Kart yerel anahtarı kabul etmedi (bu kart sunucudaki kayıtla eşleşmiyor olabilir).",
    "locked": "Kart çok sayıda hatalı denemeden dolayı geçici olarak kilitli. Biraz sonra yeniden deneyin.",
    "unreachable": "Karta ağdan ulaşılamadı. IP adresini, Ethernet kablosunu ve bilgisayarın aynı ağda olduğunu kontrol edin.",
    "no_response": "Kart yanıt vermedi.",
    "readback_mismatch": "Yazım sonrası karttan okunan şablon kimliği/sürümü beklenenle eşleşmiyor.",
    "cfg_invalid": "Kart şablonu geçersiz buldu (güvenlik ayarları ana yapılandırmayla uyuşmuyor).",
    "mac_mismatch": "Bağlı kart seçilen daireye bağlı kartla eşleşmiyor.",
    "unexpected": "Karttan beklenmeyen bir yanıt alındı.",
    "cancelled": "İşlem iptal edildi.",
}


def describe_error(code: str, path: str = "") -> str:
    """Hata kodunu kullanıcıya gösterilebilir Türkçe metne çevirir (kod ve alan yolu parantezde)."""
    safe_code = code if isinstance(code, str) and re.fullmatch(r"[a-z0-9_]{1,40}", code or "") else "bilinmiyor"
    text = ERROR_TEXTS.get(safe_code, "Şablon kart tarafından reddedildi.")
    safe_path = path if isinstance(path, str) and re.fullmatch(r"[A-Za-z0-9_.\[\]]{1,64}", path or "") else ""
    return f"{text} ({safe_code}{' @ ' + safe_path if safe_path else ''})"


# ---------------------------------------------------------------------------
# Düzenleyici yardımcıları
# ---------------------------------------------------------------------------
RELAY_KIND_LABELS = {"light": "Lamba/Priz", "shutter": "Panjur (çift)", "impulse": "Darbe"}
RELAY_TYPE_TEXT = {"light": "Lamba/Priz", "shutter_up": "Panjur Yukarı", "shutter_down": "Panjur Aşağı", "impulse": "Darbe"}
DI_MODE_TEXT = {
    "toggle": "Aç/Kapa (anahtar)",
    "momentary": "Basılı tut (buton)",
    "shutter_step": "Panjur adım (tek buton)",
    "shutter_up": "Panjur yukarı",
    "shutter_down": "Panjur aşağı",
}
SENSOR_KIND_TEXT = {
    "water": "Su baskını",
    "gas": "Gaz",
    "smoke": "Duman",
    "door": "Kapı",
    "window": "Pencere",
    "motion": "Hareket",
    "generic": "Genel kontak",
    "alarm_ack": "Alarm susturma butonu",
    "valve_close": "Vana kapatma butonu",
    "gas_reset": "Gaz vanası sıfırlama",
    "arm_key": "Anahtarlı kontak (kurma)",
}
ACT_KIND_TEXT = {"valve": "Vana", "siren": "Siren", "fan": "Fan", "generic": "Genel"}
CLOSE_MODE_TEXT = {"energize": "Enerji verince kapanır", "deenergize": "Enerji kesilince kapanır", "pulse": "İki röle (darbe)"}
MEDIUM_TEXT = {"water": "Su", "gas": "Gaz", "none": "-"}
DIMMER_SRC_TEXT = {0: "Yok", 1: "Modbus dimmer modülü (RS485)", 2: "Köprü (kablosuz dimmer)"}


def new_template(name: str = "Yeni Şablon", flat_type: str = "2+1", site_id: Optional[str] = None) -> dict[str, Any]:
    """Boş (8 lamba, 8 boşta giriş) şablon taslağı; kimlik/sürüm sunucu kaydedince dolar."""
    return {
        "schema": SCHEMA,
        "meta": {"template_id": PLACEHOLDER_ID, "version": 1, "name": name, "flat_type": flat_type, "site_id": site_id},
        "ext_module": {"enabled": False, "channels": 0, "address": 1},
        "relays": [_default_relay(ch) for ch in range(1, BASE_CHANNELS + 1)],
        "dis": [_default_di(ch) for ch in range(1, BASE_CHANNELS + 1)],
        "safety": {"policy": {"on": True, "dry_hold_ms": 10000}, "zones": [{"id": 1, "name": "Ev"}],
                   "sensors": [], "actuators": [], "lights": []},
    }


def _default_relay(ch: int) -> dict[str, Any]:
    return {"ch": ch, "name": f"Röle {ch}", "room": "", "type": "light", "load": ""}


def _default_di(ch: int) -> dict[str, Any]:
    return {"ch": ch, "name": f"Giriş {ch}", "target_relay": 0, "mode": "toggle", "wiring": ""}


def set_ext_module(template: dict[str, Any], enabled: bool, channels: int, address: int) -> None:
    """Ek modülü ayarlar ve röle/giriş tablolarını yeni kanal sayısına göre büyütür/küçültür. Küçülmede dışarıda kalan
    kanallara bağlı panjur çiftleri, sensörler, eylemciler, dimmer ve hedefler temizlenir (şablon geçerli kalsın)."""
    if not enabled:
        channels = 0
    template["ext_module"] = {"enabled": bool(enabled), "channels": int(channels), "address": int(address)}
    n = total_channels(template)
    relays, dis = template["relays"], template["dis"]
    del relays[n:]
    del dis[n:]
    relays.extend(_default_relay(ch) for ch in range(len(relays) + 1, n + 1))
    dis.extend(_default_di(ch) for ch in range(len(dis) + 1, n + 1))
    if relays and relays[-1]["type"] == "shutter_up":  # çiftin yarısı dışarıda kaldı
        set_relay_kind(template, n, "light")
    for item in dis:
        if item["target_relay"] > n:
            item["target_relay"], item["mode"] = 0, "toggle"
    safety = template["safety"]
    safety["sensors"] = [s for s in safety.get("sensors", []) if not _sensor_outside(s, n)]
    safety["actuators"] = [a for a in safety.get("actuators", []) if a.get("relay", 0) <= n and a.get("relay2", 0) <= n]
    for act in safety["actuators"]:
        if act.get("fb_di", 0) > n:
            act["fb_di"] = 0
    safety["lights"] = [light for light in safety.get("lights", []) if light.get("relay", 0) <= n]


def _sensor_outside(sensor: dict[str, Any], n: int) -> bool:
    parsed = parse_sensor_id(sensor.get("id"))
    return parsed is not None and parsed[0] == "di" and parsed[1] > n


def relay_kind(template: dict[str, Any], ch: int) -> str:
    kind = template["relays"][ch - 1]["type"]
    return "shutter" if kind.startswith("shutter") else kind


def set_relay_kind(template: dict[str, Any], ch: int, kind: str, *, runtime_s: int = 25, pulse_ms: int = 1000) -> None:
    """Röle tipini değiştirir. ``shutter`` daima çift kurar: (2p-1, 2p) = (yukarı, aşağı), aynı süre. Panjur çiftinden biri
    başka tipe çevrilirse eşi de 'Lamba/Priz' olur (yetim panjur rölesi kalmaz). Eylemci/dimmer uyumsuzlukları temizlenir."""
    relays = template["relays"]
    if kind == "shutter":
        up = ch if ch % 2 == 1 else ch - 1
        if up + 1 > len(relays):
            raise ValueError("Panjur çifti için bir sonraki röle yok.")
        for index in (up, up + 1):
            current = relays[index - 1]
            if not current["type"].startswith("shutter"):
                _break_pair(template, index)
        runtime = relays[up - 1].get("runtime_s") or relays[up].get("runtime_s") or runtime_s
        for index, direction in ((up, "shutter_up"), (up + 1, "shutter_down")):
            relay = relays[index - 1]
            relay["type"] = direction
            relay["runtime_s"] = int(runtime)
            relay.pop("pulse_ms", None)
            _drop_relay_safety(template, index)
        return
    _break_pair(template, ch)
    relay = relays[ch - 1]
    relay["type"] = kind
    relay.pop("runtime_s", None)
    if kind == "impulse":
        relay["pulse_ms"] = int(relay.get("pulse_ms") or pulse_ms)
        _drop_relay_safety(template, ch)
    else:
        relay.pop("pulse_ms", None)


def _break_pair(template: dict[str, Any], ch: int) -> None:
    relays = template["relays"]
    current = relays[ch - 1]["type"]
    partner = None
    if current == "shutter_up" and ch < len(relays):
        partner = ch + 1
    elif current == "shutter_down" and ch > 1:
        partner = ch - 1
    for index in (ch, partner):
        if index is None:
            continue
        relay = relays[index - 1]
        if relay["type"].startswith("shutter"):
            relay["type"] = "light"
            relay.pop("runtime_s", None)
    up = ch if current == "shutter_up" else partner if current == "shutter_down" else None
    if up:
        for item in template["dis"]:  # artık panjur olmayan röleyi hedefleyen panjur kipleri düz anahtara döner
            if item["target_relay"] == up and item["mode"].startswith("shutter_"):
                item["mode"] = "toggle"


def _drop_relay_safety(template: dict[str, Any], ch: int) -> None:
    safety = template["safety"]
    safety["actuators"] = [a for a in safety.get("actuators", []) if ch not in (a.get("relay"), a.get("relay2"))]
    safety["lights"] = [light for light in safety.get("lights", []) if light.get("relay") != ch]


def set_shutter_runtime(template: dict[str, Any], ch: int, runtime_s: int) -> None:
    """Panjur çiftinin iki rölesine aynı süreyi yazar."""
    up = ch if ch % 2 == 1 else ch - 1
    for index in (up, up + 1):
        relay = template["relays"][index - 1]
        if relay["type"].startswith("shutter"):
            relay["runtime_s"] = int(runtime_s)


def di_sensor(template: dict[str, Any], ch: int) -> Optional[dict[str, Any]]:
    sensor_id = f"d{ch}"
    return next((s for s in template["safety"].get("sensors", []) if s.get("id") == sensor_id), None)


def set_di_sensor(
    template: dict[str, Any],
    ch: int,
    kind: Optional[str],
    *,
    zone: int = 1,
    normally_closed: bool = False,
    name: str = "",
) -> None:
    """DI ``ch``'yi güvenlik sensörü (ya da kumanda rolü) yapar/geri alır. Sensör olan girişin hedef rölesi 0 olur.
    Gaz/duman/anahtarlı kontak her zaman NC'dir (README). Sensör adı en çok 19 bayta kısaltılır."""
    sensors = template["safety"].setdefault("sensors", [])
    sensor_id = f"d{ch}"
    existing = di_sensor(template, ch)
    if not kind:
        if existing is not None:
            sensors.remove(existing)
        return
    if kind not in SENSOR_KINDS:
        raise ValueError("Bilinmeyen sensör türü.")
    item = template["dis"][ch - 1]
    item["target_relay"], item["mode"] = 0, "toggle"
    active_open = 1 if (normally_closed or kind in ("gas", "smoke", "arm_key")) else 0
    sensor = {"id": sensor_id, "kind": kind, "zone": int(zone) if kind not in CONTROL_KINDS else int(zone or 0),
              "active_open": active_open, "name": truncate_utf8(name or item["name"], SAFETY_NAME_BYTES)}
    if existing is not None:
        sensors[sensors.index(existing)] = sensor
    else:
        sensors.append(sensor)
        sensors.sort(key=_sensor_sort_key)


def _sensor_sort_key(sensor: dict[str, Any]) -> tuple[int, int]:
    parsed = parse_sensor_id(sensor.get("id")) or ("bridge", 99)
    return (0 if parsed[0] == "di" else 1, parsed[1])


def light_option(template: dict[str, Any], ch: int) -> Optional[dict[str, Any]]:
    return next((light for light in template["safety"].get("lights", []) if light.get("relay") == ch), None)


def set_light_dimmer(template: dict[str, Any], ch: int, dimmable: bool, *, src: int = 1, addr: int = 0, dim_ch: int = 0) -> None:
    """K4: lamba rölesine parlaklık (dimmer) seçeneği. ``dimmable=False`` kaydı siler."""
    lights = template["safety"].setdefault("lights", [])
    existing = light_option(template, ch)
    if existing is not None:
        lights.remove(existing)
    if dimmable:
        lights.append({"relay": ch, "dimmable": 1, "src": int(src), "addr": int(addr), "ch": int(dim_ch)})
        lights.sort(key=lambda light: light["relay"])


def dimmer_guidance(light: Optional[dict[str, Any]], relay_name: str = "") -> str:
    """K4 dimmer yerleşim yönergesi (PDF ve düzenleyici). Parlaklık için röle kontağı yetmez: dimmer modülü gerekir."""
    who = f"'{relay_name}' " if relay_name else ""
    if not light or not light.get("dimmable"):
        return f"{who}aç/kapa lamba: röle çıkışı doğrudan lamba hattını anahtarlar; dimmer gerekmez."
    src = light.get("src", 0)
    if src == 1:
        return (
            f"{who}parlaklık ayarlı: Modbus dimmer modülü gerekir (adres {light.get('addr', 0)}, kanal {light.get('ch', 0)}). "
            "Dimmeri lambaya en yakın buat/sıva altı kutusuna ya da pano içine koyun; RS485 hattını (A/B) panodan "
            "dimmere taşıyın. Röle çıkışı dimmerin beslemesini keser (ana anahtar). Dimmer lamba tipine uygun olmalı "
            "(LED: kısılabilir LED + kenar kesmeli dimmer)."
        )
    if src == 2:
        return (
            f"{who}parlaklık ayarlı: kablosuz (köprü) dimmer gerekir (köprü adresi {light.get('addr', 0)}, kanal "
            f"{light.get('ch', 0)}). Dimmeri lamba buatına takın; röle çıkışı dimmer beslemesini keser. Köprünün "
            "kapsama alanında olduğundan emin olun."
        )
    return f"{who}parlaklık ayarlı işaretli ama dimmer kaynağı seçilmemiş: dimmer kaynağını (Modbus/köprü) belirleyin."


def truncate_utf8(text: str, max_bytes: int) -> str:
    """UTF-8 bayt sınırına karakter bölmeden kısaltır."""
    data = (text or "").encode("utf-8")
    if len(data) <= max_bytes:
        return text or ""
    return data[:max_bytes].decode("utf-8", errors="ignore")


def strip_for_save(template: dict[str, Any]) -> dict[str, Any]:
    """Sunucuya gidecek gövdenin kopyası (taslak kimliği korunur; sunucu meta.template_id/version'ı kendisi doldurur)."""
    return copy.deepcopy(template)


def duplicate_template(template: dict[str, Any], new_name: str) -> dict[str, Any]:
    """Çoğaltma: aynı içerik, yeni ad, taslak kimlik/sürüm 1."""
    body = copy.deepcopy(template)
    body["meta"]["template_id"] = PLACEHOLDER_ID
    body["meta"]["version"] = 1
    body["meta"]["name"] = truncate_utf8(new_name, META_NAME_BYTES) or "Kopya"
    return body


# ---------------------------------------------------------------------------
# Kart uygulama zarfı ve seri TPL parçalama (README "Kartta uygulama zarfı", "Seri protokol")
# ---------------------------------------------------------------------------
def default_label(site_name: str = "", block: str = "", number: Any = "", template: Optional[dict[str, Any]] = None) -> str:
    """Kart adı (device_name): ``"<site> <blok>-<no>"``; daire yoksa şablon adı. En çok 31 bayt."""
    if site_name and (block or number not in ("", None)):
        label = f"{site_name} {block}-{number}" if block else f"{site_name} {number}"
    elif template is not None:
        label = str(template.get("meta", {}).get("name") or "")
    else:
        label = site_name
    return truncate_utf8(" ".join(label.split()), LABEL_BYTES)


def envelope_bytes(template: dict[str, Any], label: str = "") -> bytes:
    """``{"template": ..., "label": ...}`` UTF-8 JSON baytları (en çok 24576 bayt)."""
    if not _clean_text(label, 0, LABEL_BYTES):
        raise ValueError("Kart adı en çok 31 bayt olmalı ve kontrol karakteri içermemeli.")
    body: dict[str, Any] = {"template": template}
    if label:
        body["label"] = label
    data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_ENVELOPE_BYTES:
        raise ValueError("Şablon karta göre çok büyük (en çok 24 KB).")
    return data


def crc32_hex(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def serial_chunks(data: bytes, chunk_bytes: int = SERIAL_CHUNK_BYTES) -> list[str]:
    """Her parça bağımsız çözülebilen base64 (≤150 karakter)."""
    return [base64.b64encode(data[i : i + chunk_bytes]).decode("ascii") for i in range(0, len(data), chunk_bytes)]


def flat_info_line(block: Any = "", number: Any = "", flat_type: str = "", version: Any = None) -> str:
    """Etiket/PDF daire satırı: ``"A Blok / Daire 12 · 3+1 · Şablon v4"`` (boş parçalar atlanır)."""
    parts: list[str] = []
    place = []
    if block not in ("", None):
        block_text = str(block).strip()
        place.append(block_text if "blok" in block_text.lower() else f"{block_text} Blok")
    if number not in ("", None):
        place.append(f"Daire {number}")
    if place:
        parts.append(" / ".join(place))
    if flat_type:
        parts.append(str(flat_type))
    if version not in ("", None):
        parts.append(f"Şablon v{version}")
    return " · ".join(parts)
