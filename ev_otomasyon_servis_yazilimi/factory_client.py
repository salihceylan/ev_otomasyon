# -*- coding: utf-8 -*-
"""
AHBU fabrika/servis aracı - ağ ve güvenlik katmanı (yalnızca standart kütüphane, Tk'siz).

Bu modül ``ev_otomasyon_sistemi.py`` (Tk arayüzü) tarafından kullanılır; arayüzden bağımsız
test edilebilsin diye ayrıdır. İçerik:

* Güvenli üreticiler: kurulum PIN'i (``secrets``), cihaza özel AP parolası, MAC -> UID / AP SSID.
* Etiket karekod metinleri: PIN'li claim adresi (1. karekod) ve kurulum/kurtarma Wi-Fi karekodu
  ``WIFI:T:WPA;S:<AP SSID>;P:<ap_pass>;;`` (2. karekod; kaçışlı; AP parolasını içerdiği için GİZLİ değerdir).
* ``ServerClient``: süper kullanıcı e-posta + parola ile ``POST /api/v1/auth/login`` -> Bearer
  (401 ``TOKEN_EXPIRED`` ise tek seferlik refresh) veya isteğe bağlı ``ADMIN_API_KEY`` ortam
  değişkeni ile ``x-api-key``. Parola hiçbir yerde saklanmaz.
* ``SerialProvisioner``: TERCİH EDİLEN provizyon yolu - USB seri üzerinden ``FACTORYINIT`` (anahtar kablosuz
  ağdan/düz HTTP'den geçmez), ``STATUS`` ile doğrulama - docs/CONTRACTS.md §3c. pyserial yoksa PlatformIO penv
  gibi başka bir yorumlayıcıdaki pyserial röle üzerinden kullanılır (yeni paket KURULMAZ).
* ``DeviceClient``: YEDEK (güvensiz) yol - açık kurulum AP'si + düz HTTP: ``POST /api/factory/init`` ve
  doğrulama ``GET /api/auth/check`` - docs/CONTRACTS.md §3.
* Hata çevirisi: sunucu/cihaz hataları kullanıcıya Türkçe, ham gövde/istisna göstermeden.
* ``SecretScrubber``: log/ekran metninden bellekteki gizli değerleri maskeler.

Güvenlik ilkeleri: sabit sır yok; TLS doğrulaması her zaman açık; düz ``http`` yalnızca
loopback; yönlendirme (redirect) izlenmez (yetki başlığı başka ana makineye gitmesin);
cihaz adresi yalnızca yerel/özel ağ olabilir (anahtar internete sızmasın); tüm ağ
çağrılarında zaman aşımı ve yanıt boyut sınırı vardır.
"""

from __future__ import annotations

import binascii
import functools
import http.client
import ipaddress
import json
import os
import queue
import re
import secrets
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Mapping, Optional

import template_model as tm

# ---------------------------------------------------------------------------
# Sabitler
# ---------------------------------------------------------------------------
DEFAULT_SERVER_URL = "https://evotomasyon.gudeteknoloji.com.tr"
DEFAULT_DEVICE_HOST = "192.168.4.1"  # cihaz kurulum/kurtarma AP adresi (CONTRACTS §3)

ENV_SERVER_URL = "EV_SERVER_URL"          # QA için: http://127.0.0.1:5000
ENV_DEVICE_HOST = "EV_DEVICE_AP_HOST"     # QA için: 127.0.0.1:8081 (firmware simülatörü)
ENV_API_KEY = "ADMIN_API_KEY"             # isteğe bağlı makine anahtarı (>= 32 karakter)
MIN_API_KEY_LENGTH = 32

API_PREFIX = "/api/v1"
USER_AGENT = "AHBU-FabrikaAraci/2.0"
SERVER_TIMEOUT_S = 15.0
DEVICE_TIMEOUT_S = 6.0
MAX_RESPONSE_BYTES = 1024 * 1024

PIN_LENGTH = 6
AP_PASS_LENGTH = 10
AP_PASS_MIN_LEN = 8       # firmware: ap_pass 8..32 (SystemConfig.h)
AP_PASS_MAX_LEN = 32
LOCAL_KEY_MIN_LEN = 8     # firmware: local_key 8..32, yazdırılabilir ASCII, boşluksuz
LOCAL_KEY_MAX_LEN = 32

# Karışan karakterler (0/O, 1/l/I, i, o) çıkarıldı: etiketten elle okunabilsin.
AP_PASS_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"

UID_PATTERN = re.compile(r"^AHBU-[A-Z0-9-]{3,32}$")
PIN_PATTERN = re.compile(r"^\d{6}$")
LABEL_TEXT_PATTERN = re.compile(r"^[A-Za-z0-9 ._\-/]{1,64}$")
_API_CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{1,40}$")
_ERROR_REF_PATTERN = re.compile(r"^[0-9a-f]{6,24}$")
_DETAIL_CODE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{1,40}$")
_FIELD_PATH_PATTERN = re.compile(r"^[A-Za-z0-9_.\[\]]{1,64}$")
_RESOURCE_ID_PATTERN = re.compile(r"^[A-Za-z0-9-]{1,64}$")
# Aracı kullanabilen roller (İP-3.1): süper kullanıcı (her şey) ve servis sorumlusu (site/şablon/karta yazım; envanter kaydı,
# durum değiştirme ve silme YOK - sunucu da reddeder).
TOOL_ROLES = ("super_user", "service_user")
ROLE_TEXT = {"super_user": "süper kullanıcı", "service_user": "servis sorumlusu", "api_key": "API anahtarı"}

ProgressCallback = Callable[[str], None]


# ---------------------------------------------------------------------------
# Hata sınıfları (str(exc) = kullanıcıya gösterilebilir Türkçe mesaj)
# ---------------------------------------------------------------------------
class FactoryError(Exception):
    """Kullanıcıya doğrudan gösterilebilen hata; ham sunucu/istisna metni içermez."""

    def __init__(self, message: str, *, code: Optional[str] = None) -> None:
        super().__init__(message)
        self.message = message
        self.code = code


class NetworkError(FactoryError):
    """Bağlantı kurulamadı / zaman aşımı / TLS sorunu."""


class ApiError(FactoryError):
    """Sunucu HTTP hata yanıtı (``{success:false, message, code}``)."""

    def __init__(
        self,
        message: str,
        *,
        status: int = 0,
        code: Optional[str] = None,
        retry_after: Optional[int] = None,
        detail: Optional[str] = None,
        path: Optional[str] = None,
    ) -> None:
        super().__init__(message, code=code)
        self.status = status
        self.retry_after = retry_after
        self.detail = detail  # ör. şablon doğrulama kodu (422 TEMPLATE_INVALID -> "invalid_runtime"); yalnız güvenli biçimde
        self.path = path      # ör. "relays[3].runtime_s"


class SessionExpiredError(ApiError):
    """Oturum yok / süresi doldu / iptal edildi: yeniden giriş gerekir."""


class ProvisionError(FactoryError):
    """Cihaz provizyonu hatası. ``hint`` = "Ne yapmalıyım?" açıklaması."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        hint: str = "",
        retry_after: Optional[int] = None,
    ) -> None:
        super().__init__(message, code=code)
        self.hint = hint
        self.retry_after = retry_after


# ---------------------------------------------------------------------------
# Gizli değer maskeleme
# ---------------------------------------------------------------------------
class SecretScrubber:
    """Bellekteki gizli değerleri (token, anahtar, PIN, parola) log/ekran metninden siler."""

    MIN_LENGTH = 4

    def __init__(self) -> None:
        self._values: set[str] = set()
        self._lock = threading.Lock()

    def add(self, *values: Optional[str]) -> None:
        with self._lock:
            for value in values:
                if isinstance(value, str) and len(value) >= self.MIN_LENGTH:
                    self._values.add(value)

    def discard(self, *values: Optional[str]) -> None:
        with self._lock:
            for value in values:
                if isinstance(value, str):
                    self._values.discard(value)

    def clear(self) -> None:
        with self._lock:
            self._values.clear()

    def scrub(self, text: str) -> str:
        if not isinstance(text, str) or not text:
            return text
        with self._lock:
            values = sorted(self._values, key=len, reverse=True)
        for value in values:
            if value in text:
                text = text.replace(value, "***")
        return text


# ---------------------------------------------------------------------------
# Güvenli üreticiler ve biçim yardımcıları
# ---------------------------------------------------------------------------
def generate_setup_pin() -> str:
    """6 haneli kurulum PIN'i (000000-999999). Yalnızca ``secrets`` (CSPRNG) kullanılır."""
    return f"{secrets.randbelow(10 ** PIN_LENGTH):0{PIN_LENGTH}d}"


def generate_ap_pass(length: int = AP_PASS_LENGTH) -> str:
    """Cihaza özel rastgele AP parolası (karışık karakterlerden arındırılmış alfabe, ``secrets``)."""
    if not AP_PASS_MIN_LEN <= length <= AP_PASS_MAX_LEN:
        raise ValueError("AP parolası uzunluğu 8..32 olmalıdır.")
    return "".join(secrets.choice(AP_PASS_ALPHABET) for _ in range(length))


_MAC_PATTERN = re.compile(r"^(?:[0-9A-Fa-f]{2}[:\-]?){5}[0-9A-Fa-f]{2}$")


def normalize_mac(raw: Any) -> Optional[str]:
    """``e8:f6:0a:dd:87:54`` / ``E8-F6-...`` / ``e8f60add8754`` -> ``E8:F6:0A:DD:87:54``; geçersizse None."""
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if not _MAC_PATTERN.match(text):
        return None
    digits = re.sub(r"[^0-9A-Fa-f]", "", text).upper()
    if len(digits) != 12:
        return None
    return ":".join(digits[i : i + 2] for i in range(0, 12, 2))


def uid_from_mac(mac: Any) -> Optional[str]:
    """Firmware ile aynı kural: ``AHBU-S3-<MAC son 6 hex, büyük harf>`` (WiFiManager::getDeviceUid)."""
    normalized = normalize_mac(mac)
    if normalized is None:
        return None
    return "AHBU-S3-" + normalized.replace(":", "")[-6:]


def ap_ssid_from_mac(mac: Any) -> Optional[str]:
    """Firmware ile aynı kural: ``AHBU-<MAC son 6 hex>`` (WiFiManager::apSsid; 11 karakter)."""
    normalized = normalize_mac(mac)
    if normalized is None:
        return None
    return "AHBU-" + normalized.replace(":", "")[-6:]


def is_valid_local_key(value: Any) -> bool:
    """Firmware kuralı: 8..32 karakter, yazdırılabilir ASCII (0x21-0x7E), boşluksuz."""
    return (
        isinstance(value, str)
        and LOCAL_KEY_MIN_LEN <= len(value) <= LOCAL_KEY_MAX_LEN
        and all(0x21 <= ord(ch) <= 0x7E for ch in value)
    )


def is_valid_ap_pass(value: Any) -> bool:
    """Firmware kuralı: 8..32 karakter, yazdırılabilir ASCII (0x20-0x7E)."""
    return (
        isinstance(value, str)
        and AP_PASS_MIN_LEN <= len(value) <= AP_PASS_MAX_LEN
        and all(0x20 <= ord(ch) <= 0x7E for ch in value)
    )


# ---------------------------------------------------------------------------
# Adres yardımcıları
# ---------------------------------------------------------------------------
def _is_loopback_host(host: str) -> bool:
    name = host.strip("[]").lower()
    if name == "localhost":
        return True
    try:
        return ipaddress.ip_address(name).is_loopback
    except ValueError:
        return False


def _is_local_network_host(host: str) -> bool:
    """localhost, loopback, özel (RFC1918) veya link-local IP."""
    name = host.strip("[]").lower()
    if name == "localhost":
        return True
    try:
        ip = ipaddress.ip_address(name)
    except ValueError:
        return False
    return ip.is_loopback or ip.is_private or ip.is_link_local


def normalize_server_url(raw: Optional[str]) -> str:
    """Sunucu adresini ``https://host[:port]`` köküne çevirir.

    * Sondaki ``/``, ``/api``, ``/api/v1`` atılır (Flutter ``API_BASE_URL`` biçimi de kabul edilir).
    * Düz ``http`` yalnızca loopback (QA: ``http://127.0.0.1:5000``); aksi halde parola düz metin
      gider -> ``ValueError``.
    * Kullanıcı bilgisi (``user:pass@``), sorgu ve parça reddedilir.
    """
    text = (raw or "").strip()
    if not text:
        return DEFAULT_SERVER_URL
    if "://" not in text:
        text = "https://" + text
    try:
        parts = urllib.parse.urlsplit(text)
        port = parts.port  # geçersiz port ValueError verir
    except ValueError as exc:
        raise ValueError("Sunucu adresi geçersiz.") from exc
    scheme = parts.scheme.lower()
    host = (parts.hostname or "").lower()
    if scheme not in ("http", "https") or not host:
        raise ValueError("Sunucu adresi http(s)://alan-adı biçiminde olmalıdır.")
    if parts.username is not None or parts.password is not None or "@" in parts.netloc:
        raise ValueError("Sunucu adresi kullanıcı adı/parola içeremez.")
    if parts.query or parts.fragment:
        raise ValueError("Sunucu adresi yalnızca alan adı (ve isteğe bağlı port) olmalıdır.")
    path = parts.path.rstrip("/")
    for suffix in ("/api/v1", "/api"):
        if path.lower().endswith(suffix):
            path = path[: -len(suffix)].rstrip("/")
            break
    if path:
        raise ValueError("Sunucu adresi yalnızca alan adı (ve isteğe bağlı port) olmalıdır.")
    if scheme == "http" and not _is_loopback_host(host):
        raise ValueError(
            "Düz http yalnızca yerel test (127.0.0.1) için kabul edilir; parola düz metin gönderilmez. "
            "Lütfen https:// adresi kullanın."
        )
    shown_host = f"[{host}]" if ":" in host else host
    return f"{scheme}://{shown_host}" + (f":{port}" if port else "")


def normalize_device_host(raw: Optional[str]) -> str:
    """Cihaz AP adresi ``host[:port]``. Yalnızca localhost / özel / loopback / link-local IP kabul edilir
    (yerel anahtar ve AP parolası internete gönderilemesin)."""
    text = (raw or "").strip()
    if not text:
        return DEFAULT_DEVICE_HOST
    if any(ch in text for ch in "/?#@ \t\r\n\\") or "://" in text:
        raise ValueError("Cihaz adresi 'host' veya 'host:port' biçiminde olmalıdır.")
    try:
        parts = urllib.parse.urlsplit("http://" + text)
        port = parts.port
    except ValueError as exc:
        raise ValueError("Cihaz adresi geçersiz.") from exc
    host = (parts.hostname or "").lower()
    if not host:
        raise ValueError("Cihaz adresi geçersiz.")
    if not _is_local_network_host(host):
        raise ValueError("Cihaz adresi yalnızca yerel ağ (özel IP) adresi olabilir.")
    shown_host = f"[{host}]" if ":" in host else host
    return shown_host + (f":{port}" if port else "")


def build_claim_url(uid: str, pin: str, base: str = DEFAULT_SERVER_URL) -> str:
    """Etiket karekodu içeriği: ``https://<host>/claim?uid=<UID>&pin=<PIN>`` (QrClaimParser biçimi)."""
    query = urllib.parse.urlencode([("uid", uid), ("pin", pin)])
    return f"{base.rstrip('/')}/claim?{query}"


def parse_claim_url(url: Any) -> Optional[tuple[str, str]]:
    """``/claim?uid=..&pin=..`` adresini sıkı biçimde çözer; geçersizse None (host izin listesi uygulamada)."""
    if not isinstance(url, str) or not url or len(url) > 512:
        return None
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in url):
        return None
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.path != "/claim":
        return None
    query = urllib.parse.parse_qs(parts.query, keep_blank_values=True)
    uids, pins = query.get("uid", []), query.get("pin", [])
    if len(uids) != 1 or len(pins) != 1:
        return None
    uid, pin = uids[0].strip().upper(), pins[0].strip()
    if not UID_PATTERN.match(uid) or not PIN_PATTERN.match(pin):
        return None
    return uid, pin


def claim_url_matches(url: Any, uid: str, pin: str) -> bool:
    parsed = parse_claim_url(url)
    return parsed is not None and parsed == (uid.strip().upper(), pin)


# ---------------------------------------------------------------------------
# Etiketin 2. karekodu: kurulum/kurtarma Wi-Fi ağı (standart "Wi-Fi karekodu")
# ---------------------------------------------------------------------------
# Telefon kamerası (Android / iOS 11+) bu karekodu okuyup "ağa bağlan" önerir; uygulamanın WifiQrParser'ı da aynı
# kaçış kurallarını çözer. Karekod AP parolasını içerir: üretilen metin GİZLİ değerdir (loglanmaz, ekrana yazılmaz).
WIFI_QR_ESCAPED_CHARS = frozenset('\\;,:"')  # ters bölü ; , : çift tırnak
WIFI_SSID_MAX_BYTES = 32
WIFI_WPA_PASSWORD_MIN = 8
WIFI_WPA_PASSWORD_MAX = 63


def escape_wifi_qr_value(value: str) -> str:
    """Wi-Fi karekodu alan değerini kaçışlar: ters bölü, noktalı virgül, virgül, iki nokta ve çift tırnağın önüne
    ters bölü konur; diğer karakterler (boşluk dahil) aynen kalır."""
    return "".join("\\" + ch if ch in WIFI_QR_ESCAPED_CHARS else ch for ch in value)


def _has_control_chars(value: str) -> bool:
    return any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value)


def wifi_qr_payload(ssid: str, password: str) -> str:
    """WPA/WPA2 ağı için standart Wi-Fi karekodu metni: ``WIFI:T:WPA;S:<ssid>;P:<parola>;;``.

    Uygulamanın WifiQrParser sınırları uygulanır (SSID 1..32 bayt, WPA parolası 8..63 bayt, kontrol karakteri yok).
    Geçersiz girdide ``ValueError`` (ileti parolayı/SSID'yi içermez)."""
    if not isinstance(ssid, str) or not ssid:
        raise ValueError("Wi-Fi ağ adı (SSID) boş olamaz.")
    if len(ssid.encode("utf-8")) > WIFI_SSID_MAX_BYTES:
        raise ValueError("Wi-Fi ağ adı (SSID) 32 baytı aşamaz.")
    if _has_control_chars(ssid):
        raise ValueError("Wi-Fi ağ adında (SSID) kontrol karakteri olamaz.")
    if not isinstance(password, str) or not WIFI_WPA_PASSWORD_MIN <= len(password.encode("utf-8")) <= WIFI_WPA_PASSWORD_MAX:
        raise ValueError("Wi-Fi parolası 8 ile 63 karakter arasında olmalıdır.")
    if _has_control_chars(password):
        raise ValueError("Wi-Fi parolasında kontrol karakteri olamaz.")
    return f"WIFI:T:WPA;S:{escape_wifi_qr_value(ssid)};P:{escape_wifi_qr_value(password)};;"


def device_wifi_qr_payload(mac: Any, ap_pass: Any) -> str:
    """Cihazın kurulum/kurtarma ağı için 2. karekod metni. SSID kuralı firmware ile aynıdır (``AHBU-`` + MAC son 6
    hex, büyük harf: ``ap_ssid_from_mac``); parola etikette yazan ``ap_pass``'tir (firmware: 8..32 karakter, ASCII
    0x20-0x7E). Geçersiz MAC/parolada ``ValueError``."""
    ssid = ap_ssid_from_mac(mac)
    if ssid is None:
        raise ValueError("Geçerli bir MAC adresi olmadan kurulum ağı adı üretilemez.")
    if not is_valid_ap_pass(ap_pass):
        raise ValueError("AP parolası firmware kuralına uymuyor (8-32 karakter, yazdırılabilir ASCII).")
    return wifi_qr_payload(ssid, ap_pass)


# ---------------------------------------------------------------------------
# Hata metinlerinin Türkçeleştirilmesi
# ---------------------------------------------------------------------------
_UNSAFE_MESSAGE = re.compile(
    r"(?i)(select\s|insert\s|update\s|delete\s|constraint|violates|traceback|exception|stack|"
    r"econn|enotfound|\bat\s+\S+\.(?:js|ts)\b|\bpg_|sequelize|node_modules|\bsql\b)"
)


def safe_server_message(message: Any) -> Optional[str]:
    """Sunucunun ``message`` alanını yalnızca zararsız/kısa düz metinse döndürür (aksi halde None)."""
    if not isinstance(message, str):
        return None
    text = re.sub(r"[\x00-\x1f\x7f]", " ", message)
    text = " ".join(text.split())
    if not text or len(text) > 200:
        return None
    if re.search(r"<[^>]*>", text) or "{" in text or "}" in text:
        return None
    if _UNSAFE_MESSAGE.search(text):
        return None
    return text


def _format_wait(seconds: Optional[int]) -> str:
    if not seconds or seconds <= 0:
        return "biraz"
    value = int(seconds)
    if value < 90:
        return f"{value} saniye"
    return f"{(value + 59) // 60} dakika"


DEVICE_NOT_IN_STOCK_TEXT = (
    "Bu kart stokta değil (müşteriye ait ya da askıda); Ethernet ile şablon yazılamaz — USB kullanın veya ev üzerinden işlem yapın."
)


def friendly_api_error(
    status: int,
    code: Optional[str] = None,
    server_message: Any = None,
    retry_after: Optional[int] = None,
    error_ref: Optional[str] = None,
) -> str:
    """Sunucu hata yanıtını (CONTRACTS §1.1) kullanıcıya gösterilebilir Türkçe metne çevirir.

    5xx ve kimlik/yetki/hız sınırı hatalarında sunucu metni hiç gösterilmez; yalnızca 400/404/409/410
    gibi alan hatalarında, zararsız ve kısaysa sunucunun Türkçe mesajı kullanılır.
    """
    safe = safe_server_message(server_message)
    wait = _format_wait(retry_after)

    if status >= 500:
        by_code = {
            "SERVICE_UNAVAILABLE": "Sunucudaki ilgili özellik şu anda kullanılamıyor (yapılandırma eksik olabilir). "
            "Sistem yöneticisine bildirin.",
            "DELIVERY_FAILED": "Sunucu e-posta/SMS gönderemedi. Sistem yöneticisine bildirin.",
            "BROKER_UNAVAILABLE": "Sunucu mesaj altyapısına (MQTT) ulaşamadı. Biraz sonra tekrar deneyin.",
        }
        by_status = {
            502: "Sunucu geçidi şu anda yanıt vermiyor. Biraz sonra tekrar deneyin.",
            503: "Sunucu geçici olarak hizmet veremiyor. Biraz sonra tekrar deneyin.",
            504: "Sunucu zamanında yanıt vermedi. Biraz sonra tekrar deneyin.",
        }
        text = by_code.get(code or "") or by_status.get(
            status, "Sunucuda beklenmeyen bir hata oluştu. Biraz sonra tekrar deneyin; sürerse sistem yöneticisine bildirin."
        )
        if error_ref and _ERROR_REF_PATTERN.match(error_ref):
            text += f" (Hata ref: {error_ref})"
        return text

    if 300 <= status < 400:
        return "Sunucu beklenmeyen bir yönlendirme döndürdü. Sunucu adresini (https://...) kontrol edin."

    if status == 401:
        return {
            "INVALID_CREDENTIALS": "E-posta veya parola hatalı.",
            "TOKEN_EXPIRED": "Oturum süresi doldu. Lütfen yeniden giriş yapın.",
            "INVALID_TOKEN": "Oturum geçersiz veya sonlandırılmış. Lütfen yeniden giriş yapın.",
            "SERVICE_SESSION_EXPIRED": "Servis oturumu sona erdi. Lütfen yeniden giriş yapın.",
        }.get(code or "", "Kimlik doğrulaması başarısız. Lütfen yeniden giriş yapın.")

    if status == 403:
        return {
            "ACCOUNT_DISABLED": "Hesap dondurulmuş. Sistem yöneticisine başvurun.",
            "ACCOUNT_PENDING": "Hesap henüz etkinleştirilmemiş (davet bekliyor). Önce hesabı etkinleştirin.",
            "REAUTH_REQUIRED": "Bu hassas işlem için parola ile yeniden doğrulama gerekiyor.",
            "SERVICE_SESSION_FORBIDDEN": "Servis PIN oturumu bu işlem için yeterli değil; e-posta + parola ile giriş yapın.",
        }.get(
            code or "",
            "Bu işlem için yetkiniz yok (envanter kaydı, durum değiştirme ve silme yalnızca süper kullanıcıya açıktır).",
        )

    if status == 423:
        return f"Çok sayıda hatalı deneme nedeniyle geçici olarak kilitlendi. {wait} sonra tekrar deneyin."

    if status == 429:
        return f"Çok fazla istek/deneme yapıldı (hız sınırı). {wait} sonra tekrar deneyin."

    if status == 400:
        return safe or "Gönderilen bilgiler geçersiz. Alanları kontrol edin."
    if status == 404:
        return safe or "Kayıt bulunamadı."
    if status == 409 and code == "DEVICE_NOT_IN_STOCK":
        return DEVICE_NOT_IN_STOCK_TEXT
    if status == 409:
        return safe or "Kayıt zaten mevcut veya mevcut durumla çakışıyor."
    if status == 410:
        return safe or "Kod/bağlantı süresi doldu veya zaten kullanıldı."
    if status == 413:
        return "İstek çok büyük; sunucu reddetti."
    if status == 415:
        return "Sunucu bu içerik türünü kabul etmiyor."
    if status == 405:
        return "Sunucu bu işlemi kabul etmiyor (yöntem desteklenmiyor)."
    return safe or f"Sunucu isteği reddetti (HTTP {status})."


def describe_network_error(exc: BaseException) -> str:
    """Ağ istisnasını (ham metni göstermeden) anlaşılır Türkçe cümleye çevirir."""
    reason: Any = exc.reason if isinstance(exc, urllib.error.URLError) else exc
    if isinstance(reason, ssl.SSLCertVerificationError):
        return "Sunucunun güvenlik sertifikası doğrulanamadı. Sunucu adresini ve bilgisayarın tarih/saatini kontrol edin."
    if isinstance(reason, ssl.SSLError):
        return "Güvenli bağlantı (TLS) kurulamadı. Sunucu adresini kontrol edin."
    if isinstance(reason, (socket.timeout, TimeoutError)):
        return "Sunucu zamanında yanıt vermedi (zaman aşımı). Bağlantınızı kontrol edip tekrar deneyin."
    if isinstance(reason, socket.gaierror):
        return "Sunucu adı çözümlenemedi (DNS). İnternet bağlantınızı ve sunucu adresini kontrol edin."
    if isinstance(reason, ConnectionRefusedError):
        return "Sunucu bağlantıyı reddetti (kapalı olabilir). Sunucu adresini kontrol edin."
    if isinstance(reason, (ConnectionResetError, ConnectionAbortedError, http.client.HTTPException)):
        return "Bağlantı sunucu tarafından kesildi. Biraz sonra tekrar deneyin."
    return (
        "Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin "
        "(bilgisayar cihazın kurulum Wi-Fi ağına bağlıysa internet yoktur; normal ağınıza dönün)."
    )


# ---------------------------------------------------------------------------
# HTTP taşıma katmanı (test için değiştirilebilir)
# ---------------------------------------------------------------------------
@dataclass
class TransportResponse:
    status: int
    headers: dict[str, str] = field(default_factory=dict)  # anahtarlar küçük harf
    body: bytes = b""


Transport = Callable[[str, str, Mapping[str, str], Optional[bytes], float], TransportResponse]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Yönlendirme izlenmez: Authorization başlığı başka ana makineye taşınmasın."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


@functools.lru_cache(maxsize=1)
def _tls_context() -> ssl.SSLContext:
    return ssl.create_default_context()  # sertifika ve ana makine adı doğrulaması AÇIK


def _build_opener(url: str) -> urllib.request.OpenerDirector:
    host = urllib.parse.urlsplit(url).hostname or ""
    handlers: list[Any] = [_NoRedirect(), urllib.request.HTTPSHandler(context=_tls_context())]
    if _is_local_network_host(host):
        handlers.append(urllib.request.ProxyHandler({}))  # yerel/cihaz adresleri için sistem proxy'si kullanılmaz
    return urllib.request.build_opener(*handlers)


def _read_limited(fp: Any) -> bytes:
    data = fp.read(MAX_RESPONSE_BYTES + 1)
    if len(data) > MAX_RESPONSE_BYTES:
        raise NetworkError("Sunucu yanıtı beklenenden çok büyük; işlem durduruldu.")
    return data


def default_transport(
    method: str,
    url: str,
    headers: Mapping[str, str],
    body: Optional[bytes],
    timeout: float,
) -> TransportResponse:
    """Gerçek HTTP çağrısı (urllib). HTTP hata kodları istisna değil ``TransportResponse`` olarak döner;
    ağ sorunları ``NetworkError`` (güvenli Türkçe mesaj) olarak fırlar."""
    request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
    opener = _build_opener(url)
    try:
        with opener.open(request, timeout=timeout) as response:
            data = _read_limited(response)
            return TransportResponse(
                response.status,
                {k.lower(): v for k, v in response.headers.items()},
                data,
            )
    except urllib.error.HTTPError as exc:
        try:
            data = _read_limited(exc)
        except NetworkError:
            raise
        except Exception:  # gövde okunamadı: yalnızca durum kodu yeterli
            data = b""
        finally:
            exc.close()
        return TransportResponse(exc.code, {k.lower(): v for k, v in (exc.headers or {}).items()}, data)
    except NetworkError:
        raise
    except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError) as exc:
        raise NetworkError(describe_network_error(exc)) from None


def parse_json_object(body: bytes) -> Optional[dict[str, Any]]:
    if not body:
        return None
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _parse_retry_after(payload: Optional[dict[str, Any]], headers: Mapping[str, str]) -> Optional[int]:
    candidate: Any = payload.get("retry_after") if payload else None
    if candidate is None:
        candidate = headers.get("retry-after")
    try:
        value = int(float(candidate))
    except (TypeError, ValueError):
        return None
    return value if 0 < value <= 86400 else None


# ---------------------------------------------------------------------------
# Sunucu istemcisi
# ---------------------------------------------------------------------------
@dataclass(repr=False)
class RegistrationResult:
    """``POST /admin/inventory/register`` yanıtı. ``local_key``/QR yalnızca BİR KEZ gelir."""

    device: dict[str, Any]
    local_key: str
    qr_claim_url: str
    qr_from_server: bool = True

    def __repr__(self) -> str:  # sırlar repr'e sızmasın
        return f"RegistrationResult(device_uuid={self.device.get('device_uuid')!r}, <gizli alanlar gizlendi>)"


def _role_rejection(role: str) -> str:
    return (
        "Bu araç yalnızca süper kullanıcı veya servis sorumlusu hesabıyla çalışır "
        f"(bu hesabın rolü: {role or 'bilinmiyor'})."
    )


class ServerClient:
    """AHBU sunucusu için kimlik doğrulamalı istemci (Bearer veya ``x-api-key``)."""

    def __init__(
        self,
        base_url: Optional[str] = None,
        *,
        transport: Optional[Transport] = None,
        env: Optional[Mapping[str, str]] = None,
        scrubber: Optional[SecretScrubber] = None,
        timeout: float = SERVER_TIMEOUT_S,
    ) -> None:
        self._env: Mapping[str, str] = os.environ if env is None else env
        raw = base_url if base_url else self._env.get(ENV_SERVER_URL, "")
        self._base_url = normalize_server_url(raw)
        self._transport = transport
        self._scrubber = scrubber
        self._timeout = timeout
        self._lock = threading.RLock()
        self._access_token: Optional[str] = None
        self._refresh_token: Optional[str] = None
        self._api_key: Optional[str] = None
        self._user: dict[str, Any] = {}
        self.must_change_password = False
        # "Beni hatırla": sunucu refresh token'ı DÖNDÜRDÜĞÜNDE (tek kullanımlık) yenisini alan kanca; hatırlanan oturum
        # yoksa None. Kanca hata verirse oturum bozulmaz (bkz. _notify_rotation).
        self.session_listener: Optional[Callable[[str], None]] = None

    # ---- durum -------------------------------------------------------------
    @property
    def base_url(self) -> str:
        return self._base_url

    @property
    def is_authenticated(self) -> bool:
        return bool(self._api_key or self._access_token)

    @property
    def auth_mode(self) -> Optional[str]:
        if self._api_key:
            return "api_key"
        if self._access_token:
            return "jwt"
        return None

    @property
    def user_email(self) -> str:
        return str(self._user.get("email") or "")

    @property
    def user_role(self) -> str:
        return str(self._user.get("role") or "")

    def set_base_url(self, raw: Optional[str]) -> bool:
        """Adresi değiştirir; farklıysa belirteçler başka sunucuya gitmesin diye oturum silinir. True = değişti."""
        new_url = normalize_server_url(raw)
        if new_url == self._base_url:
            return False
        self._clear_session()
        self._base_url = new_url
        return True

    def api_key_available(self) -> bool:
        key = self._env.get(ENV_API_KEY, "")
        return isinstance(key, str) and len(key) >= MIN_API_KEY_LENGTH

    # ---- oturum ------------------------------------------------------------
    def _track(self, *values: Optional[str]) -> None:
        if self._scrubber is not None:
            self._scrubber.add(*values)

    def _clear_session(self) -> None:
        with self._lock:
            if self._scrubber is not None:
                self._scrubber.discard(self._access_token, self._refresh_token, self._api_key)
            self._access_token = self._refresh_token = self._api_key = None
            self._user = {}
            self.must_change_password = False

    def use_api_key(self) -> None:
        """``ADMIN_API_KEY`` ortam değişkenini ``x-api-key`` olarak kullanır (>= 32 karakter)."""
        key = self._env.get(ENV_API_KEY, "")
        if not isinstance(key, str) or len(key) < MIN_API_KEY_LENGTH:
            raise FactoryError(
                f"{ENV_API_KEY} ortam değişkeni tanımlı değil veya {MIN_API_KEY_LENGTH} karakterden kısa."
            )
        self._clear_session()
        with self._lock:
            self._api_key = key
            self._user = {"email": "(API anahtarı)", "role": "api_key"}
        self._track(key)

    def login(self, email: str, password: str) -> dict[str, Any]:
        """E-posta + parola ile giriş. Parola saklanmaz; rol ``super_user`` ya da ``service_user`` değilse reddedilir."""
        email = (email or "").strip()
        if not email or not password:
            raise FactoryError("E-posta ve parola zorunludur.")
        previous_refresh = self._refresh_token
        data = self._call("POST", "/auth/login", body={"email": email, "password": password}, auth=False)
        access, refresh = data.get("access_token"), data.get("refresh_token")
        user = data.get("user") if isinstance(data.get("user"), dict) else {}
        if not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh:
            raise ApiError("Sunucu yanıtı beklenen oturum bilgisini içermiyor.", status=200, code="BAD_RESPONSE")
        role = str(user.get("role") or "")
        if role not in TOOL_ROLES:
            # Yetkisiz hesap: açılan oturum hemen iptal edilir, belirteçler tutulmaz.
            self._revoke_quietly(refresh)
            raise ApiError(_role_rejection(role), status=403, code="FORBIDDEN")
        self._clear_session()
        with self._lock:
            self._access_token, self._refresh_token = access, refresh
            self._user = {"email": str(user.get("email") or email), "role": role, "name": str(user.get("full_name") or "")}
            self.must_change_password = bool(user.get("must_change_password") or data.get("must_change_password"))
        self._track(access, refresh)
        if previous_refresh and previous_refresh != refresh:
            self._revoke_quietly(previous_refresh)  # hesap değiştirme: eski oturum ailesi sunucuda kapanır
        return dict(self._user)

    def _revoke_quietly(self, refresh_token: Optional[str]) -> None:
        if not refresh_token:
            return
        try:
            self._call("POST", "/auth/logout", body={"refresh_token": refresh_token}, auth=False)
        except FactoryError:
            pass

    def end_session_local(self) -> Optional[str]:
        """Yerel oturumu AĞ ÇAĞRISI YAPMADAN siler; sunucuda iptal edilecek refresh token'ı döndürür."""
        refresh = self._refresh_token
        self._clear_session()
        return refresh

    def revoke_refresh_token(self, refresh_token: Optional[str]) -> None:
        """Refresh token'ı sunucuda en iyi çabayla iptal eder (hata yutulur)."""
        self._revoke_quietly(refresh_token)

    def logout(self) -> None:
        """Yerel oturumu siler; sunucudaki refresh ailesini en iyi çabayla iptal eder."""
        self.revoke_refresh_token(self.end_session_local())

    # ---- hatırlanan oturum ("Beni hatırla"): geriye uyumlu eklemeler ---------
    def current_refresh_token(self) -> Optional[str]:
        """Yürürlükteki refresh token (yalnızca 'Beni hatırla' deposuna yazmak için; gösterilmez, loglanmaz)."""
        return self._refresh_token

    def _notify_rotation(self, refresh_token: str) -> None:
        listener = self.session_listener
        if listener is None:
            return
        try:
            listener(refresh_token)
        except Exception:  # noqa: BLE001 - depo hatası oturumu bozmasın
            pass

    def restore_session(self, refresh_token: str) -> dict[str, Any]:
        """Kayıtlı refresh token ile SESSİZ giriş (parola gerekmez, saklanmaz).

        1) ``POST /auth/refresh``: yeni access + refresh (rotasyon). Yeni refresh token hemen ``session_listener``'a
           verilir (sunucu eskisini kullanılmış saydığı için depo GÜNCELLENMELİDİR).
        2) ``GET /auth/me``: rol denetimi; ``super_user``/``service_user`` değilse yeni oturum sunucuda iptal edilir ve
           ``ApiError(403, FORBIDDEN)`` yükselir (login ile aynı kural).

        Hata: refresh 400/401/403 veya /me 401/403 -> ``SessionExpiredError`` (çağıran kayıtlı tokeni SİLER); ağ/5xx
        hataları olduğu gibi yükselir (token silinmez: sonraki açılışta yeniden denenir)."""
        token = (refresh_token or "").strip()
        if not token:
            raise SessionExpiredError("Kayıtlı oturum yok. Lütfen giriş yapın.", status=401, code="INVALID_TOKEN")
        try:
            data = self._call("POST", "/auth/refresh", body={"refresh_token": token}, auth=False)
        except ApiError as exc:
            if exc.status in (400, 401, 403):
                raise SessionExpiredError(
                    "Kayıtlı oturum geçersiz veya süresi dolmuş. Lütfen yeniden giriş yapın.", status=401, code="INVALID_TOKEN"
                ) from None
            raise
        access, new_refresh = data.get("access_token"), data.get("refresh_token")
        if not isinstance(access, str) or not access or not isinstance(new_refresh, str) or not new_refresh:
            raise SessionExpiredError("Oturum yenilenemedi. Lütfen yeniden giriş yapın.", status=401, code="INVALID_TOKEN")
        self._clear_session()
        with self._lock:
            self._access_token, self._refresh_token = access, new_refresh
            self.must_change_password = bool(data.get("must_change_password"))
        self._track(access, new_refresh)
        self._notify_rotation(new_refresh)  # sunucu eski token'ı kullanılmış saydı: yenisi hemen depoya
        try:
            profile = self._call("GET", "/auth/me")
        except ApiError as exc:
            self._clear_session()
            if exc.status in (401, 403):
                raise SessionExpiredError("Kayıtlı oturum geçersiz. Lütfen yeniden giriş yapın.", status=401, code="INVALID_TOKEN") from None
            raise
        except FactoryError:
            self._clear_session()  # ağ hatası: yeni token depoda; bir sonraki denemede kullanılır
            raise
        user = profile.get("user") if isinstance(profile.get("user"), dict) else profile
        role = str(user.get("role") or "")
        if role not in TOOL_ROLES:
            self._clear_session()
            self._revoke_quietly(new_refresh)  # yetkisiz hesap: açılan oturum hemen iptal edilir, token tutulmaz
            raise ApiError(_role_rejection(role), status=403, code="FORBIDDEN")
        with self._lock:
            self._user = {"email": str(user.get("email") or ""), "role": role, "name": str(user.get("full_name") or "")}
            self.must_change_password = self.must_change_password or bool(user.get("must_change_password"))
        return dict(self._user)

    # ---- istek çekirdeği ---------------------------------------------------
    def _url(self, path: str, query: Optional[Mapping[str, Any]] = None) -> str:
        url = f"{self._base_url}{API_PREFIX}{path}"
        if query:
            clean = {k: v for k, v in query.items() if v is not None and v != ""}
            if clean:
                url += "?" + urllib.parse.urlencode(clean)
        return url

    def _auth_headers(self) -> dict[str, str]:
        if self._api_key:
            return {"x-api-key": self._api_key}
        if self._access_token:
            return {"Authorization": "Bearer " + self._access_token}
        return {}

    def _call(
        self,
        method: str,
        path: str,
        *,
        body: Optional[Mapping[str, Any]] = None,
        query: Optional[Mapping[str, Any]] = None,
        auth: bool = True,
    ) -> dict[str, Any]:
        headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
        data: Optional[bytes] = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        if auth:
            headers.update(self._auth_headers())
        send = self._transport or default_transport
        response = send(method, self._url(path, query), headers, data, self._timeout)
        payload = parse_json_object(response.body)

        if 200 <= response.status < 300:
            if response.status == 204:
                return {}
            if payload is None or payload.get("success") is False:
                raise ApiError(
                    "Sunucudan beklenmeyen bir yanıt alındı. Sunucu adresini kontrol edin.",
                    status=response.status,
                    code="BAD_RESPONSE",
                )
            inner = payload.get("data")
            return inner if isinstance(inner, dict) else ({} if inner is None else {"value": inner})

        code = payload.get("code") if payload else None
        code = code if isinstance(code, str) and _API_CODE_PATTERN.match(code) else None
        retry_after = _parse_retry_after(payload, response.headers)
        ref = response.headers.get("x-error-ref") if response.status >= 500 else None
        detail = payload.get("error") if payload else None
        path = payload.get("path") if payload else None
        raise ApiError(
            friendly_api_error(response.status, code, payload.get("message") if payload else None, retry_after, ref),
            status=response.status,
            code=code,
            retry_after=retry_after,
            detail=detail if isinstance(detail, str) and _DETAIL_CODE_PATTERN.match(detail) else None,
            path=path if isinstance(path, str) and _FIELD_PATH_PATTERN.match(path) else None,
        )

    def _refresh_session(self, stale_access: Optional[str]) -> None:
        """Tek-uçuş refresh (yalnızca 401 TOKEN_EXPIRED sonrası). Başarısızsa oturum kapanır."""
        with self._lock:
            if self._access_token != stale_access:
                return  # başka iş parçacığı zaten yeniledi
            refresh = self._refresh_token
            if not refresh:
                self._clear_session()
                raise SessionExpiredError("Oturum süresi doldu. Lütfen yeniden giriş yapın.", status=401, code="TOKEN_EXPIRED")
            try:
                data = self._call("POST", "/auth/refresh", body={"refresh_token": refresh}, auth=False)
            except ApiError as exc:
                if exc.status in (400, 401, 403):
                    self._clear_session()
                    raise SessionExpiredError(
                        "Oturum yenilenemedi. Lütfen yeniden giriş yapın.", status=401, code="INVALID_TOKEN"
                    ) from None
                raise
            access, new_refresh = data.get("access_token"), data.get("refresh_token")
            if not isinstance(access, str) or not access or not isinstance(new_refresh, str) or not new_refresh:
                self._clear_session()
                raise SessionExpiredError("Oturum yenilenemedi. Lütfen yeniden giriş yapın.", status=401, code="INVALID_TOKEN")
            if self._scrubber is not None:
                self._scrubber.discard(self._access_token, self._refresh_token)
            self._access_token, self._refresh_token = access, new_refresh
            self._track(access, new_refresh)
            self._notify_rotation(new_refresh)  # hatırlanan oturumda yeni refresh token depoya yazılır (rotasyon)

    def request(
        self,
        method: str,
        path: str,
        *,
        body: Optional[Mapping[str, Any]] = None,
        query: Optional[Mapping[str, Any]] = None,
    ) -> dict[str, Any]:
        """Kimlik doğrulamalı çağrı. 401 ``TOKEN_EXPIRED`` -> bir kez refresh + bir kez yeniden deneme.
        403 asla refresh tetiklemez; ``INVALID_TOKEN`` oturumu kapatır."""
        if not self.is_authenticated:
            raise SessionExpiredError("Sunucu oturumu yok. Lütfen giriş yapın.", status=401, code="INVALID_TOKEN")
        stale = self._access_token
        try:
            return self._call(method, path, body=body, query=query)
        except ApiError as exc:
            if exc.status != 401:
                raise
            if self._api_key:
                raise ApiError(
                    "API anahtarı sunucu tarafından kabul edilmedi (ADMIN_API_KEY yanlış veya sunucuda tanımsız).",
                    status=401,
                    code="INVALID_TOKEN",
                ) from None
            if exc.code == "TOKEN_EXPIRED":
                self._refresh_session(stale)
                try:
                    return self._call(method, path, body=body, query=query)
                except ApiError as retry_exc:
                    if retry_exc.status == 401:  # yenilenen belirteç de reddedildi: oturum kapanır
                        self._clear_session()
                        raise SessionExpiredError(retry_exc.message, status=401, code=retry_exc.code) from None
                    raise
            self._clear_session()
            raise SessionExpiredError(exc.message, status=401, code=exc.code) from None

    # ---- envanter uçları ---------------------------------------------------
    def register_device(
        self, *, uid: str, mac: str, pin: str, model: str, batch_no: str
    ) -> RegistrationResult:
        """Cihazı envantere kaydeder (süper kullanıcı JWT veya API anahtarı)."""
        data = self.request(
            "POST",
            "/admin/inventory/register",
            body={"device_uuid": uid, "mac_address": mac, "pin": pin, "model": model, "batch_no": batch_no},
        )
        device = data.get("device")
        local_key = data.get("local_key")
        if not isinstance(device, dict) or not is_valid_local_key(local_key):
            raise ApiError(
                "Sunucu yanıtı eksik: cihaz anahtarı alınamadı. Cihaz kaydedilmiş olabilir; "
                "envanter listesini kontrol edin (gerekirse kaydı silip yeniden oluşturun).",
                status=201,
                code="BAD_RESPONSE",
            )
        self._track(local_key)
        qr = data.get("qr_claim_url")
        if claim_url_matches(qr, uid, pin):
            return RegistrationResult(device, local_key, qr, True)
        return RegistrationResult(device, local_key, build_claim_url(uid, pin), False)

    def list_inventory(self, *, limit: int = 100, offset: int = 0, status: Optional[str] = None) -> dict[str, Any]:
        return self.request(
            "GET",
            "/admin/inventory",
            query={"limit": max(1, min(int(limit), 100)), "offset": max(0, int(offset)), "status": status},
        )

    def _require_jwt(self) -> None:
        if self._api_key:
            raise ApiError(
                "Bu işlem e-posta + parola ile süper kullanıcı girişi gerektirir (API anahtarı yetmez).",
                status=403,
                code="FORBIDDEN",
            )

    @staticmethod
    def _uid_segment(uid: str) -> str:
        value = (uid or "").strip().upper()
        if not UID_PATTERN.match(value):
            raise FactoryError("Geçersiz cihaz UID'si.")
        return urllib.parse.quote(value, safe="")

    def update_status(self, uid: str, status: str) -> dict[str, Any]:
        self._require_jwt()
        return self.request("PATCH", f"/admin/inventory/{self._uid_segment(uid)}/status", body={"status": status})

    def delete_device(self, uid: str) -> dict[str, Any]:
        self._require_jwt()
        return self.request("DELETE", f"/admin/inventory/{self._uid_segment(uid)}")

    # ---- rol yardımcıları (İP-3.1) -------------------------------------------
    @property
    def role_text(self) -> str:
        """Oturum çubuğunda gösterilen rol adı (süper kullanıcı / servis sorumlusu / API anahtarı)."""
        return ROLE_TEXT.get(self.user_role, self.user_role or "bilinmiyor")

    @property
    def can_manage_inventory(self) -> bool:
        """Envanter kaydı / durum / silme yalnız süper kullanıcı (ve kayıt için API anahtarı); servis sorumlusu YAPAMAZ."""
        return self.user_role in ("super_user", "api_key")

    # ---- site / daire / şablon uçları (CONTRACTS §3e; requireServiceManager) ----
    @staticmethod
    def _id_segment(value: Any, what: str = "kayıt") -> str:
        text = str(value or "").strip()
        if not _RESOURCE_ID_PATTERN.match(text):
            raise FactoryError(f"Geçersiz {what} kimliği.")
        return urllib.parse.quote(text, safe="")

    @staticmethod
    def _items(data: Mapping[str, Any], *keys: str) -> list[dict[str, Any]]:
        """Liste yanıtı: ``data`` bir dizi ise (``{"value": [...]}``) ya da ``{items|<anahtar>: [...]}``."""
        for key in ("value", "items") + keys:
            value = data.get(key) if isinstance(data, Mapping) else None
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
        return []

    def _service_jwt(self) -> None:
        if self._api_key:
            raise ApiError(
                "Site ve şablon işlemleri e-posta + parola ile giriş gerektirir (API anahtarı yetmez).",
                status=403,
                code="FORBIDDEN",
            )

    def list_sites(self) -> list[dict[str, Any]]:
        self._service_jwt()
        return self._items(self.request("GET", "/sites"), "sites")

    def create_site(self, fields: Mapping[str, Any]) -> dict[str, Any]:
        self._service_jwt()
        data = self.request("POST", "/sites", body=dict(fields))
        return data.get("site") if isinstance(data.get("site"), dict) else data

    def get_site(self, site_id: str) -> dict[str, Any]:
        self._service_jwt()
        data = self.request("GET", f"/sites/{self._id_segment(site_id, 'site')}")
        return data.get("site") if isinstance(data.get("site"), dict) else data

    def update_site(self, site_id: str, fields: Mapping[str, Any]) -> dict[str, Any]:
        self._service_jwt()
        data = self.request("PATCH", f"/sites/{self._id_segment(site_id, 'site')}", body=dict(fields))
        return data.get("site") if isinstance(data.get("site"), dict) else data

    def delete_site(self, site_id: str) -> dict[str, Any]:
        self._service_jwt()
        return self.request("DELETE", f"/sites/{self._id_segment(site_id, 'site')}")

    def list_flats(self, site_id: str) -> list[dict[str, Any]]:
        self._service_jwt()
        return self._items(self.request("GET", f"/sites/{self._id_segment(site_id, 'site')}/flats"), "flats")

    def bulk_create_flats(
        self,
        site_id: str,
        *,
        block: str,
        start: int,
        end: int,
        flat_type: Optional[str] = None,
        template_id: Optional[str] = None,
    ) -> list[dict[str, Any]]:
        """``POST /sites/:id/flats/bulk {block, from, to, flat_type?, template_id?}`` (var olan blok+no atlanır)."""
        self._service_jwt()
        body: dict[str, Any] = {"block": block, "from": int(start), "to": int(end)}
        if flat_type:
            body["flat_type"] = flat_type
        if template_id:
            body["template_id"] = template_id
        data = self.request("POST", f"/sites/{self._id_segment(site_id, 'site')}/flats/bulk", body=body)
        return self._items(data, "flats", "created")

    def update_flat(self, site_id: str, flat_id: str, fields: Mapping[str, Any]) -> dict[str, Any]:
        self._service_jwt()
        path = f"/sites/{self._id_segment(site_id, 'site')}/flats/{self._id_segment(flat_id, 'daire')}"
        data = self.request("PATCH", path, body=dict(fields))
        return data.get("flat") if isinstance(data.get("flat"), dict) else data

    def delete_flat(self, site_id: str, flat_id: str) -> dict[str, Any]:
        self._service_jwt()
        return self.request("DELETE", f"/sites/{self._id_segment(site_id, 'site')}/flats/{self._id_segment(flat_id, 'daire')}")

    def link_flat_device(self, site_id: str, flat_id: str, device_uuid: Optional[str]) -> dict[str, Any]:
        """``PUT /sites/:id/flats/:flatId/device {device_uuid}``; ``None`` bağlantıyı kaldırır."""
        self._service_jwt()
        uid = None
        if device_uuid:
            uid = device_uuid.strip().upper()
            if not UID_PATTERN.match(uid):
                raise FactoryError("Geçersiz cihaz UID'si (AHBU-S3-XXXXXX biçiminde olmalı).")
        path = f"/sites/{self._id_segment(site_id, 'site')}/flats/{self._id_segment(flat_id, 'daire')}/device"
        return self.request("PUT", path, body={"device_uuid": uid})

    def list_templates(self, site_id: Optional[str] = None, *, include_global: bool = True) -> list[dict[str, Any]]:
        """``GET /templates?site_id=&include_global=1``; ``site_id`` yoksa yalnız genel (standart) şablonlar."""
        self._service_jwt()
        query: dict[str, Any] = {"include_global": 1 if include_global else 0}
        if site_id:
            query["site_id"] = self._id_segment(site_id, "site")
        return self._items(self.request("GET", "/templates", query=query), "templates")

    def create_template(self, site_id: Optional[str], body: Mapping[str, Any]) -> dict[str, Any]:
        self._service_jwt()
        data = self.request("POST", "/templates", body={"site_id": site_id or None, "body": dict(body)})
        return data.get("template") if isinstance(data.get("template"), dict) else data

    def get_template(self, template_id: str) -> dict[str, Any]:
        self._service_jwt()
        data = self.request("GET", f"/templates/{self._id_segment(template_id, 'şablon')}")
        return data.get("template") if isinstance(data.get("template"), dict) else data

    def update_template(self, template_id: str, body: Mapping[str, Any]) -> dict[str, Any]:
        """Kaydet = yeni sürüm (gövde aynıysa sunucu sürümü artırmaz)."""
        self._service_jwt()
        data = self.request("PUT", f"/templates/{self._id_segment(template_id, 'şablon')}", body={"body": dict(body)})
        return data.get("template") if isinstance(data.get("template"), dict) else data

    def delete_template(self, template_id: str) -> dict[str, Any]:
        self._service_jwt()
        return self.request("DELETE", f"/templates/{self._id_segment(template_id, 'şablon')}")

    def list_template_versions(self, template_id: str) -> list[dict[str, Any]]:
        self._service_jwt()
        return self._items(self.request("GET", f"/templates/{self._id_segment(template_id, 'şablon')}/versions"), "versions")

    def get_template_version(self, template_id: str, version: int) -> dict[str, Any]:
        self._service_jwt()
        path = f"/templates/{self._id_segment(template_id, 'şablon')}/versions/{int(version)}"
        data = self.request("GET", path)
        return data.get("version") if isinstance(data.get("version"), dict) else data

    def validate_template_remote(self, body: Mapping[str, Any]) -> None:
        """``POST /templates/validate``: geçerliyse döner; 422 ``TEMPLATE_INVALID`` -> ``ApiError`` (``detail`` = şablon kodu,
        ``path`` = alan yolu)."""
        self._service_jwt()
        self.request("POST", "/templates/validate", body={"body": dict(body)})

    def record_template_write(
        self,
        *,
        device_uuid: str,
        template_id: str,
        version: int,
        via: str,
        result: str,
        flat_id: Optional[str] = None,
        error_code: Optional[str] = None,
    ) -> dict[str, Any]:
        """``POST /template-writes`` (K-Ş6): ``via`` usb|eth, ``result`` ok|error. ``ok`` ise daire ``written`` olur."""
        self._service_jwt()
        if via not in ("usb", "eth", "lan") or result not in ("ok", "error"):
            raise FactoryError("Yazım kaydı geçersiz.")
        uid = (device_uuid or "").strip().upper()
        if not UID_PATTERN.match(uid):
            raise FactoryError("Geçersiz cihaz UID'si.")
        body: dict[str, Any] = {"device_uuid": uid, "template_id": template_id, "version": int(version), "via": via, "result": result}
        if flat_id:
            body["flat_id"] = flat_id
        if error_code:
            body["error_code"] = error_code if _DETAIL_CODE_PATTERN.match(error_code) else "unknown"
        return self.request("POST", "/template-writes", body=body)

    def fetch_local_key(self, uid: str) -> str:
        """Ethernet yazımı için kartın yerel anahtarı (``GET /admin/inventory/:uuid/local-key``; denetim kaydı + oran sınırı).
        Değer maskelenmek üzere ``SecretScrubber``'a eklenir; ekranda/günlükte GÖSTERİLMEZ."""
        self._service_jwt()
        data = self.request("GET", f"/admin/inventory/{self._uid_segment(uid)}/local-key")
        key = data.get("local_key")
        if not is_valid_local_key(key):
            raise ApiError("Sunucu kartın yerel anahtarını vermedi.", status=200, code="BAD_RESPONSE")
        self._track(key)
        return key


# ---------------------------------------------------------------------------
# Cihaz kaydı (bellekte tutulan tek-seferlik değerler)
# ---------------------------------------------------------------------------
@dataclass(repr=False)
class DeviceRecord:
    """Kayıt yanıtından ve araçtan gelen cihaz bilgileri. Gizli alanlar yalnızca BELLEKTE tutulur;
    diske yalnızca kullanıcı "etiketi kaydet" derse etiket görseli olarak yazılır."""

    uid: str
    mac: str
    pin: str
    local_key: str
    ap_pass: str
    qr_claim_url: str
    serial_no: Any = None
    model: str = ""
    batch_no: str = ""
    created_at: Optional[str] = None
    state: str = "registered"  # registered | init_sent | verified | wiped
    path: str = ""             # provizyon yolu: "serial" (USB) | "wifi" (güvensiz yedek) | "" (henüz yok)
    flat_info: str = ""        # İP-3.5: karta daire şablonu yazılınca etiket satırı ("A Blok / Daire 12 · 3+1 · Şablon v4")

    @property
    def ap_ssid(self) -> Optional[str]:
        return ap_ssid_from_mac(self.mac)

    @property
    def provisioned(self) -> bool:
        return self.state == "verified"

    def secret_values(self) -> tuple[str, ...]:
        """Maskelenecek gizli metinler: PIN, yerel anahtar, AP parolası, PIN'li karekod adresi ve (AP parolasını
        taşıyan) etiketin 2. karekod metni ile parolanın kaçışlı biçimi."""
        values = [self.pin, self.local_key, self.ap_pass, self.qr_claim_url]
        if self.ap_pass:
            escaped = escape_wifi_qr_value(self.ap_pass)
            if escaped != self.ap_pass:
                values.append(escaped)
            try:
                values.append(device_wifi_qr_payload(self.mac, self.ap_pass))
            except ValueError:
                pass
        return tuple(values)

    def wipe(self) -> None:
        self.pin = self.local_key = self.ap_pass = self.qr_claim_url = ""
        self.state = "wiped"

    def __repr__(self) -> str:
        return f"DeviceRecord(uid={self.uid!r}, mac={self.mac!r}, state={self.state!r}, <gizli alanlar gizlendi>)"


# ---------------------------------------------------------------------------
# Cihaz provizyonu (flash sonrası) - docs/CONTRACTS.md §3 ve §3b
# ---------------------------------------------------------------------------
@dataclass
class ProvisionOutcome:
    initialized: bool = False        # POST /api/factory/init 200 döndü (veya cihaz zaten bu anahtarla kurulu)
    verified: bool = False           # GET /api/auth/check X-Device-Key ile 200 döndü
    needs_reconnect: bool = False    # init tamam; AP WPA2'ye geçti -> bilgisayar yeniden bağlanmalı
    device_uid: Optional[str] = None
    firmware: Optional[str] = None
    via: str = "wifi"                # "serial" (USB, önerilen) | "wifi" (açık AP + düz HTTP, güvensiz yedek)
    mac: Optional[str] = None        # seri yolda STATUS'tan okunan kart MAC'i
    ap_ssid: Optional[str] = None    # seri yolda STATUS'tan okunan kurulum ağı adı


def provision_urgency_notice(ssid: Optional[str] = None) -> str:
    """Açık kurulum ağı riski (CONTRACTS §3b): provizyon flash'tan HEMEN sonra yapılmalıdır."""
    net = ssid or "AHBU-XXXXXX"
    return (
        f"Bilgi: Provizyon bitene kadar kart '{net}' kurulum ağını PAROLASIZ yayınlar. "
        "Provizyonu flash'tan HEMEN sonra yapmanız yeterli; araç bunu USB üzerinden otomatik yapar."
    )


def manual_provision_instructions(ssid: Optional[str] = None) -> str:
    """Otomatik provizyon çalışmazsa elle yöntemler (gizli değer içermez)."""
    net = ssid or "AHBU-XXXXXX"
    return (
        "ELLE PROVİZYON (otomatik yöntem çalışmazsa)\n"
        "\n"
        "A) ÖNERİLEN - USB (seri) ile elle (anahtar kablosuz ağdan geçmez):\n"
        "1) Kartı USB ile bağlayın. Bu aracın seri bağlantısı kapalı olsun (port tek programa açıktır). Bir seri terminal "
        "programı (PuTTY, Arduino/PlatformIO seri monitör vb.) açın: 115200 baud, satır sonu CR+LF.\n"
        "2) STATUS yazıp Enter'a basın. 'Yerel anahtar (local_key): YOK (provizyonsuz cihaz)' görmelisiniz. 'tanimli' "
        "görüyorsanız önce RESETKEY yazın (eski anahtar kullanılamaz hale gelir).\n"
        "3) FACTORYINIT <yerel anahtar> <AP parolası> yazıp Enter'a basın (değerleri bu araçtaki 'Anahtarı kopyala' / "
        "'AP parolasını kopyala' düğmeleriyle alın; araya TEK boşluk). Kart bu satırı geri YAZMAZ. Yanıt 'OK factory_init' "
        "olmalı. Hata yanıtları: ERR already_provisioned (önce RESETKEY), ERR invalid_local_key / ERR invalid_ap_pass "
        "(8-32 karakter olmalı), ERR persist_failed (yeniden deneyin; sürerse Erase Flash + firmware).\n"
        "4) STATUS ile 'tanimli' olduğunu doğrulayıp terminali kapatın.\n"
        "\n"
        "B) YEDEK (GÜVENSİZ) - Wi-Fi ile: anahtar açık ağdan düz HTTP ile gider.\n"
        f"{provision_urgency_notice(ssid)}\n"
        f"1) Bilgisayarı veya telefonu '{net}' Wi-Fi ağına bağlayın. Provizyonsuz kartta bu ağ PAROLASIZDIR. "
        "Ağ görünmüyorsa: USB ile bağlanıp seri terminalde (115200 baud) AP ON yazın (ağ 10 dk açılır) "
        "veya USB'yi çekip takarak kartı yeniden başlatın.\n"
        "2) Tarayıcıda http://192.168.4.1 adresini açın; 'Cihaz Kurulumu (Provizyon)' formu görünür.\n"
        "3) 'Yerel anahtar' ve 'AP parolası' alanlarına bu araçtaki değerleri girin "
        "('Anahtarı kopyala' / 'AP parolasını kopyala' düğmelerini kullanın) ve kaydedin.\n"
        f"4) Kart ağı parolalı (WPA2) olarak yeniden başlatır: '{net}' ağına etiketteki AP PAROLASI ile "
        "yeniden bağlanın ve bu araçta 'Wi-Fi ile Doğrula'ya basın.\n"
        "Kart 'zaten provizyonlu' diyorsa: seri terminalden RESETKEY yazın (kurulum ağı açılmazsa ardından AP ON), "
        "sonra yukarıdaki adımları yineleyin.\n"
        "Kart daha önce başka bir Wi-Fi ağına kaydedildiyse kurulum ağı hemen açılmaz (bağlantı 3 dk kesilince açılır): "
        "fabrika akışında önce 'Hafızayı Sil (Erase Flash)', sonra firmware yükleyin."
    )


def provision_error_text(err: ProvisionError, ssid: Optional[str] = None) -> str:
    """Hata + 'ne yapmalıyım' metni (gizli değer içermez)."""
    net = ssid or "kartın kurulum ağı"
    hint = err.hint.replace("{ssid}", net)
    return err.message if not hint else f"{err.message}\n{hint}"


_DEVICE_ERROR_ID = re.compile(r"[a-z0-9_]{1,40}")


class DeviceClient:
    """Cihazın yerel HTTP API'si (kurulum AP'si). Yalnızca yerel ağ adreslerine bağlanır."""

    def __init__(
        self,
        host: Optional[str] = None,
        *,
        transport: Optional[Transport] = None,
        env: Optional[Mapping[str, str]] = None,
        timeout: float = DEVICE_TIMEOUT_S,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        env_map: Mapping[str, str] = os.environ if env is None else env
        self.host = normalize_device_host(host if host else env_map.get(ENV_DEVICE_HOST, ""))
        self._transport = transport
        self._timeout = timeout
        self._sleep = sleep

    @property
    def base_url(self) -> str:
        return f"http://{self.host}"

    def _request(
        self,
        method: str,
        path: str,
        *,
        key: Optional[str] = None,
        json_body: Optional[Mapping[str, Any]] = None,
        raw_json: Optional[bytes] = None,
    ) -> tuple[int, Optional[dict[str, Any]], Mapping[str, str]]:
        headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
        data: Optional[bytes] = None
        if json_body is not None:
            data = json.dumps(json_body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif raw_json is not None:  # hazır UTF-8 JSON (şablon zarfı: Türkçe karakterler kaçışsız, 24 KB sınırı korunur)
            data = bytes(raw_json)
            headers["Content-Type"] = "application/json; charset=utf-8"
        if key:
            headers["X-Device-Key"] = key
        send = self._transport or default_transport
        try:
            response = send(method, self.base_url + path, headers, data, self._timeout)
        except NetworkError:
            raise ProvisionError(
                "unreachable",
                "Cihaza ulaşılamadı.",
                hint=(
                    "Bilgisayarın Wi-Fi bağlantısını kartın kurulum ağına ({ssid}) alın. Kartı yeni yüklediyseniz "
                    "30-60 saniye bekleyin. Ağ görünmüyorsa (10 dakikalık pencere kapanmış olabilir): karta USB ile "
                    "bağlanıp seri terminalde (115200 baud) AP ON yazın veya USB'yi çekip takarak kartı yeniden "
                    "başlatın. Ethernet kablosu veya VPN, cihaz adresine giden yolu bozuyorsa onları kapatıp "
                    "tekrar deneyin."
                ),
            ) from None
        return response.status, parse_json_object(response.body), response.headers

    @staticmethod
    def _error_id(payload: Optional[dict[str, Any]]) -> str:
        value = payload.get("error") if payload else None
        return value if isinstance(value, str) and _DEVICE_ERROR_ID.fullmatch(value) else ""

    @staticmethod
    def _wait_hint(payload: Optional[dict[str, Any]], headers: Mapping[str, str]) -> tuple[Optional[int], str]:
        after = _parse_retry_after(payload, headers)
        return after, f"{_format_wait(after)} sonra tekrar deneyin."

    def status(self) -> dict[str, Any]:
        """Anahtarsız KISITLI durum: ``{device, name, fw, provisioned, wifi_connected}`` (§3b: UID ``device`` alanında)."""
        status, payload, _headers = self._request("GET", "/api/status")
        if (
            status != 200
            or payload is None
            or not isinstance(payload.get("provisioned"), bool)
            or not isinstance(payload.get("device"), str)
        ):
            raise ProvisionError(
                "unexpected",
                f"Bu adres bir AHBU cihazı gibi yanıt vermedi (HTTP {status}).",
                hint="Bilgisayarın kartın kurulum ağına ({ssid}) bağlı olduğundan ve başka bir ağ cihazına gitmediğinden emin olun.",
            )
        return payload

    def _status_with_retry(
        self,
        attempts: int,
        delay: float,
        progress: Optional[ProgressCallback],
        cancel: Optional[threading.Event] = None,
        lenient: bool = False,
    ) -> dict[str, Any]:
        last: Optional[ProvisionError] = None
        retryable = ("unreachable", "unexpected") if lenient else ("unreachable",)
        for attempt in range(max(1, attempts)):
            if cancel is not None and cancel.is_set():
                raise ProvisionError("cancelled", "İşlem iptal edildi.")
            try:
                return self.status()
            except ProvisionError as exc:
                if exc.code not in retryable:
                    raise
                last = exc
            if attempt < attempts - 1:
                if progress and (attempt % 5 == 0):
                    progress(f"Cihaz bekleniyor ({attempt + 1}/{attempts})... Bilgisayar kurulum ağına bağlanınca devam edilir.")
                self._sleep(delay)
        assert last is not None
        raise last

    def factory_init(self, local_key: str, ap_pass: str) -> None:
        """``POST /api/factory/init {local_key, ap_pass}`` - yalnızca provizyonsuz cihazda çalışır."""
        status, payload, headers = self._request(
            "POST", "/api/factory/init", json_body={"local_key": local_key, "ap_pass": ap_pass}
        )
        if status == 200:
            return
        err = self._error_id(payload)
        if status == 403 and err == "factory_ap_only":
            raise ProvisionError(
                "factory_ap_only",
                "Kart provizyonu bu ağ arayüzünden kabul etmiyor (factory_ap_only): yalnız kurulum Wi-Fi'si ya da USB.",
                hint=(
                    "Atölye sırası: USB ile firmware yükleyin -> USB (seri) FACTORYINIT (araç otomatik yapar) -> şablonu USB ya da "
                    "Ethernet ile yazın. 'Seri (USB) ile Provizyonla'yı kullanın."
                ),
            )
        if status == 403 and err == "already_provisioned":
            raise ProvisionError(
                "already_provisioned",
                "Cihaz zaten provizyonlu (başka bir anahtarla kurulmuş).",
                hint=(
                    "Yeniden kurmak için karta USB ile bağlanıp seri terminalden (115200 baud) RESETKEY komutunu "
                    "gönderin (kurulum ağı açılmazsa ardından AP ON) ve tekrar deneyin."
                ),
            )
        if status == 503 and err == "storage":
            raise ProvisionError(
                "storage",
                "Cihaz anahtarı kalıcı belleğe yazamadı (storage).",
                hint="Kartı yeniden başlatıp tekrar deneyin; sürerse 'Hafızayı Sil (Erase Flash)' ile firmware'i yeniden yükleyin.",
            )
        if status in (409, 503) or err in ("busy", "queue_full"):
            raise ProvisionError("busy", "Cihaz meşgul.", hint="Birkaç saniye bekleyip tekrar deneyin.")
        if status == 423:
            after, hint = self._wait_hint(payload, headers)
            raise ProvisionError("locked", "Cihaz geçici olarak kilitli.", hint=hint, retry_after=after)
        if status in (400, 401, 403, 413, 415):
            raise ProvisionError(
                "rejected",
                f"Cihaz gönderilen bilgiyi reddetti ({err or 'HTTP ' + str(status)}).",
                hint="Araç ile firmware sürümlerinin uyumlu olduğundan emin olun (yerel anahtar ve AP parolası 8-32 karakter).",
            )
        raise ProvisionError(
            "unexpected",
            f"Cihazdan beklenmeyen yanıt alındı (HTTP {status}).",
            hint="Firmware sürümünü kontrol edip tekrar deneyin.",
        )

    def verify(
        self,
        local_key: str,
        *,
        attempts: int = 5,
        delay: float = 2.0,
        progress: Optional[ProgressCallback] = None,
        cancel: Optional[threading.Event] = None,
    ) -> bool:
        """``GET /api/auth/check`` (``X-Device-Key``) 200 ise True. Ağ yoksa yeniden dener."""
        last: Optional[ProvisionError] = None
        for attempt in range(max(1, attempts)):
            if cancel is not None and cancel.is_set():
                raise ProvisionError("cancelled", "İşlem iptal edildi.")
            try:
                status, payload, headers = self._request("GET", "/api/auth/check", key=local_key)
            except ProvisionError as exc:
                last = exc
            else:
                err = self._error_id(payload)
                if status == 200:
                    return True
                if status == 401:
                    raise ProvisionError(
                        "key_mismatch",
                        "Cihaz anahtarı doğrulanamadı (401): cihazdaki anahtar bu kayıttakiyle aynı değil.",
                        hint="Kart başka bir anahtarla provizyonlanmış olabilir: RESETKEY ile sıfırlayıp provizyonu yeniden yapın.",
                    )
                if status == 423:
                    after, hint = self._wait_hint(payload, headers)
                    raise ProvisionError(
                        "locked",
                        "Cihaz çok sayıda hatalı denemeden dolayı geçici olarak kilitlendi.",
                        hint=hint,
                        retry_after=after,
                    )
                if status == 403 and err == "unprovisioned":
                    raise ProvisionError(
                        "not_provisioned",
                        "Cihaz hâlâ provizyonsuz görünüyor (anahtar yazılmamış).",
                        hint="'Provizyonu Başlat'a basarak yeniden deneyin.",
                    )
                raise ProvisionError(
                    "unexpected",
                    f"Cihazdan beklenmeyen yanıt alındı (HTTP {status}).",
                    hint="Firmware sürümünü kontrol edip tekrar deneyin.",
                )
            if attempt < attempts - 1:
                if progress:
                    progress(f"Doğrulama için cihaza ulaşılamadı; yeniden deneniyor ({attempt + 2}/{attempts})...")
                self._sleep(delay)
        assert last is not None
        raise last

    def provision(
        self,
        local_key: str,
        ap_pass: str,
        *,
        expected_uid: Optional[str] = None,
        progress: Optional[ProgressCallback] = None,
        status_attempts: int = 3,
        retry_delay: float = 2.0,
        wait_seconds: float = 0.0,
        cancel: Optional[threading.Event] = None,
    ) -> ProvisionOutcome:
        """Provizyonsuz cihaza yerel anahtar + AP parolasını yazar ve doğrular (en iyi çaba).

        Adımlar: (1) anahtarsız durum -> provizyonsuz mu / doğru cihaz mı, (2) ``POST /api/factory/init``,
        (3) hızlı doğrulama. Init sonrası kart AP'yi WPA2'ye geçirdiği için bilgisayarın bağlantısı düşer;
        doğrulama ulaşılamazsa ``needs_reconnect=True`` döner (kullanıcı yeniden bağlanıp ``verify`` çağırır).

        ``wait_seconds > 0`` iken (flash sonrası) cihaz ulaşılabilir olana kadar bu süre boyunca beklenir
        (kullanıcı bilgisayarı kurulum ağına bağlarken); ``cancel`` olayı beklemeyi keser.
        """
        if not is_valid_local_key(local_key) or not is_valid_ap_pass(ap_pass):
            raise ProvisionError(
                "rejected",
                "Yerel anahtar veya AP parolası geçersiz (8-32 karakter olmalı).",
                hint="Cihazı yeniden kaydedin.",
            )

        def say(message: str) -> None:
            if progress:
                progress(message)

        attempts, lenient = status_attempts, False
        if wait_seconds and wait_seconds > 0:
            attempts, lenient = int(wait_seconds / max(retry_delay, 0.1)) + 1, True
            say(f"Cihaz kurulum ağında aranıyor (en çok {int(wait_seconds)} sn)...")
        say(f"Cihaz durumu okunuyor ({self.base_url}/api/status)...")
        state = self._status_with_retry(attempts, retry_delay, progress, cancel, lenient)
        outcome = ProvisionOutcome(
            device_uid=state.get("device") if isinstance(state.get("device"), str) else None,
            firmware=state.get("fw") if isinstance(state.get("fw"), str) else None,
        )
        if expected_uid and outcome.device_uid and outcome.device_uid.upper() != expected_uid.strip().upper():
            raise ProvisionError(
                "uid_mismatch",
                f"Bağlanılan cihaz bu kayıtla eşleşmiyor (cihaz UID'si: {outcome.device_uid}).",
                hint="Doğru kartın kurulum ağına ({ssid}) bağlı olduğunuzdan emin olun.",
            )

        if state.get("provisioned") is True:
            say("Cihaz zaten provizyonlu görünüyor; bu kayıttaki anahtarla doğrulanıyor...")
            try:
                self.verify(local_key, attempts=1)
            except ProvisionError as exc:
                if exc.code == "key_mismatch":
                    raise ProvisionError(
                        "already_provisioned",
                        "Cihaz zaten provizyonlu (başka bir anahtarla kurulmuş).",
                        hint=(
                            "Yeniden kurmak için karta USB ile bağlanıp seri terminalden (115200 baud) RESETKEY "
                            "komutunu gönderin (kurulum ağı açılmazsa ardından AP ON) ve tekrar deneyin."
                        ),
                    ) from None
                raise
            outcome.initialized = outcome.verified = True
            return outcome

        say("Yerel anahtar ve AP parolası cihaza yazılıyor (POST /api/factory/init)...")
        self.factory_init(local_key, ap_pass)
        outcome.initialized = True
        say("Cihaz anahtarı kabul etti. Kart kurulum ağını parolalı (WPA2) olarak yeniden başlatıyor...")
        try:
            self.verify(local_key, attempts=2, delay=0.5)  # AP ~1.5 sn sonra WPA2'ye döner: hızlı doğrulama bir fırsattır
            outcome.verified = True
        except ProvisionError as exc:
            if exc.code != "unreachable":
                raise
            outcome.needs_reconnect = True
        return outcome


# ---------------------------------------------------------------------------
# Seri (USB) provizyon - TERCİH EDİLEN YOL (docs/CONTRACTS.md §3c: FACTORYINIT)
#
# Anahtar kablosuz ağdan ve düz HTTP'den GEÇMEZ: flash için zaten bağlı olan USB/COM portundan
# `FACTORYINIT <local_key> <ap_pass>` satırı gönderilir. Firmware satırı/parametreleri asla yankılamaz;
# yalnızca `OK factory_init` veya `ERR <neden>` yazar.
#
# Gizlilik kuralları: parametreler hiçbir zaman loglanmaz/ilerleme metnine yazılmaz; cihazdan gelen ham
# satırlar kullanıcıya gösterilmez (yalnızca ayrıştırılmış, sınırlı kodlar); gönderim tamponu iş bitince
# sıfırlanır (Python `str` nesneleri sıfırlanamaz: en iyi çaba).
# ---------------------------------------------------------------------------
SERIAL_BAUD = 115200
SERIAL_MAX_LINE = 159            # firmware satır tamponu 160 bayt (NUL dahil)
SERIAL_PORT_WAIT_S = 40.0        # flash sonrası USB'nin yeniden görünmesi için azami bekleme
SERIAL_BOOT_WAIT_S = 30.0        # açılış: STATUS'a yanıt gelene kadar azami bekleme
SERIAL_STATUS_TIMEOUT_S = 4.0
SERIAL_INIT_TIMEOUT_S = 8.0
SERIAL_RESET_TIMEOUT_S = 6.0
SERIAL_PERSIST_RETRIES = 3
SERIAL_PROBE_TIMEOUT_S = 25.0    # başka yorumlayıcıda "import serial" denemesi

_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0

_STATUS_MAC = re.compile(r"\(MAC:\s*((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})\)")
_STATUS_KEY = re.compile(r"Yerel anahtar \(local_key\):\s*(tanimli|YOK)")
_STATUS_SSID = re.compile(r"\(SSID:\s*(AHBU-[0-9A-Fa-f]{6})")
_FACTORY_RESULT = re.compile(r"(?:^|\s)(OK factory_init|ERR [a-z_]{1,40})\s*$")
_RESETKEY_RESULT = re.compile(r"Yerel anahtar (SILINDI|SILINEMEDI)")


class SerialError(FactoryError):
    """Seri port açma/okuma/yazma sorunu. ``kind``: not_found | busy | io | other."""

    def __init__(self, message: str, *, kind: str = "other") -> None:
        super().__init__(message, code=kind)
        self.kind = kind


class SerialUnavailableError(FactoryError):
    """pyserial hiçbir yorumlayıcıda bulunamadı (araç yeni paket KURMAZ)."""


def classify_serial_error(exc: BaseException, phase: str = "open") -> SerialError:
    """pyserial istisnasını (ham metni göstermeden) Türkçe ``SerialError``'a çevirir."""
    if phase == "io":
        return SerialError(
            "Seri bağlantı koptu (USB kablo çıkmış veya kart yeniden başlamış olabilir).", kind="io"
        )
    text = f"{type(exc).__name__} {exc!r}".lower()
    if "permissionerror" in text or "(13," in text or "access is denied" in text:
        return SerialError("Seri port başka bir programda açık görünüyor (erişim reddedildi).", kind="busy")
    if "filenotfounderror" in text or "(2," in text or "cannot find" in text:
        return SerialError("Seri port bulunamadı.", kind="not_found")
    return SerialError("Seri port açılamadı.", kind="other")


# ---- satır kurma / ayrıştırma ----------------------------------------------------------------------------
def validate_factory_init_values(local_key: str, ap_pass: str) -> None:
    """Firmware'in (CliParse.h) kabul ettiği biçim; aksi halde gönderilmeden ProvisionError."""
    if not is_valid_local_key(local_key):
        raise ProvisionError(
            "rejected",
            "Yerel anahtar geçersiz (8-32 karakter, boşluksuz yazdırılabilir ASCII olmalı).",
            hint="Cihazı yeniden kaydedin.",
        )
    if not is_valid_ap_pass(ap_pass) or ap_pass != ap_pass.strip():
        raise ProvisionError(
            "rejected",
            "AP parolası geçersiz (8-32 karakter; başında/sonunda boşluk olamaz).",
            hint="Cihazı yeniden kaydedin.",
        )
    if len("FACTORYINIT ") + len(local_key) + 1 + len(ap_pass) > SERIAL_MAX_LINE:
        raise ProvisionError("rejected", "Seri komut satırı çok uzun.", hint="Cihazı yeniden kaydedin.")


def build_factory_init_line(local_key: str, ap_pass: str) -> bytearray:
    """``FACTORYINIT <local_key> <ap_pass>\\r\\n`` (ASCII). Kullanıldıktan sonra ``wipe_bytes`` ile sıfırlanmalıdır."""
    validate_factory_init_values(local_key, ap_pass)
    return bytearray(f"FACTORYINIT {local_key} {ap_pass}\r\n".encode("ascii"))


def wipe_bytes(buffer: bytearray) -> None:
    """Gizli içerikli tamponu sıfırlar (en iyi çaba)."""
    for index in range(len(buffer)):
        buffer[index] = 0


@dataclass
class SerialStatus:
    """``STATUS`` çıktısından ayrıştırılan, kullanıcıya gösterilebilir alanlar."""

    mac: Optional[str] = None
    provisioned: Optional[bool] = None
    ap_ssid: Optional[str] = None

    def absorb(self, line: str) -> None:
        match = _STATUS_MAC.search(line)
        if match and self.mac is None:
            self.mac = normalize_mac(match.group(1))
        match = _STATUS_SSID.search(line)
        if match and self.ap_ssid is None:
            self.ap_ssid = match.group(1).upper()
        match = _STATUS_KEY.search(line)
        if match:
            self.provisioned = match.group(1) == "tanimli"


def parse_factory_init_result(line: str) -> Optional[tuple[bool, str]]:
    """``OK factory_init`` -> (True, ""); ``ERR <kod>`` -> (False, kod); ilgisiz satır -> None."""
    match = _FACTORY_RESULT.search(line)
    if not match:
        return None
    token = match.group(1)
    return (True, "") if token == "OK factory_init" else (False, token[4:])


class _LineBuffer:
    """Bayt akışını satırlara böler (CR ve LF ayraç; boş satırlar atılır)."""

    MAX_PENDING = 4096

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes) -> list[str]:
        self._buf.extend(data)
        lines: list[str] = []
        while True:
            positions = [p for p in (self._buf.find(b"\n"), self._buf.find(b"\r")) if p >= 0]
            if not positions:
                break
            cut = min(positions)
            raw = bytes(self._buf[:cut])
            del self._buf[: cut + 1]
            text = raw.decode("utf-8", errors="replace").strip()
            if text:
                lines.append(text)
        if len(self._buf) > self.MAX_PENDING:
            del self._buf[: -self.MAX_PENDING // 4]
        return lines

    def clear(self) -> None:
        self._buf.clear()


# ---- seri bağlantı arka uçları -----------------------------------------------------------------------------
class _PySerialConnection:
    def __init__(self, ser: Any) -> None:
        self._ser = ser

    def write(self, data: Any) -> None:
        try:
            self._ser.write(data)
            self._ser.flush()
        except Exception as exc:  # noqa: BLE001 - pyserial istisnaları sürüme göre değişir
            raise classify_serial_error(exc, "io") from None

    def read(self, size: int = 4096, timeout: float = 0.2) -> bytes:
        try:
            self._ser.timeout = timeout
            first = self._ser.read(1)
            if not first:
                return b""
            waiting = self._ser.in_waiting
            return first + (self._ser.read(min(waiting, size - 1)) if waiting else b"")
        except Exception as exc:  # noqa: BLE001
            raise classify_serial_error(exc, "io") from None

    def close(self) -> None:
        try:
            self._ser.close()
        except Exception:  # noqa: BLE001
            pass


class PySerialBackend:
    """Aracın KENDİ Python ortamındaki pyserial (tercih edilen)."""

    kind = "in-process"
    description = "pyserial (aracın kendi Python ortamı)"

    def __init__(self, serial_module: Any = None, list_ports_module: Any = None) -> None:
        self._serial = serial_module
        self._list_ports = list_ports_module

    def _modules(self) -> tuple[Any, Any]:
        if self._serial is None or self._list_ports is None:
            import serial as serial_module  # noqa: PLC0415 - yalnızca gerektiğinde
            import serial.tools.list_ports as list_ports_module  # noqa: PLC0415

            self._serial, self._list_ports = serial_module, list_ports_module
        return self._serial, self._list_ports

    def list_ports(self) -> list[tuple[str, str]]:
        _, list_ports = self._modules()
        return [(p.device, p.description or "") for p in list_ports.comports()]

    def open(self, port: str, baud: int = SERIAL_BAUD) -> _PySerialConnection:
        module, _ = self._modules()
        ser = module.Serial()
        ser.port, ser.baudrate = port, baud
        ser.timeout, ser.write_timeout = 0.2, 3
        ser.dtr = False  # açarken kartı sıfırlama/bootloader'a sokma tetiklenmesin
        ser.rts = False
        try:
            ser.open()
        except Exception as exc:  # noqa: BLE001
            raise classify_serial_error(exc, "open") from None
        return _PySerialConnection(ser)


# Başka bir yorumlayıcıdaki (ör. PlatformIO penv) pyserial'ı kullanmak için küçük, "aptal" röle betiği.
# Protokol (satır tabanlı, yalnızca ASCII): ebeveyn -> `OPEN <port> <baud>`, `W <hex>`, `Q`;
# betik -> `OPEN_OK`, `D <hex>` (porttan okunan baytlar), `E <kısa neden>`. Gizli değerler argv'ye DEĞİL
# boruya (stdin) gider; betik stderr'e hiçbir şey yazmaz.
_RELAY_SCRIPT = r"""
import binascii, sys, threading

def emit(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()

try:
    import serial
except Exception:
    emit("E import")
    sys.exit(3)

head = sys.stdin.readline().split()
if len(head) != 3 or head[0] != "OPEN":
    emit("E protocol")
    sys.exit(2)
ser = serial.Serial()
ser.port = head[1]
ser.baudrate = int(head[2])
ser.timeout = 0.05
ser.write_timeout = 3
ser.dtr = False
ser.rts = False
try:
    ser.open()
except Exception as exc:
    emit("E open " + type(exc).__name__ + " " + repr(exc).replace("\n", " ")[:160])
    sys.exit(4)
emit("OPEN_OK")
stop = threading.Event()

def pump():
    while not stop.is_set():
        try:
            data = ser.read(max(1, ser.in_waiting))
        except Exception:
            emit("E io")
            stop.set()
            return
        if data:
            emit("D " + binascii.hexlify(data).decode("ascii"))

threading.Thread(target=pump, daemon=True).start()
for raw in sys.stdin:
    parts = raw.split()
    if not parts:
        continue
    if parts[0] == "W" and len(parts) == 2:
        try:
            ser.write(binascii.unhexlify(parts[1]))
            ser.flush()
        except Exception:
            emit("E io")
            break
    elif parts[0] == "Q":
        break
stop.set()
try:
    ser.close()
except Exception:
    pass
"""

_LIST_SCRIPT = r"""
import json, serial.tools.list_ports as lp
print(json.dumps([[p.device, p.description or ""] for p in lp.comports()]))
"""

_PROBE_SCRIPT = "import serial, serial.tools.list_ports; print('PYSERIAL_OK', serial.__version__)"


class _RelayConnection:
    """Röle betiğiyle (alt süreç) konuşan bağlantı: `write`/`read` yerel pyserial gibi davranır."""

    def __init__(self, process: "subprocess.Popen[str]") -> None:
        self._proc = process
        self._queue: "queue.Queue[Any]" = queue.Queue()
        self._opened = threading.Event()
        self._open_error: Optional[str] = None
        self._reader = threading.Thread(target=self._pump, name="serial-relay-reader", daemon=True)
        self._reader.start()

    def _pump(self) -> None:
        try:
            for raw in self._proc.stdout:  # type: ignore[union-attr]
                line = raw.strip()
                if line == "OPEN_OK":
                    self._opened.set()
                elif line.startswith("D "):
                    try:
                        self._queue.put(binascii.unhexlify(line[2:].strip()))
                    except (binascii.Error, ValueError):
                        continue
                elif line.startswith("E "):
                    if not self._opened.is_set():
                        self._open_error = line[2:]
                        self._opened.set()
                    self._queue.put(SerialError("Seri bağlantı koptu.", kind="io"))
        except (OSError, ValueError):
            pass
        finally:
            if not self._opened.is_set():
                self._open_error = "kapandi"
                self._opened.set()
            self._queue.put(SerialError("Seri bağlantı koptu.", kind="io"))

    def wait_open(self, timeout: float) -> None:
        if not self._opened.wait(timeout):
            self.close()
            raise SerialError("Seri port açılamadı (zaman aşımı).", kind="other")
        if self._open_error is not None:
            self.close()
            raise classify_serial_error(Exception(self._open_error), "open")

    def write(self, data: Any) -> None:
        try:
            self._proc.stdin.write("W " + binascii.hexlify(bytes(data)).decode("ascii") + "\n")  # type: ignore[union-attr]
            self._proc.stdin.flush()  # type: ignore[union-attr]
        except (OSError, ValueError):
            raise classify_serial_error(OSError("write"), "io") from None

    def read(self, size: int = 4096, timeout: float = 0.2) -> bytes:
        try:
            item = self._queue.get(timeout=max(timeout, 0.001))
        except queue.Empty:
            return b""
        if isinstance(item, SerialError):
            self._queue.put(item)  # sonraki okumalar da hatayı görsün
            raise item
        chunks = [item]
        total = len(item)
        while total < size:
            try:
                nxt = self._queue.get_nowait()
            except queue.Empty:
                break
            if isinstance(nxt, SerialError):
                self._queue.put(nxt)
                break
            chunks.append(nxt)
            total += len(nxt)
        return b"".join(chunks)

    def close(self) -> None:
        try:
            if self._proc.stdin and not self._proc.stdin.closed:
                self._proc.stdin.write("Q\n")
                self._proc.stdin.flush()
                self._proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self._proc.wait(timeout=2)
        except (subprocess.TimeoutExpired, OSError):
            try:
                self._proc.kill()
                self._proc.wait(timeout=2)
            except (subprocess.TimeoutExpired, OSError):
                pass
        self._reader.join(timeout=1.0)
        try:
            if self._proc.stdout is not None and not self._reader.is_alive():
                self._proc.stdout.close()  # boru dosya tanıtıcısı sızmasın
        except (OSError, ValueError):
            pass


class RelayBackend:
    """Başka bir yorumlayıcıdaki (ör. PlatformIO penv) pyserial'ı alt süreç röleliyle kullanır."""

    kind = "relay"

    def __init__(self, python_exe: str, *, env: Optional[Mapping[str, str]] = None) -> None:
        self.python = python_exe
        self._env = dict(env) if env is not None else None
        self.description = f"pyserial ({python_exe})"

    def _run_env(self) -> Optional[dict[str, str]]:
        if self._env is None:
            return None
        merged = dict(os.environ)
        merged.update(self._env)
        return merged

    def list_ports(self) -> list[tuple[str, str]]:
        try:
            done = subprocess.run(
                [self.python, "-c", _LIST_SCRIPT],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=SERIAL_PROBE_TIMEOUT_S,
                shell=False,
                creationflags=_NO_WINDOW,
                env=self._run_env(),
            )
            items = json.loads(done.stdout or "[]") if done.returncode == 0 else None
        except (OSError, subprocess.SubprocessError, ValueError):
            items = None
        if not isinstance(items, list):
            raise SerialError("Port listesi alınamadı (yardımcı Python çalıştırılamadı).", kind="other")
        return [(str(a), str(b)) for a, b in (i for i in items if isinstance(i, list) and len(i) == 2)]

    def open(self, port: str, baud: int = SERIAL_BAUD) -> _RelayConnection:
        try:
            process = subprocess.Popen(
                [self.python, "-u", "-c", _RELAY_SCRIPT],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                encoding="ascii",
                errors="replace",
                bufsize=1,
                shell=False,
                creationflags=_NO_WINDOW,
                env=self._run_env(),
            )
        except OSError:
            raise SerialError("Yardımcı Python çalıştırılamadı.", kind="other") from None
        connection = _RelayConnection(process)
        try:
            process.stdin.write(f"OPEN {port} {int(baud)}\n")  # type: ignore[union-attr]
            process.stdin.flush()  # type: ignore[union-attr]
        except (OSError, ValueError):
            connection.close()
            raise SerialError("Yardımcı Python ile konuşulamadı.", kind="other") from None
        connection.wait_open(10.0)
        return connection


def platformio_python_candidates(core_dirs: Iterable[str]) -> list[str]:
    """PlatformIO çekirdek dizinlerindeki penv yorumlayıcı adayları (tekrarsız; var olmayanlar elenmez)."""
    seen: list[str] = []
    for root in core_dirs:
        for rel in (("penv", "Scripts", "python.exe"), ("penv", "bin", "python")):
            path = os.path.join(root, *rel)
            if path not in seen:
                seen.append(path)
    return seen


def _default_in_process_probe() -> bool:
    try:
        import serial  # noqa: PLC0415
        import serial.tools.list_ports  # noqa: F401,PLC0415
    except Exception:  # noqa: BLE001 - yanlış "serial" paketi dahil
        return False
    return hasattr(serial, "Serial")


def _default_interpreter_probe(python_exe: str) -> bool:
    if not python_exe or not os.path.isfile(python_exe):
        return False
    try:
        done = subprocess.run(
            [python_exe, "-c", _PROBE_SCRIPT],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=SERIAL_PROBE_TIMEOUT_S,
            shell=False,
            creationflags=_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0 and "PYSERIAL_OK" in (done.stdout or "")


def select_serial_backend(
    extra_pythons: Iterable[str] = (),
    *,
    in_process_probe: Optional[Callable[[], bool]] = None,
    interpreter_probe: Optional[Callable[[str], bool]] = None,
    relay_env: Optional[Mapping[str, str]] = None,
) -> Any:
    """Seri port arka ucunu seçer: (1) aracın kendi Python'unda ``import serial``; (2) PlatformIO penv gibi
    başka bir yorumlayıcıda pyserial (röle). Hiçbiri yoksa ``SerialUnavailableError`` - YENİ PAKET KURULMAZ."""
    probe_here = in_process_probe or _default_in_process_probe
    probe_python = interpreter_probe or _default_interpreter_probe
    if probe_here():
        return PySerialBackend()
    tried: list[str] = []
    for python_exe in extra_pythons:
        tried.append(python_exe)
        if probe_python(python_exe):
            return RelayBackend(python_exe, env=relay_env)
    raise SerialUnavailableError(
        "Bu Python ortamında pyserial bulunamadı"
        + (f" ve {len(tried)} yardımcı Python (PlatformIO) denendi ama onlarda da yok." if tried else " (PlatformIO penv da bulunamadı).")
        + " Araç yeni paket KURMAZ; seri (USB) provizyon bu bilgisayarda kullanılamıyor."
    )


# ---- seri provizyon akışı -----------------------------------------------------------------------------------
_SERIAL_ERRORS: dict[str, tuple[str, str]] = {
    "port_not_found": (
        "Seri port bulunamadı.",
        "USB kablonun VERİ destekli olduğundan ve kartın takılı olduğundan emin olun. Flash sonrası kart yeniden "
        "başlarken port birkaç saniye kaybolur; 1. sekmede 'Portları Yenile'ye basıp tekrar deneyin.",
    ),
    "port_busy": (
        "Seri port başka bir programda açık.",
        "Seri monitör, PuTTY, Arduino/PlatformIO terminali gibi programları kapatıp tekrar deneyin.",
    ),
    "port_io": (
        "Seri bağlantı koptu.",
        "USB kabloyu kontrol edin; kart yeniden başlamış olabilir. Tekrar deneyin.",
    ),
    "serial_error": ("Seri port açılamadı.", "Başka bir USB kablosu veya USB girişi deneyin."),
    "no_response": (
        "Kart seri komutlara yanıt vermedi.",
        "Kartta AHBU firmware'inin çalıştığından emin olun (önce 1. sekmeden yükleyin). USB'yi çıkarıp takın; BOOT "
        "düğmesi basılı olmamalı. Seri port başka bir programda açıksa onu kapatın.",
    ),
    "already_provisioned": (
        "Kartta zaten bir yerel anahtar var (provizyonlu).",
        "Kartı sıfırlamak için 'Anahtarı sıfırla (RESETKEY) ve yeniden dene' seçilebilir; eski anahtar KULLANILAMAZ hale gelir.",
    ),
    "persist_failed": (
        "Kart anahtarı kalıcı belleğe yazamadı (persist_failed).",
        "Kartı yeniden başlatıp tekrar deneyin; sürerse 'Hafızayı Sil (Erase Flash)' ile firmware'i yeniden yükleyin.",
    ),
    "verify_failed": (
        "Kart 'OK' dedi ama yerel anahtar STATUS çıktısında görünmüyor.",
        "Tekrar deneyin; sürerse 'Hafızayı Sil (Erase Flash)' ile firmware'i yeniden yükleyin.",
    ),
    "reset_failed": (
        "Kart eski yerel anahtarı silemedi (RESETKEY).",
        "Kartı yeniden başlatıp tekrar deneyin; sürerse 'Hafızayı Sil (Erase Flash)' ile firmware'i yeniden yükleyin.",
    ),
}


def serial_provision_error(code: str, **context: str) -> ProvisionError:
    """Seri provizyon hata kodunu Türkçe mesaj + ipucu ile ``ProvisionError``'a çevirir (ham satır içermez)."""
    if code in ("invalid_local_key", "invalid_ap_pass"):
        what = "yerel anahtarı" if code == "invalid_local_key" else "AP parolasını"
        return ProvisionError(
            code,
            f"Kart {what} reddetti ({code}).",
            hint="Araç ve firmware sürümleri uyumsuz olabilir; cihazı yeniden kaydedip tekrar deneyin.",
        )
    if code == "mac_mismatch":
        return ProvisionError(
            code,
            f"Bağlı kartın MAC adresi ({context.get('found', '?')}) bu kayıtla ({context.get('expected', '?')}) eşleşmiyor.",
            hint="Doğru kartı bağladığınızdan emin olun.",
        )
    if code in _SERIAL_ERRORS:
        message, hint = _SERIAL_ERRORS[code]
        if code == "port_not_found" and context.get("port"):
            message = f"Seri port bulunamadı ({context['port']})."
        error = ProvisionError(code, message, hint=hint)
        if code == "already_provisioned":
            error.can_reset = True  # type: ignore[attr-defined]
        return error
    safe = code if re.fullmatch(r"[a-z_]{1,40}", code or "") else "bilinmiyor"
    return ProvisionError(
        "unexpected",
        f"Kartın yanıtı anlaşılamadı ({safe}).",
        hint="Firmware sürümünü kontrol edip tekrar deneyin.",
    )


class _Retry(Exception):
    """İç akış: bağlantı denemesi yinelenecek."""


class _Session:
    """Açık seri bağlantı üzerinde satır tabanlı okuma/yazma. Hiçbir şey kaydetmez/loglamaz."""

    def __init__(self, connection: Any, clock: Callable[[], float]) -> None:
        self._conn = connection
        self._clock = clock
        self._lines = _LineBuffer()

    def send(self, data: Any) -> None:
        self._conn.write(data)

    def read_lines(self, timeout: float) -> list[str]:
        chunk = self._conn.read(4096, timeout)
        return self._lines.feed(chunk) if chunk else []

    def drain(self, quiet: float = 0.3, max_total: float = 2.0) -> None:
        """Gelen bayt akışı `quiet` sn boyunca susana kadar (en çok `max_total` sn) okunup atılır."""
        start = self._clock()
        while self._clock() - start < max_total:
            if not self._conn.read(4096, quiet):
                break
        self._lines.clear()

    def close(self) -> None:
        try:
            self._conn.close()
        except Exception:  # noqa: BLE001
            pass


class SerialProvisioner:
    """USB-seri provizyon (``FACTORYINIT``): bağlan -> ``STATUS`` ile kart/durum doğrula -> ``FACTORYINIT`` ->
    ``STATUS`` ile doğrula. Anahtar kablosuz ağdan veya düz HTTP'den geçmez."""

    def __init__(
        self,
        backend: Any,
        *,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._backend = backend
        self._clock = clock
        self._sleep = sleep

    # ---- yardımcılar ----
    @staticmethod
    def _check_cancel(cancel: Optional[threading.Event]) -> None:
        if cancel is not None and cancel.is_set():
            raise ProvisionError("cancelled", "İşlem iptal edildi.")

    def _port_listed(self, port: str) -> bool:
        try:
            return any(device.upper() == port.upper() for device, _ in self._backend.list_ports())
        except FactoryError:
            return True  # liste alınamadı: yine de doğrudan açmayı dene

    def _query_status(self, session: _Session, timeout: float) -> Optional[SerialStatus]:
        session.drain(quiet=0.3, max_total=1.5)
        session.send(b"\r\nSTATUS\r\n")
        deadline = self._clock() + timeout
        info = SerialStatus()
        while self._clock() < deadline:
            for line in session.read_lines(0.3):
                info.absorb(line)
            if info.provisioned is not None:
                return info
        return None

    def _connect_and_probe(
        self,
        port: str,
        wait_for_port: bool,
        say: Callable[[str], None],
        cancel: Optional[threading.Event],
    ) -> tuple[_Session, SerialStatus]:
        deadline = self._clock() + SERIAL_BOOT_WAIT_S + (SERIAL_PORT_WAIT_S if wait_for_port else 0.0)
        session: Optional[_Session] = None
        last: Optional[ProvisionError] = None
        announced_wait = False
        try:
            while True:
                self._check_cancel(cancel)
                try:
                    if session is None:
                        if not self._port_listed(port):
                            last = serial_provision_error("port_not_found", port=port)
                            if not wait_for_port:
                                raise last  # elle başlatma: port yoksa beklemeden hata
                            if not announced_wait:
                                say("Kart yeniden başlıyor; USB seri portun yeniden görünmesi bekleniyor...")
                                announced_wait = True
                            raise _Retry()
                        session = _Session(self._backend.open(port, SERIAL_BAUD), self._clock)
                        say("Seri porta bağlanıldı; kartın açılması ve STATUS yanıtı bekleniyor...")
                    status = self._query_status(session, SERIAL_STATUS_TIMEOUT_S)
                    if status is not None:
                        return session, status
                    last = serial_provision_error("no_response")
                except _Retry:
                    pass
                except SerialError as exc:
                    if session is not None:
                        session.close()
                        session = None
                    mapping = {"not_found": "port_not_found", "busy": "port_busy", "io": "port_io"}
                    last = serial_provision_error(mapping.get(exc.kind, "serial_error"), port=port)
                if self._clock() >= deadline:
                    raise last or serial_provision_error("no_response")
                self._sleep(1.0)
        except BaseException:
            if session is not None:
                session.close()
            raise

    def _reset_key(self, session: _Session, cancel: Optional[threading.Event]) -> None:
        session.drain()
        session.send(b"\r\nRESETKEY\r\n")
        deadline = self._clock() + SERIAL_RESET_TIMEOUT_S
        while self._clock() < deadline:
            self._check_cancel(cancel)
            for line in session.read_lines(0.3):
                match = _RESETKEY_RESULT.search(line)
                if match:
                    if match.group(1) == "SILINDI":
                        return
                    raise serial_provision_error("reset_failed")
        raise serial_provision_error("no_response")

    def _wait_factory_result(self, session: _Session, cancel: Optional[threading.Event]) -> Optional[tuple[bool, str]]:
        deadline = self._clock() + SERIAL_INIT_TIMEOUT_S
        while self._clock() < deadline:
            self._check_cancel(cancel)
            for line in session.read_lines(0.3):
                result = parse_factory_init_result(line)
                if result is not None:
                    return result
        return None

    def _factory_init(
        self,
        session: _Session,
        local_key: str,
        ap_pass: str,
        say: Callable[[str], None],
        cancel: Optional[threading.Event],
    ) -> None:
        for attempt in range(1, SERIAL_PERSIST_RETRIES + 1):
            self._check_cancel(cancel)
            session.drain(quiet=0.2, max_total=1.0)
            session.send(b"\r\n")  # satır tamponunda artık kalmış çöp varsa FACTORYINIT'ten önce temizlenir
            payload = build_factory_init_line(local_key, ap_pass)
            try:
                session.send(payload)
            finally:
                wipe_bytes(payload)
            say("FACTORYINIT gönderildi (parametreler gizli); kartın yanıtı bekleniyor...")
            result = self._wait_factory_result(session, cancel)
            if result is None:  # yanıt gelmedi: belirsiz durum -> önce kartın durumuna bak
                info = self._query_status(session, SERIAL_STATUS_TIMEOUT_S)
                if info is not None and info.provisioned:
                    return  # yanıt gecikti ama kart anahtarı kabul etmiş
                if attempt < SERIAL_PERSIST_RETRIES:
                    say("Karttan yanıt gelmedi; yeniden deneniyor...")
                    continue
                raise serial_provision_error("no_response")
            ok, code = result
            if ok:
                return
            if code == "persist_failed" and attempt < SERIAL_PERSIST_RETRIES:
                say("Kart anahtarı kalıcı belleğe yazamadı; yeniden deneniyor...")
                self._sleep(1.0)
                continue
            raise serial_provision_error(code)
        raise serial_provision_error("persist_failed")

    # ---- ana akış ----
    def provision(
        self,
        port: str,
        local_key: str,
        ap_pass: str,
        *,
        expected_mac: Optional[str] = None,
        reset_existing: bool = False,
        wait_for_port: bool = False,
        progress: Optional[ProgressCallback] = None,
        cancel: Optional[threading.Event] = None,
    ) -> ProvisionOutcome:
        """Karta USB-seri ile yerel anahtar + AP parolası yazar ve ``STATUS`` ile doğrular.

        ``wait_for_port``: flash sonrası (kart yeniden başlar, USB yeniden numaralanır) portun yeniden
        görünmesini bekler. ``reset_existing``: kartta eski anahtar varsa önce ``RESETKEY`` gönderir
        (kullanıcı onayı çağıranın sorumluluğundadır)."""

        def say(message: str) -> None:
            if progress:
                progress(message)

        validate_factory_init_values(local_key, ap_pass)  # geçersizse hiçbir şey gönderilmez
        session, status = self._connect_and_probe(port, wait_for_port, say, cancel)
        try:
            if expected_mac and status.mac and normalize_mac(expected_mac) != status.mac:
                raise serial_provision_error("mac_mismatch", found=status.mac, expected=normalize_mac(expected_mac) or "?")
            if status.provisioned:
                if not reset_existing:
                    raise serial_provision_error("already_provisioned")
                say("Kartta eski yerel anahtar var; RESETKEY gönderiliyor...")
                self._reset_key(session, cancel)
                again = self._query_status(session, SERIAL_STATUS_TIMEOUT_S)
                if again is None or again.provisioned:
                    raise serial_provision_error("reset_failed")
            say("Kart provizyonsuz; yerel anahtar ve AP parolası USB üzerinden yazılıyor (kablosuz ağdan geçmez)...")
            self._factory_init(session, local_key, ap_pass, say, cancel)
            say("Yazma tamam; kart STATUS ile doğrulanıyor...")
            final = None
            for _ in range(3):
                self._check_cancel(cancel)
                final = self._query_status(session, SERIAL_STATUS_TIMEOUT_S)
                if final is not None:
                    break
            if final is None or final.provisioned is not True:
                raise serial_provision_error("verify_failed")
            return ProvisionOutcome(
                initialized=True,
                verified=True,
                needs_reconnect=False,
                device_uid=uid_from_mac(final.mac or status.mac or ""),
                via="serial",
                mac=final.mac or status.mac,
                ap_ssid=final.ap_ssid or status.ap_ssid,
            )
        finally:
            session.close()


# ---------------------------------------------------------------------------
# Kurulum şablonunu karta yazma (İP-3.4; docs/contracts/template/README.md)
#
# USB (seri, fiziksel erişim = yetki, K-Ş4): ``TPL BEGIN <bayt> <crc32>`` -> ``TPL DATA <base64>`` satırları -> ``TPL COMMIT``
# -> ``TPL STATUS`` ile geri okuma. Ethernet (LAN): ``POST /api/template/apply`` (X-Device-Key) -> ``GET /api/template``.
# Gövde (şablon) günlüğe/ilerleme metnine yazılmaz; yerel anahtar ekranda gösterilmez (yalnız başlıkta gider).
# ---------------------------------------------------------------------------
SERIAL_TPL_STEP_TIMEOUT_S = 5.0
SERIAL_TPL_COMMIT_TIMEOUT_S = 20.0
_TPL_REPLY = re.compile(r"(?:^|\s)(OK tpl_[a-z_]{1,20}(?: [^\r\n]{0,80})?|ERR [a-z][a-z0-9_]{0,39}(?: [A-Za-z0-9_.\[\]]{1,64})?)\s*$")
_TPL_STATUS = re.compile(r"^TPL (\S{1,40}) (\d{1,10})(?: (.{0,40}))?$")
_UNKNOWN_TPL = re.compile(r"Bilinmeyen komut: 'TPL'", re.IGNORECASE)


class TemplateWriteError(FactoryError):
    """Şablon yazımı hatası: ``code`` README/kart kodu (``tpl_crc``, ``local_loosen_forbidden``...), ``path`` alan yolu."""

    def __init__(self, code: str, path: str = "", *, message: Optional[str] = None) -> None:
        safe = code if re.fullmatch(r"[a-z0-9_]{1,40}", code or "") else "unknown"
        super().__init__(message or tm.describe_error(safe, path), code=safe)
        self.path = path if re.fullmatch(r"[A-Za-z0-9_.\[\]]{1,64}", path or "") else ""
        self.device_uid: Optional[str] = None  # USB yolunda STATUS'tan bilinen kart (yazım kaydı için)

    @property
    def use_usb(self) -> bool:
        """LAN gevşetme yasağı: araç 'USB ile yazın' der."""
        return self.code == "local_loosen_forbidden"


@dataclass
class TemplateWriteOutcome:
    template_id: str
    version: int
    label: str = ""
    via: str = "usb"                 # "usb" | "eth" (template-writes ``via``)
    device_uid: Optional[str] = None
    mac: Optional[str] = None
    rev: Optional[int] = None


def parse_tpl_status(line: str) -> Optional[tuple[Optional[str], int, str]]:
    """``TPL <id|-> <sürüm> <etiket>`` -> (kimlik ya da None, sürüm, etiket)."""
    match = _TPL_STATUS.match(line.strip())
    if not match:
        return None
    template_id = None if match.group(1) == "-" else match.group(1)
    return template_id, int(match.group(2)), (match.group(3) or "").strip()


class TemplateSerialWriter(SerialProvisioner):
    """USB-seri şablon yazıcı: aynı bağlantı/arka uç altyapısı (``_Session``, ``STATUS`` yoklaması) kullanılır."""

    def _wait_tpl(self, session: _Session, timeout: float, cancel: Optional[threading.Event]) -> tuple[bool, str, str]:
        """(başarılı mı, kod, kalan) - ``OK tpl_<kod> <kalan>`` ya da ``ERR <kod> [yol]``."""
        deadline = self._clock() + timeout
        while self._clock() < deadline:
            self._check_cancel(cancel)
            for line in session.read_lines(0.3):
                if _UNKNOWN_TPL.search(line):
                    raise TemplateWriteError("unsupported_fw")
                match = _TPL_REPLY.search(line)
                if not match:
                    continue
                token = match.group(1)
                if token.startswith("OK "):
                    head, _sep, rest = token[3:].partition(" ")
                    return True, head[4:], rest.strip()
                code, _sep, path = token[4:].partition(" ")
                return False, code, path.strip()
        raise TemplateWriteError("no_response", message="Kart şablon komutuna zamanında yanıt vermedi (USB bağlantısını ve firmware sürümünü kontrol edin).")

    def _expect(self, session: _Session, step: str, timeout: float, cancel: Optional[threading.Event]) -> str:
        ok, code, rest = self._wait_tpl(session, timeout, cancel)
        if not ok:
            raise TemplateWriteError(code, rest)
        if code != step:
            raise TemplateWriteError("unexpected", message=f"Kartın yanıtı beklenen adıma uymuyor (tpl_{code}).")
        return rest

    def _read_status(self, session: _Session, cancel: Optional[threading.Event]) -> Optional[tuple[Optional[str], int, str]]:
        session.drain(quiet=0.2, max_total=1.0)
        session.send(b"TPL STATUS\r\n")
        deadline = self._clock() + SERIAL_TPL_STEP_TIMEOUT_S
        while self._clock() < deadline:
            self._check_cancel(cancel)
            for line in session.read_lines(0.3):
                if _UNKNOWN_TPL.search(line):
                    raise TemplateWriteError("unsupported_fw")
                parsed = parse_tpl_status(line)
                if parsed is not None:
                    return parsed
        return None

    def read_status(self, port: str, *, progress: Optional[ProgressCallback] = None,
                    cancel: Optional[threading.Event] = None) -> Optional[tuple[Optional[str], int, str]]:
        """Karttaki şablonu (``TPL STATUS``) okur: (kimlik|None, sürüm, etiket)."""
        say = progress or (lambda _message: None)
        session, _status = self._connect_and_probe(port, False, say, cancel)
        try:
            return self._read_status(session, cancel)
        finally:
            session.close()

    def write(
        self,
        port: str,
        envelope: bytes,
        *,
        template_id: str,
        version: int,
        label: str = "",
        expected_uid: Optional[str] = None,
        wait_for_port: bool = False,
        progress: Optional[ProgressCallback] = None,
        cancel: Optional[threading.Event] = None,
    ) -> TemplateWriteOutcome:
        """Şablon zarfını karta yazar ve ``TPL STATUS`` ile geri okuyup doğrular. Hata -> ``TemplateWriteError``."""

        def say(message: str) -> None:
            if progress:
                progress(message)

        if not envelope or len(envelope) > tm.MAX_ENVELOPE_BYTES:
            raise TemplateWriteError("tpl_size")
        session, status = self._connect_and_probe(port, wait_for_port, say, cancel)
        begun = False
        found_uid = uid_from_mac(status.mac or "")
        try:
            if expected_uid and not found_uid:
                raise TemplateWriteError(
                    "mac_mismatch",
                    message="Bağlı kartın kimliği (MAC) okunamadı; kartın seçilen kart "
                    f"({expected_uid.strip().upper()}) olduğu doğrulanamadı. Hiçbir şey yazılmadı; kartı yeniden bağlayıp tekrar deneyin.",
                )
            if expected_uid and found_uid and found_uid != expected_uid.strip().upper():
                raise TemplateWriteError(
                    "mac_mismatch",
                    message=f"Bağlı kart ({found_uid}) seçilen daireye bağlı kartla ({expected_uid.strip().upper()}) eşleşmiyor; "
                    "hiçbir şey yazılmadı. Doğru kartı bağlayın.",
                )
            chunks = tm.serial_chunks(envelope)
            session.drain(quiet=0.2, max_total=1.0)
            session.send(b"\r\n")
            say(f"Şablon USB ile gönderiliyor ({len(envelope)} bayt, {len(chunks)} parça)...")
            session.send(f"TPL BEGIN {len(envelope)} {tm.crc32_hex(envelope)}\r\n".encode("ascii"))
            begun = True
            self._expect(session, "begin", SERIAL_TPL_STEP_TIMEOUT_S, cancel)
            sent = 0
            for index, chunk in enumerate(chunks):
                session.send(f"TPL DATA {chunk}\r\n".encode("ascii"))
                sent += len(base64_decoded_length(chunk))
                received = self._expect(session, "data", SERIAL_TPL_STEP_TIMEOUT_S, cancel)
                if received.isdigit() and int(received) != sent:
                    raise TemplateWriteError("tpl_overflow")
                if progress and (index + 1) % 20 == 0:
                    say(f"  ... {index + 1}/{len(chunks)} parça gönderildi")
            say("Tüm parçalar gönderildi; kart şablonu doğrulayıp uyguluyor (TPL COMMIT)...")
            session.send(b"TPL COMMIT\r\n")
            try:
                rest = self._expect(session, "applied", SERIAL_TPL_COMMIT_TIMEOUT_S, cancel)
            except TemplateWriteError as exc:
                if exc.code != "no_response":
                    raise
                # COMMIT yanıtı kayboldu: kart uygulamış olabilir -> TPL STATUS ile karar ver (uygulanmışsa başarı).
                say("COMMIT yanıtı gelmedi; kartın şablon durumu TPL STATUS ile denetleniyor...")
                back = self._read_status(session, cancel)
                if back is None or back[0] != template_id or back[1] != int(version):
                    raise
                rest = f"{template_id} {int(version)}"
            begun = False
            parts = rest.split()
            if len(parts) < 2 or parts[0] != template_id or not parts[1].isdigit() or int(parts[1]) != int(version):
                raise TemplateWriteError("readback_mismatch")
            say("Kart şablonu uyguladı; TPL STATUS ile geri okunuyor...")
            back = self._read_status(session, cancel)
            if back is None or back[0] != template_id or back[1] != int(version):
                raise TemplateWriteError("readback_mismatch")
            return TemplateWriteOutcome(
                template_id=template_id,
                version=int(version),
                label=back[2] or label,
                via="usb",
                device_uid=uid_from_mac(status.mac or ""),
                mac=status.mac,
            )
        except BaseException as exc:
            if isinstance(exc, TemplateWriteError) and exc.code != "mac_mismatch":
                exc.device_uid = found_uid
            if begun:  # yarım aktarım kartta silinsin (en iyi çaba)
                try:
                    session.send(b"TPL ABORT\r\n")
                except FactoryError:
                    pass
            raise
        finally:
            session.close()


def base64_decoded_length(chunk: str) -> bytes:
    """Base64 parçasının çözülmüş baytları (yalnız uzunluk denetimi için)."""
    return binascii.a2b_base64(chunk.encode("ascii"))


class TemplateLanWriter:
    """Ethernet/LAN üzerinden şablon yazımı (yerel anahtarla; yalnız özel/yerel IP)."""

    PENDING_POLL_S = 1.0
    PENDING_MAX_S = 20.0

    def __init__(self, host: str, *, transport: Optional[Transport] = None, timeout: float = 15.0,
                 sleep: Callable[[float], None] = time.sleep) -> None:
        if not (host or "").strip():
            raise ValueError("Kartın IP adresini girin.")
        self._device = DeviceClient(host, transport=transport, env={}, timeout=timeout)
        self._sleep = sleep

    @property
    def host(self) -> str:
        return self._device.host

    def _send(self, method: str, path: str, key: str, raw: Optional[bytes] = None) -> tuple[int, Optional[dict[str, Any]], Mapping[str, str]]:
        try:
            return self._device._request(method, path, key=key, raw_json=raw)
        except ProvisionError:
            raise TemplateWriteError("unreachable") from None

    @staticmethod
    def _error(status: int, payload: Optional[dict[str, Any]]) -> TemplateWriteError:
        err = DeviceClient._error_id(payload)
        path = payload.get("path") if payload and isinstance(payload.get("path"), str) else ""
        if status == 401:
            return TemplateWriteError("key_mismatch")
        if status == 423:
            return TemplateWriteError("locked")
        if status == 404 or err == "not_found":
            return TemplateWriteError("unsupported_fw")
        if status == 507:
            return TemplateWriteError("storage")
        if status == 413:
            return TemplateWriteError("tpl_size")
        if err == "cfg_invalid":  # 409 {"error":"cfg_invalid","detail":"<CfgErr metni>"}
            detail = payload.get("detail") if payload else None
            if isinstance(detail, str) and _DETAIL_CODE_PATTERN.match(detail):
                return TemplateWriteError("cfg_invalid", message=tm.describe_error("cfg_invalid") + " Ayrıntı: "
                                          + tm.describe_error(detail, path))
            return TemplateWriteError("cfg_invalid", path)
        if err:
            return TemplateWriteError(err, path)
        if status in (409, 503):
            return TemplateWriteError("busy")
        return TemplateWriteError("unexpected", message=f"Karttan beklenmeyen yanıt alındı (HTTP {status}).")

    def apply(self, local_key: str, envelope: bytes) -> dict[str, Any]:
        """``POST /api/template/apply`` -> ``{"ok":true,"template_id","version","rev"}``."""
        if not is_valid_local_key(local_key):
            raise TemplateWriteError("key_mismatch")
        status, payload, _headers = self._send("POST", "/api/template/apply", local_key, envelope)
        if status == 200 and payload is not None and payload.get("ok") is True:
            return payload
        if status == 202 and payload is not None and payload.get("pending") is True:
            return payload  # kart hâlâ yazıyor: çağıran GET /api/template ile bekler
        raise self._error(status, payload)

    def read(self, local_key: str) -> dict[str, Any]:
        """``GET /api/template`` -> ``{"template_id","version","label","applied_at_uptime_s"}``."""
        status, payload, _headers = self._send("GET", "/api/template", local_key)
        if status == 200 and payload is not None:
            return payload
        raise self._error(status, payload)

    def verify_identity(self, *expected_uids: Optional[str]) -> str:
        """Anahtarsız ``GET /api/status`` ile bu IP'deki kartın UID'sini okur; beklenen UID(ler)le eşleşmezse yerel anahtar
        ALINMADAN/GÖNDERİLMEDEN ``TemplateWriteError("device_mismatch")``."""
        try:
            found = str(self._device.status().get("device") or "").strip().upper()
        except ProvisionError as exc:
            if exc.code == "unreachable":
                raise TemplateWriteError("unreachable") from None
            raise TemplateWriteError(
                "device_mismatch",
                message="Bu IP adresindeki cihaz bir AHBU kartı gibi yanıt vermedi; yerel anahtar alınmadı, hiçbir şey yazılmadı.",
            ) from None
        for expected in expected_uids:
            if expected and found != expected.strip().upper():
                raise TemplateWriteError(
                    "device_mismatch",
                    message=f"Bu IP adresindeki kart ({found or '?'}) seçilen kartla ({expected.strip().upper()}) eşleşmiyor; "
                    "yerel anahtar alınmadı, hiçbir şey yazılmadı. IP adresini kontrol edin.",
                )
        return found

    def write(self, local_key: str, envelope: bytes, *, template_id: str, version: int, label: str = "",
              device_uid: Optional[str] = None, progress: Optional[ProgressCallback] = None) -> TemplateWriteOutcome:
        say = progress or (lambda _message: None)
        say(f"Şablon Ethernet ile gönderiliyor (http://{self.host}/api/template/apply, yerel anahtar gizli)...")
        try:
            reply = self.apply(local_key, envelope)
        except TemplateWriteError as exc:
            if exc.code != "unreachable":
                raise
            # Gönderimden sonra bağlantı koptu: kart uygulamış olabilir -> GET /api/template ile karar ver.
            say("Karttan yanıt alınamadı; şablon durumu GET /api/template ile denetleniyor...")
            try:
                back = self.read(local_key)
            except TemplateWriteError:
                raise exc from None
            if back.get("template_id") != template_id or back.get("version") != int(version):
                raise exc from None
            reply = {"ok": True, "template_id": template_id, "version": int(version)}
        if reply.get("pending") is True:  # 202: kart NVS'e yazıyor -> GET /api/template ile 1 sn arayla en çok 20 sn bekle
            say("Kart şablonu yazıyor (202 pending); GET /api/template ile bekleniyor...")
            waited = 0.0
            while True:
                try:
                    back = self.read(local_key)
                except TemplateWriteError as exc:
                    if exc.code not in ("unreachable", "busy"):
                        raise
                    back = {}
                if back.get("template_id") == template_id and back.get("version") == int(version):
                    reply = {"ok": True, "template_id": template_id, "version": int(version)}
                    break
                if waited >= self.PENDING_MAX_S:
                    raise TemplateWriteError("tpl_timeout", message="Kart şablonu 20 sn içinde uygulamadı (202 pending). "
                                             "Kartın durumunu kontrol edip yeniden deneyin ya da USB ile yazın.")
                self._sleep(self.PENDING_POLL_S)
                waited += self.PENDING_POLL_S
        if reply.get("template_id") not in (None, template_id) or reply.get("version") not in (None, int(version)):
            raise TemplateWriteError("readback_mismatch")
        say("Kart şablonu uyguladı; GET /api/template ile geri okunuyor...")
        back = self.read(local_key)
        if back.get("template_id") != template_id or back.get("version") != int(version):
            raise TemplateWriteError("readback_mismatch")
        rev = reply.get("rev")
        return TemplateWriteOutcome(
            template_id=template_id,
            version=int(version),
            label=str(back.get("label") or label),
            via="eth",
            device_uid=device_uid,
            rev=rev if isinstance(rev, int) and not isinstance(rev, bool) else None,
        )
