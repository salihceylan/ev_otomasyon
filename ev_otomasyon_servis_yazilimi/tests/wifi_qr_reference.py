# -*- coding: utf-8 -*-
"""Uygulamanın Wi-Fi karekod ayrıştırıcısının (lib/utils/wifi_qr_parser.dart, WifiQrParser.parseDetailed) Python'daki
referans karşılığı - YALNIZCA test içindir (test modülü değil, yardımcı modüldür).

Aynı kaçış kuralları (ters bölü + herhangi bir karakter -> o karakter; çift tırnak sarmalama; alan sırası serbest) ve aynı
doğrulama sınırları (SSID <= 32 bayt, WPA parolası 8..63 bayt, kontrol karakteri yok, EAP/WEP reddi) uygulanır. Doğruluğu,
uygulamanın kendi test vektörleriyle (tests/test_wifi_label.py::ReferenceParserTests) sınanır.
"""
from types import SimpleNamespace


class WifiQrRefError(Exception):
    """Uygulamanın WifiQrError değerlerine karşılık gelen kod (notWifi, tooLong, malformed, ...)."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _ends_with_unescaped_quote(value):
    if not value.endswith('"'):
        return False
    backslashes = 0
    index = len(value) - 2
    while index >= 0 and value[index] == "\\":
        backslashes += 1
        index -= 1
    return backslashes % 2 == 0


def _has_control_characters(value):
    return any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value)


def _decode_field(raw_value):
    inner = raw_value
    if len(inner) >= 2 and inner.startswith('"') and _ends_with_unescaped_quote(inner):
        inner = inner[1:-1]
    out = []
    index = 0
    while index < len(inner):
        ch = inner[index]
        if ch == "\\" and index + 1 < len(inner):
            index += 1
            out.append(inner[index])
        else:
            out.append(ch)
        index += 1
    return "".join(out)


def reference_parse_wifi_qr(raw):
    """Dart WifiQrParser.parseDetailed'in birebir Python karşılığı. Başarıda (ssid, password, security, hidden) içeren
    SimpleNamespace döndürür; reddedilirse ``WifiQrRefError(kod)`` fırlatır."""
    if raw is None:
        raise WifiQrRefError("notWifi")
    text = raw.strip()
    if len(text) < 5 or text[:5].upper() != "WIFI:":
        raise WifiQrRefError("notWifi")
    if len(text) > 512:
        raise WifiQrRefError("tooLong")

    raw_fields = {}
    key, value = [], []
    state = {"reading_key": True}

    def flush():
        k = "".join(key).strip().upper()
        if k and k not in raw_fields:
            raw_fields[k] = "".join(value)
        key.clear()
        value.clear()
        state["reading_key"] = True

    pending_escape = False
    for ch in text[5:]:
        sink = key if state["reading_key"] else value
        if pending_escape:
            sink.append("\\")
            sink.append(ch)
            pending_escape = False
        elif ch == "\\":
            pending_escape = True
        elif ch == ";":
            flush()
        elif ch == ":" and state["reading_key"]:
            state["reading_key"] = False
        else:
            sink.append(ch)
    if pending_escape:
        raise WifiQrRefError("malformed")
    flush()

    ssid = _decode_field(raw_fields.get("S", ""))
    security = _decode_field(raw_fields.get("T", "")).strip().upper()
    password = _decode_field(raw_fields.get("P", ""))
    hidden = _decode_field(raw_fields.get("H", "")).strip().lower() == "true"

    if any(name in raw_fields for name in ("E", "A", "I", "PH2")) or "EAP" in security:
        raise WifiQrRefError("eapUnsupported")
    if security == "WEP":
        raise WifiQrRefError("wepUnsupported")
    if security == "":
        is_open = password == ""
    elif security == "NOPASS":
        is_open = True
    elif security.startswith("WPA") or security == "SAE":
        is_open = False
    else:
        raise WifiQrRefError("unknownSecurity")

    if not ssid:
        raise WifiQrRefError("missingSsid")
    if len(ssid.encode("utf-8")) > 32:
        raise WifiQrRefError("ssidTooLong")
    if _has_control_characters(ssid):
        raise WifiQrRefError("controlCharacters")
    if is_open:
        return SimpleNamespace(ssid=ssid, password="", security="nopass", hidden=hidden)
    if _has_control_characters(password):
        raise WifiQrRefError("controlCharacters")
    size = len(password.encode("utf-8"))
    if size < 8 or size > 63:
        raise WifiQrRefError("passwordLength")
    return SimpleNamespace(ssid=ssid, password=password, security="WPA", hidden=hidden)
