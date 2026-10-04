# pyright: reportUnknownParameterType=false, reportUnknownArgumentType=false, reportUnknownVariableType=false, reportUnknownMemberType=false, reportMissingTypeStubs=false
"""
AHBU Ev Otomasyon Sistemi - Servis ve Üretim (Fabrika) Aracı

1. Firmware Yükleyici (Waveshare ESP32-S3 Flasher)
2. Envanter kaydı + Karekod/Etiket üretimi   (sunucu: süper kullanıcı e-posta + parola). Etiket İKİ karekod taşır:
   1) Daireye bağla (PIN'li claim adresi, uygulama okur) ve 2) Kurulum Wi-Fi'sine bağlan (standart Wi-Fi karekodu
   ``WIFI:T:WPA;S:<AP SSID>;P:<ap_pass>;;``, telefon kamerası okur; ap_pass yalnızca metinde ve bu karekodda)
3. Cihaz provizyonu (flash sonrası): TERCİHEN USB (seri) `FACTORYINIT` (anahtar kablosuz ağdan geçmez);
   YEDEK (güvensiz): kartın açık kurulum ağı üzerinden POST /api/factory/init

Güvenlik ilkeleri (docs/CONTRACTS.md):
* Kodda sabit API anahtarı / parola YOKTUR. Sunucu kimlik bilgisi yalnızca çalışma anında diyalogdan
  alınır (parola saklanmaz); isteğe bağlı ADMIN_API_KEY ortam değişkeni (>= 32 karakter) x-api-key olur.
* Envanter yanıtındaki local_key ve PIN'li karekod adresi YALNIZCA BİR KEZ gelir: bellekte tutulur,
  etikete yazılır ve cihaza provizyonda kullanılır. Diske yalnızca kullanıcı "Etiketi Kaydet" derse etiket
  görseli (PNG) olarak yazılır; düz metin JSON/log yoktur. Gizli değerler loglanmaz.
* PIN ve cihaza özel AP parolası yalnızca `secrets` ile üretilir (`random` kullanılmaz).
* Ağ ve flash işlemleri arka plan iş parçacığında çalışır; arayüz donmaz. subprocess çağrıları liste
  argümanlıdır (kabuk/shell kullanılmaz); port ve esptool/firmware yolları doğrulanır.

Ağ/güvenlik mantığı `factory_client.py` içindedir (Tk'siz, test edilebilir).

Ortam değişkenleri (hepsi isteğe bağlı):
  EV_SERVER_URL      Sunucu adresi (varsayılan https://evotomasyon.gudeteknoloji.com.tr; QA için http://127.0.0.1:5000).
                     Düz http yalnızca loopback için kabul edilir.
  EV_DEVICE_AP_HOST  Cihaz kurulum ağı adresi (varsayılan 192.168.4.1; QA simülatörü için 127.0.0.1:8081).
                     Yalnızca yerel/özel ağ adresleri kabul edilir.
  ADMIN_API_KEY      >= 32 karakterse giriş diyaloğunda "ADMIN_API_KEY ile devam" seçeneği çıkar (x-api-key; kayıt ve
                     liste için yeter, durum değiştirme/silme için e-posta + parola gerekir). Değer asla gösterilmez.
  ESPTOOL_PATH       esptool.py / esptool.exe yolu (yoksa PlatformIO paketi, PATH ve `python -m esptool` aranır).
  EV_TOOL_DEBUG=1    Hata ayıklama: yalnızca istisna sınıf adları stderr'e yazılır (gizli değer içermez).
  EV_TOOL_THEME      Görünüm: dark | light (tercih dosyasını geçersiz kılar; görünüm belirteçleri tool_theme.py'dedir).
"""

from __future__ import annotations

import importlib.util
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import textwrap
import threading
import traceback
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Optional

import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

# Temel dizinler ve sabit donanım parametreleri
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

_MISSING_DEPENDENCY: Optional[str] = None
try:
    import qrcode
    from PIL import Image, ImageDraw, ImageFont, ImageTk
except ImportError as _import_error:  # pragma: no cover - ortam sorunu
    _MISSING_DEPENDENCY = str(_import_error)
# Not: pyserial İSTEĞE BAĞLIDIR (factory_client.select_serial_backend): yoksa PlatformIO penv'deki pyserial röle ile
# kullanılır; hiçbirinde yoksa seri provizyon kapanır ve yedek Wi-Fi yolu önerilir (yeni paket KURULMAZ).

from factory_client import (  # noqa: E402
    DEFAULT_DEVICE_HOST,
    DEFAULT_SERVER_URL,
    ENV_SERVER_URL,
    LABEL_TEXT_PATTERN,
    PIN_PATTERN,
    UID_PATTERN,
    ApiError,
    DeviceClient,
    DeviceRecord,
    FactoryError,
    ProvisionError,
    RelayBackend,
    SecretScrubber,
    SerialProvisioner,
    SerialUnavailableError,
    ServerClient,
    SessionExpiredError,
    SERIAL_BAUD,
    ap_ssid_from_mac,
    build_claim_url,
    claim_url_matches,
    device_wifi_qr_payload,
    generate_ap_pass,
    generate_setup_pin,
    manual_provision_instructions,
    normalize_mac,
    normalize_server_url,
    platformio_python_candidates,
    provision_error_text,
    provision_urgency_notice,
    select_serial_backend,
    uid_from_mac,
)
from tool_theme import (  # noqa: E402 - görsel tema: belirteçler/ttk stili/widget rolleri (iş mantığı içermez)
    THEME_DARK,
    THEME_LIGHT,
    ThemeManager,
    load_theme_preference,
    log_line_tag,
    theme_of,
)
from session_store import (  # noqa: E402 - "Beni hatırla": DPAPI şifreli refresh token + kimlik (parola ASLA saklanmaz)
    EXPIRED as RESTORE_EXPIRED,
    FORBIDDEN as RESTORE_FORBIDDEN,
    MISMATCH as RESTORE_MISMATCH,
    NETWORK as RESTORE_NETWORK,
    RESTORED as RESTORE_OK,
    SessionKeeper,
    SessionStore,
)

DEMO_DIR = os.path.join(BASE_DIR, "waveshare_s3_demo")
FACTORY_BIN = os.path.join(DEMO_DIR, "Firmware", "ESP32-S3-POE-ETH-8DI-8RO.bin")
RELEASES_DIR = os.path.join(DEMO_DIR, "firmware_releases")
VERSION_FILE = os.path.join(RELEASES_DIR, "version_info.json")

# Cihazın sabit donanım ayarları
DEFAULT_CHIP = "esp32s3"
DEFAULT_BAUD = "460800"
FLASH_OFFSET = "0x0"
DEFAULT_MODEL = "ESP32-S3-POE-ETH-8DI-8RO"

# esptool işlem zaman aşımları (sn): takılan işlem süresiz beklemez
ESPTOOL_TIMEOUT_S = {"read_mac": 30, "chip_id": 30, "erase_flash": 240, "write_flash": 900}
MIN_FIRMWARE_BYTES = 64 * 1024
MAX_FIRMWARE_BYTES = 16 * 1024 * 1024
LABEL_PRINT_NOTE = "Etiket PIN ve AP parolası içerir (2. karekod da parolayı taşır); yazdırdıktan sonra dosyayı silin."
LABEL_PLACEHOLDER_TEXT = "Henüz etiket üretilmedi.\nSoldaki formdan 'SUNUCU ENVANTERİNE KAYDET' düğmesine basın."
# Provizyon bekleme süreleri (sn): flash sonrası kullanıcı bilgisayarı kurulum ağına bağlarken
PROVISION_WAIT_AFTER_FLASH_S = 180
PROVISION_WAIT_MANUAL_S = 12
_ESPTOOL_MAC_LINE = re.compile(r"\bMAC:\s*((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})")

DEBUG_ENABLED = os.environ.get("EV_TOOL_DEBUG") == "1"
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0


class ToolError(RuntimeError):
    """Kullanıcıya doğrudan gösterilebilen yerel hata (port/dosya/esptool sorunu)."""


# ===========================================================================
# Sürüm bilgisi yardımcıları
# ===========================================================================
def load_version_info() -> dict[str, Any]:
    """Geliştirilen yazılımın versiyon bilgisini okur."""
    if os.path.exists(VERSION_FILE):
        try:
            with open(VERSION_FILE, "r", encoding="utf-8") as handle:
                data = json.load(handle)
            if isinstance(data, dict):
                return data
        except (OSError, ValueError):
            pass
    return {
        "current_version": "1.0.0",
        "firmware_file": "v1.0.0/firmware_v1.0.0.bin",
        "updated_at": datetime.now().isoformat(),
    }


def save_version_info(data: dict[str, Any]) -> None:
    """Versiyon bilgisini atomik olarak kaydeder."""
    os.makedirs(RELEASES_DIR, exist_ok=True)
    tmp_path = VERSION_FILE + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
    os.replace(tmp_path, VERSION_FILE)


def increment_version_str(ver_str: str) -> str:
    """1.0.0 -> 1.0.1 şeklinde versiyonu artırır."""
    parts = ver_str.split(".")
    if len(parts) == 3:
        try:
            major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
            return f"{major}.{minor}.{patch + 1}"
        except ValueError:
            pass
    return f"{ver_str}.1"


def format_serial_badge(serial_val: Any) -> str:
    """Sıra numarasını güvenli şekilde 4 haneli badge formatına (#0001) dönüştürür."""
    if serial_val is None or str(serial_val).strip() == "":
        return "#0001"
    try:
        clean = str(serial_val).replace("#", "").strip()
        return f"#{int(clean):04d}"
    except (TypeError, ValueError):
        clean_str = str(serial_val).strip()
        return f"#{clean_str}" if not clean_str.startswith("#") else clean_str


# ===========================================================================
# esptool / port / firmware doğrulaması
# ===========================================================================
_ESPTOOL_FILE_NAMES = {"esptool.py", "esptool", "esptool.exe"}


def _platformio_core_dirs() -> list[str]:
    dirs: list[str] = []
    env_dir = os.environ.get("PLATFORMIO_CORE_DIR", "").strip()
    if env_dir:
        dirs.append(env_dir)
    try:  # makineye özel çekirdek dizini (depoya girmeyen dosya)
        with open(os.path.join(DEMO_DIR, "platformio_local.ini"), "r", encoding="utf-8") as handle:
            match = re.search(r"(?m)^\s*core_dir\s*=\s*(.+?)\s*$", handle.read())
        if match:
            dirs.append(match.group(1).strip().strip('"'))
    except OSError:
        pass
    dirs.append(os.path.join(os.path.expanduser("~"), ".platformio"))
    profile = os.environ.get("USERPROFILE", "")
    if profile:
        dirs.append(os.path.join(profile, ".platformio"))
    return dirs


def _valid_esptool_file(path: str) -> bool:
    return bool(path) and os.path.isfile(path) and os.path.basename(path).lower() in _ESPTOOL_FILE_NAMES


def _esptool_command_for(path: str) -> list[str]:
    return [sys.executable, path] if path.lower().endswith(".py") else [path]


def find_esptool_command() -> list[str]:
    """esptool çalıştırma komutunu (argüman listesi) bulur ve doğrular; bulunamazsa ToolError.

    Sıra: ESPTOOL_PATH ortam değişkeni -> PlatformIO paketi -> PATH -> `python -m esptool`."""
    explicit = os.environ.get("ESPTOOL_PATH", "").strip().strip('"')
    if explicit:
        if not _valid_esptool_file(explicit):
            raise ToolError("ESPTOOL_PATH geçerli bir esptool dosyasını (esptool.py / esptool.exe) göstermiyor.")
        return _esptool_command_for(explicit)
    for root in _platformio_core_dirs():
        candidate = os.path.join(root, "packages", "tool-esptoolpy", "esptool.py")
        if _valid_esptool_file(candidate):
            return _esptool_command_for(candidate)
    for name in ("esptool.py", "esptool"):
        found = shutil.which(name)
        if found and _valid_esptool_file(found):
            return _esptool_command_for(found)
    if importlib.util.find_spec("esptool") is not None:
        return [sys.executable, "-m", "esptool"]
    raise ToolError(
        "esptool bulunamadı.\n"
        "Kurulum: 'pip install esptool' komutunu çalıştırın veya PlatformIO'yu kurun; ya da ESPTOOL_PATH "
        "ortam değişkenine esptool.py dosyasının yolunu yazın."
    )


_WINDOWS_PORT = re.compile(r"^COM[1-9][0-9]{0,2}$", re.IGNORECASE)
_POSIX_PORT = re.compile(r"^/dev/(?:tty|cu)[A-Za-z0-9._\-]{1,40}$")


def validate_serial_port(port: Any, available: Optional[set[str]] = None, *, windows: Optional[bool] = None) -> str:
    """Seri port adını doğrular (seçenek enjeksiyonu/yanlış cihaz engeli); geçerli adı döndürür."""
    if not isinstance(port, str) or not port.strip():
        raise ToolError("Lütfen önce bir COM portu seçin!")
    value = port.strip()
    is_windows = (os.name == "nt") if windows is None else windows
    pattern = _WINDOWS_PORT if is_windows else _POSIX_PORT
    if not pattern.match(value):
        raise ToolError(f"Geçersiz port adı: '{value[:24]}'. Açılır kutudan bir port seçin.")
    if available is not None:
        known = {item.upper() for item in available} if is_windows else set(available)
        if (value.upper() if is_windows else value) not in known:
            raise ToolError(f"'{value}' portu şu anda bağlı değil. USB kabloyu kontrol edip 'Portları Yenile'ye basın.")
    return value.upper() if is_windows else value


# AHBU firmware'inin seri CLI komutu (docs/CONTRACTS.md §3c). Komut adı imajda düz metin olarak bulunur; yoksa imaj
# USB (seri) provizyonu bilmeyen ESKİ bir sürümdür (kart flash sonrası provizyonlanamaz).
SERIAL_PROVISION_MARKER = b"FACTORYINIT"
STALE_FIRMWARE_WARNING = (
    "Bu imajda USB (seri) provizyon komutu (FACTORYINIT) bulunamadı: ESKİ bir firmware olabilir. Yüklerseniz kart "
    "USB üzerinden provizyonlanamaz ('Kart seri komutlara yanıt vermedi' hatası alırsınız) ve yedek Wi-Fi yolu da "
    "çalışmayabilir. Güncel firmware'i derleyip birleşik imaj olarak 'firmware_releases' altına koymanız önerilir."
)


@dataclass
class FirmwareCheck:
    path: str
    size: int
    warnings: list[str] = field(default_factory=list)
    supports_serial_provisioning: Optional[bool] = None  # None: denetlenmedi


def inspect_firmware_file(path: Any, *, expect_serial_provisioning: bool = False) -> FirmwareCheck:
    """0x0'a yazılacak firmware dosyasını doğrular. Ölümcül sorunda ToolError; şüpheli ise uyarı listesi.

    ``expect_serial_provisioning``: AHBU firmware'i yüklenecekse imajda ``FACTORYINIT`` komutunun bulunup bulunmadığı da
    denetlenir (eski imaj uyarısı)."""
    if not isinstance(path, str) or not path.strip():
        raise ToolError("Firmware dosyası seçilmedi.")
    full = os.path.abspath(os.path.expanduser(path.strip().strip('"')))
    if not os.path.isfile(full):
        raise ToolError(f"Seçilen firmware dosyası bulunamadı:\n{full}")
    if not full.lower().endswith(".bin"):
        raise ToolError("Firmware dosyası .bin uzantılı olmalıdır.")
    size = os.path.getsize(full)
    if size < MIN_FIRMWARE_BYTES or size > MAX_FIRMWARE_BYTES:
        raise ToolError(
            f"Firmware dosyasının boyutu beklenen aralığın dışında ({size} bayt). Yanlış dosya seçilmiş olabilir."
        )
    has_marker: Optional[bool] = None
    try:
        with open(full, "rb") as handle:
            head = handle.read(1)
            handle.seek(0x8000)
            partition_magic = handle.read(2)
            if expect_serial_provisioning and head == b"\xe9":
                handle.seek(0)
                has_marker = SERIAL_PROVISION_MARKER in handle.read(MAX_FIRMWARE_BYTES)
    except OSError as exc:
        raise ToolError("Firmware dosyası okunamadı (izin veya disk sorunu).") from exc
    if head != b"\xe9":
        raise ToolError("Dosya geçerli bir ESP32 imajı değil (ilk bayt 0xE9 olmalı). Yanlış dosya seçilmiş olabilir.")
    warnings: list[str] = []
    if partition_magic != b"\xaa\x50":
        warnings.append(
            "Bu dosya bootloader + bölüm tablosu + uygulama içeren BİRLEŞİK imaj gibi görünmüyor "
            "(0x8000'de bölüm tablosu yok). 0x0 adresine yazılırsa kart açılmayabilir."
        )
    if has_marker is False:
        warnings.append(STALE_FIRMWARE_WARNING)
    return FirmwareCheck(full, size, warnings, has_marker)


# ===========================================================================
# Etiket (karekod) üretimi
# ===========================================================================
_TR_TO_ASCII = str.maketrans("İıŞşĞğÜüÖöÇç", "IiSsGgUuOoCc")
_REGULAR_FONTS = ("segoeui.ttf", "arial.ttf", "tahoma.ttf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf")
_BOLD_FONTS = ("segoeuib.ttf", "arialbd.ttf", "tahomabd.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf")
# Etiket: 100 x 50 mm (4 x 2 inç) @ 203 dpi. İKİ karekod: solda 1) Daireye bağla (PIN'li claim adresi, uygulama okur),
# sağda 2) Kurulum Wi-Fi'sine bağlan (standart Wi-Fi karekodu, telefon kamerası okur); ortada okunabilir metinler.
LABEL_SIZE = (800, 400)
LABEL_DPI = (203, 203)  # PNG'ye yazılır: yazdırma gerçek boyutu (100 x 50 mm) bilsin
LABEL_QR_MAX_PX = 205
LABEL_MARGIN_X = 14
LABEL_COL_LEFT_W = 232   # 1. karekod sütunu
LABEL_COL_RIGHT_W = 262  # 2. karekod sütunu (başlığı daha uzun)
LABEL_QR_TOP = 92
LABEL_HEADING_CLAIM = "1) Daireye bağla (uygulama)"
LABEL_HEADING_WIFI = "2) Kurulum Wi-Fi'sine bağlan (telefon kamerası)"
LABEL_CAPTION_CLAIM_QR = "Karekodu uygulamayla okutun"
LABEL_CAPTION_WIFI_QR = "Telefon kamerasıyla okutun, ağa bağlanın"
LABEL_SECURITY_NOTE = "GİZLİ: Bu etiket yalnızca cihaz üzerinde/elde saklanır; fotoğrafı paylaşılmaz (kurulum parolası ve PIN içerir)."
LABEL_WIFI_MISSING_NOTE = "Wi-Fi karekodu üretilemedi (MAC veya AP parolası geçersiz)."
LABEL_PHONE_CHECK_HINT = (
    "Önerilir: yapıştırmadan önce telefon kamerasıyla etiketteki 2. karekodu okutup kurulum ağına bağlanabildiğinizi "
    "deneyin (ağ provizyondan sonra yaklaşık 10 dk açıktır)."
)


def label_qr_payload(record: DeviceRecord) -> str:
    """1. karekod içeriği: ``https://<host>/claim?uid=<UID>&pin=<PIN>`` (uygulamanın QrClaimParser biçimi).
    AP parolasını İÇERMEZ."""
    if claim_url_matches(record.qr_claim_url, record.uid, record.pin):
        return record.qr_claim_url
    return build_claim_url(record.uid, record.pin)


def label_wifi_qr_payload(record: DeviceRecord) -> Optional[str]:
    """2. karekod içeriği: ``WIFI:T:WPA;S:<AP SSID>;P:<ap_pass>;;`` (kaçışlı). AP parolasını içerdiği için GİZLİDİR:
    yalnızca etiket görseline gider. MAC/parola geçersizse None."""
    try:
        return device_wifi_qr_payload(record.mac, record.ap_pass)
    except ValueError:
        return None


LABEL_CAPTION_PIN = "KURULUM PIN"
LABEL_CAPTION_MAC = "MAC ADRESİ"


def label_text_lines(record: DeviceRecord) -> list[tuple[str, str]]:
    """Etiketin okunabilir metin alanları (başlık, değer). PIN ve AP parolası YALNIZCA etikette bulunur."""
    pin = record.pin
    pin_text = f"{pin[:3]} {pin[3:]}" if len(pin) == 6 else pin
    return [
        ("CİHAZ SERİ NO (UID)", record.uid),
        (LABEL_CAPTION_PIN, pin_text),
        ("KURULUM Wi-Fi AĞI", record.ap_ssid or "-"),
        ("AĞ PAROLASI (AP)", record.ap_pass),
        (LABEL_CAPTION_MAC, record.mac),
    ]


def _load_font(candidates: tuple[str, ...], size: int):
    for name in candidates:
        try:
            return ImageFont.truetype(name, size), True
        except OSError:
            continue
    try:
        return ImageFont.load_default(size), False
    except (TypeError, OSError):  # eski Pillow veya FreeType yok
        return ImageFont.load_default(), False


def _local_datetime_text(value: Any) -> str:
    """ISO-8601 (UTC 'Z' dahil) zamanı yerel saatte 'GG.AA.YYYY SS:DD' biçimine çevirir (boşsa '')."""
    if not value:
        return ""
    try:
        moment = value if isinstance(value, datetime) else datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if moment.tzinfo is not None:
            moment = moment.astimezone()
        return moment.strftime("%d.%m.%Y %H:%M")
    except (ValueError, OverflowError, OSError):
        return str(value)[:16]


def _label_date(created_at: Any) -> str:
    return _local_datetime_text(created_at) or datetime.now().strftime("%d.%m.%Y %H:%M")


def make_qr_image(payload: str, max_px: int = LABEL_QR_MAX_PX):
    """Karekod görseli: hata düzeltme M, 2 modül sessiz bölge, tam sayı modül boyutu (bulanıklık yok)."""
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2)
    qr.add_data(payload)
    qr.make(fit=True)
    qr.box_size = max(2, max_px // (qr.modules_count + 2 * qr.border))
    return qr.make_image(fill_color="black", back_color="white").convert("RGB")


def label_columns() -> tuple[tuple[int, int], tuple[int, int], tuple[int, int]]:
    """Etiketin üç sütunu (x başlangıç, x bitiş): solda 1. karekod, ortada metinler, sağda 2. karekod."""
    width = LABEL_SIZE[0]
    left = (LABEL_MARGIN_X, LABEL_MARGIN_X + LABEL_COL_LEFT_W)
    right = (width - LABEL_MARGIN_X - LABEL_COL_RIGHT_W, width - LABEL_MARGIN_X)
    return left, (left[1], right[0]), right


def label_qr_positions(claim_size: tuple[int, int], wifi_size: tuple[int, int]) -> tuple[tuple[int, int], tuple[int, int]]:
    """1. (claim, solda) ve 2. (Wi-Fi, sağda) karekodun sol-üst köşe konumları: her biri kendi sütununda ortalanır."""
    left, _middle, right = label_columns()
    return (
        (left[0] + (left[1] - left[0] - claim_size[0]) // 2, LABEL_QR_TOP),
        (right[0] + (right[1] - right[0] - wifi_size[0]) // 2, LABEL_QR_TOP),
    )


def _split_heading(text: str) -> tuple[str, str]:
    """'1) Daireye bağla (uygulama)' -> ('1) Daireye bağla', '(uygulama)'): başlık iki satıra bölünür."""
    head, sep, tail = text.partition(" (")
    return (head, "(" + tail) if sep else (text, "")


def build_label_image(record: DeviceRecord):
    """Pillow ile etiket görseli üretir (bellekte; diske YAZMAZ). İKİ karekod içerir:
    1) ``label_qr_payload``: claim adresi (UID + PIN; AP parolası YOK) - uygulama okur;
    2) ``label_wifi_qr_payload``: kurulum Wi-Fi'si (AP SSID + ap_pass) - telefon kamerası okur.
    ap_pass etikette yalnızca metinde ve 2. karekodda bulunur."""
    width, height = LABEL_SIZE
    img = Image.new("RGB", (width, height), color="#ffffff")
    draw = ImageDraw.Draw(img)

    title_font, ok1 = _load_font(_BOLD_FONTS, 15)
    bold_font, ok2 = _load_font(_BOLD_FONTS, 14)
    value_font, ok3 = _load_font(_REGULAR_FONTS, 13)
    small_font, ok4 = _load_font(_REGULAR_FONTS, 10)
    pin_font, ok5 = _load_font(_BOLD_FONTS, 24)
    head_font, ok6 = _load_font(_BOLD_FONTS, 14)
    sub_font, ok7 = _load_font(_REGULAR_FONTS, 12)
    note_font, ok8 = _load_font(_BOLD_FONTS, 11)
    field_font, ok9 = _load_font(_BOLD_FONTS, 16)
    truetype = all((ok1, ok2, ok3, ok4, ok5, ok6, ok7, ok8, ok9))

    def tr(text: str) -> str:  # TrueType yoksa Türkçe karakterler ASCII'ye indirgenir (kutucuk çıkmasın)
        return text if truetype else text.translate(_TR_TO_ASCII)

    def centered(text: str, center_x: float, y: float, font: Any, fill: str) -> None:
        text = tr(text)
        draw.text((center_x - draw.textlength(text, font=font) / 2, y), text, fill=fill, font=font)

    draw.rectangle([(2, 2), (width - 3, height - 3)], outline="#0f172a", width=3)
    draw.rectangle([(5, 5), (width - 6, 44)], fill="#0f172a")
    draw.text((15, 12), tr("AHBU AKILLI EV & BİNA OTOMASYONU"), fill="#38bdf8", font=title_font)
    draw.text((width - 95, 14), format_serial_badge(record.serial_no), fill="#ffffff", font=bold_font)

    # Karekodlar: tam sayı modül boyutuyla (bulanıklık yok). 1) claim adresi, 2) kurulum Wi-Fi'si.
    left, middle, right = label_columns()
    claim_img = make_qr_image(label_qr_payload(record))
    wifi_payload = label_wifi_qr_payload(record)
    wifi_img = make_qr_image(wifi_payload) if wifi_payload else None
    wifi_size = wifi_img.size if wifi_img is not None else claim_img.size
    (claim_x, claim_y), (wifi_x, wifi_y) = label_qr_positions(claim_img.size, wifi_size)
    img.paste(claim_img, (claim_x, claim_y))
    if wifi_img is not None:
        img.paste(wifi_img, (wifi_x, wifi_y))
    else:  # veri geçersiz: sessizce atlanmaz, etikette görünür uyarı verilir
        draw.rectangle([(wifi_x, wifi_y), (wifi_x + wifi_size[0] - 1, wifi_y + wifi_size[1] - 1)], outline="#dc2626", width=2)
        for index, line in enumerate(textwrap.wrap(tr(LABEL_WIFI_MISSING_NOTE), 24)):
            draw.text((wifi_x + 12, wifi_y + 20 + index * 18), line, fill="#dc2626", font=value_font)

    # Sütun başlıkları (iki satır) ve karekod altı açıklamaları
    for (col_start, col_end), heading in ((left, LABEL_HEADING_CLAIM), (right, LABEL_HEADING_WIFI)):
        center_x = (col_start + col_end) / 2
        head, sub = _split_heading(heading)
        centered(head, center_x, 51, head_font, "#0f172a")
        if sub:
            centered(sub, center_x, 70, sub_font, "#475569")
    qr_bottom = LABEL_QR_TOP + max(claim_img.height, wifi_size[1])
    caption_y = qr_bottom + 5
    centered(LABEL_CAPTION_CLAIM_QR, (left[0] + left[1]) / 2, caption_y, small_font, "#64748b")
    if wifi_img is not None:  # karekod yoksa "okutun" yazısı yanıltıcı olur
        centered(LABEL_CAPTION_WIFI_QR, (right[0] + right[1]) / 2, caption_y, small_font, "#64748b")
    for divider_x in (middle[0], middle[1]):  # iki karekodu net ayıran dikey çizgiler
        draw.line([(divider_x, 52), (divider_x, caption_y + 12)], fill="#cbd5e1", width=1)

    # Okunabilir metinler (orta sütun; yerleşim/punto dışında içerik değişmedi). Çok uzun bir değer (32 karakterlik AP
    # parolası) sütundan taşmasın diye değer yazı tipi gerekirse küçültülür.
    lines = label_text_lines(record)
    value_texts = [tr(value) for caption, value in lines if caption != LABEL_CAPTION_PIN]
    column_room = middle[1] - middle[0] - 20
    field_size = 16
    while field_size > 9 and max(draw.textlength(text, font=field_font) for text in value_texts) > column_room:
        field_size -= 1
        field_font, _ok = _load_font(_BOLD_FONTS, field_size)
    widest = max([190] + [int(draw.textlength(text, font=field_font)) for text in value_texts])
    x_left = middle[0] + max(10, (middle[1] - middle[0] - widest) // 2)
    y = 56
    for caption, value in lines:
        draw.text((x_left, y), tr(caption), fill="#64748b", font=small_font)
        if caption == LABEL_CAPTION_PIN:
            draw.rectangle([(x_left, y + 14), (x_left + 190, y + 50)], outline="#dc2626", fill="#fef2f2", width=1)
            draw.text((x_left + 18, y + 16), value, fill="#dc2626", font=pin_font)
            y += 58
        else:
            draw.text((x_left, y + 14), tr(value), fill="#0f172a", font=value_font if caption == LABEL_CAPTION_MAC else field_font)
            y += 46

    # Güvenlik notu: etiket gizlidir (PIN + kurulum parolası içerir)
    band_top = caption_y + 19
    draw.rectangle([(10, band_top), (width - 11, band_top + 26)], outline="#fca5a5", fill="#fef2f2", width=1)
    draw.text((18, band_top + 6), tr(LABEL_SECURITY_NOTE), fill="#991b1b", font=note_font)

    draw.line([(10, height - 36), (width - 10, height - 36)], fill="#cbd5e1", width=1)
    draw.text((15, height - 28), tr(f"Model: {record.model or DEFAULT_MODEL}"), fill="#64748b", font=small_font)
    draw.text((width - 175, height - 28), tr(f"Kayıt: {_label_date(record.created_at)}"), fill="#64748b", font=small_font)
    return img


# ===========================================================================
# Sunucu giriş diyaloğu
# ===========================================================================
@dataclass
class LoginRequest:
    mode: str  # "password" | "api_key"
    server_url: str
    email: str = ""
    password: str = field(default="", repr=False)
    remember: bool = True  # "Beni hatırla": şifreli oturum anahtarı + kimlik saklansın mı (parola ASLA saklanmaz)


class ServerLoginDialog(tk.Toplevel):
    """Süper kullanıcı e-posta + parola (veya ADMIN_API_KEY ortam değişkeni) soran modal diyalog.

    Parola yalnızca bu diyalogda tutulur; diske/loga yazılmaz. "Beni hatırla" işaretliyse yalnızca ŞİFRELİ oturum anahtarı
    (DPAPI, bu Windows kullanıcısına bağlı) ve kimlik (sunucu adresi + e-posta) saklanır."""

    def __init__(
        self,
        parent: tk.Misc,
        *,
        server_url: str,
        email: str = "",
        api_key_available: bool = False,
        note: str = "",
        remember_default: bool = True,
        can_remember: bool = True,
    ) -> None:
        super().__init__(parent)
        theme = theme_of(parent)  # ana pencerenin teması (koyu/açık) diyalogda da geçerlidir
        self.theme = theme
        self.title("🔐 Sunucu Kimlik Doğrulama")
        self.transient(parent)
        self.resizable(False, False)
        theme.register(self, "root")
        self.configure(padx=16, pady=14)
        self.result: Optional[LoginRequest] = None
        self._parent = parent

        card, body = theme.card(self, "🔐 Süper Kullanıcı Girişi", accent="cyan", padx=16, pady=14)
        card.pack(fill=tk.BOTH, expand=True)
        intro = note or "Cihazı sunucu envanterine kaydetmek için süper kullanıcı hesabıyla giriş yapın."
        theme.label(
            body,
            "label.muted",
            text=intro + "\nParola saklanmaz. 'Beni hatırla' işaretliyse yalnızca şifreli oturum anahtarı saklanır.",
            size=9,
            wraplength=400,
            justify="left",
        ).pack(anchor="w", pady=(2, 10))

        form = theme.frame(body, "frame.surface")
        form.pack(fill=tk.X)
        theme.label(form, "label.field", text="Sunucu adresi:").grid(row=0, column=0, sticky="w", pady=4)
        self.url_entry = theme.entry(form, width=38)
        self.url_entry.insert(0, server_url)
        self.url_entry.grid(row=0, column=1, columnspan=2, sticky="ew", pady=4, padx=(10, 0))

        theme.label(form, "label.field", text="E-posta:").grid(row=1, column=0, sticky="w", pady=4)
        self.email_entry = theme.entry(form, width=38)
        self.email_entry.insert(0, email)
        self.email_entry.grid(row=1, column=1, columnspan=2, sticky="ew", pady=4, padx=(10, 0))

        theme.label(form, "label.field", text="Parola:").grid(row=2, column=0, sticky="w", pady=4)
        self.pwd_entry = theme.entry(form, show="•", width=32)
        self.pwd_entry.grid(row=2, column=1, sticky="ew", pady=4, padx=(10, 0))
        self._show_pwd = False
        self.toggle_btn = theme.button(form, role="ghost", size="sm", text="👁️", width=3, command=self._toggle_pwd)
        self.toggle_btn.grid(row=2, column=2, padx=(6, 0))

        # "Beni hatırla": işaretliyse şifreli oturum anahtarı (DPAPI) + sunucu adresi/e-posta saklanır, bir sonraki açılışta
        # araç sessizce girer. DPAPI yoksa (Windows dışı) kutu pasif: yalnız kimlik hatırlanır, parola ASLA saklanmaz.
        self.remember_var = tk.BooleanVar(value=bool(remember_default and can_remember))
        self.chk_remember = theme.check(
            form,
            text="Beni hatırla (şifreli oturum anahtarı bu bilgisayarda saklanır; ortak bilgisayarda işareti kaldırın)"
            if can_remember
            else "Beni hatırla (bu bilgisayarda kullanılamıyor)",
            variable=self.remember_var,
            size=9,
            state=tk.NORMAL if can_remember else tk.DISABLED,
        )
        self.chk_remember.grid(row=3, column=0, columnspan=3, sticky="w", pady=(8, 0))

        btn_box = theme.frame(body, "frame.surface")
        btn_box.pack(fill=tk.X, pady=(16, 0))
        theme.button(btn_box, role="secondary", size="md", text="İptal", width=10, command=self._on_cancel).pack(side=tk.RIGHT, padx=(8, 0))
        self.btn_ok = theme.button(btn_box, role="primary", size="md", text="✓ Giriş Yap", command=self._on_ok)
        self.btn_ok.pack(side=tk.RIGHT)
        if api_key_available:
            self.btn_api = theme.button(btn_box, role="tint.amber", size="sm", text="ADMIN_API_KEY ile devam", command=self._on_api_key)
            self.btn_api.pack(side=tk.LEFT)

        self.bind("<Return>", lambda _event: self._on_ok())
        self.bind("<Escape>", lambda _event: self._on_cancel())

    @classmethod
    def ask(cls, parent: tk.Misc, **kwargs: Any) -> Optional[LoginRequest]:
        dialog = cls(parent, **kwargs)
        dialog.show_modal()
        return dialog.result

    def show_modal(self) -> None:
        self.update_idletasks()
        try:
            parent = self._parent
            px, py = parent.winfo_rootx(), parent.winfo_rooty()
            pw, ph = parent.winfo_width(), parent.winfo_height()
            w, h = self.winfo_reqwidth(), self.winfo_reqheight()
            self.geometry(f"+{px + max(0, (pw - w) // 2)}+{py + max(0, (ph - h) // 3)}")
        except tk.TclError:
            pass
        (self.email_entry if not self.email_entry.get() else self.pwd_entry).focus_set()
        try:
            self.wait_visibility()  # grab için pencere görünür olmalı
            self.grab_set()
        except tk.TclError:
            pass
        self._parent.wait_window(self)

    def _toggle_pwd(self) -> None:
        self._show_pwd = not self._show_pwd
        self.pwd_entry.config(show="" if self._show_pwd else "•")

    def _read_url(self) -> Optional[str]:
        try:
            return normalize_server_url(self.url_entry.get())
        except ValueError as exc:
            messagebox.showwarning("Sunucu Adresi", str(exc), parent=self)
            return None

    def _on_ok(self) -> None:
        url = self._read_url()
        if url is None:
            return
        email = self.email_entry.get().strip()
        password = self.pwd_entry.get()  # kırpılmaz: boşluk parolanın parçası olabilir
        if not email or not password:
            messagebox.showwarning("Eksik Bilgi", "Lütfen e-posta ve parolayı girin.", parent=self)
            return
        self.result = LoginRequest("password", url, email, password, remember=bool(self.remember_var.get()))
        self.destroy()

    def _on_api_key(self) -> None:
        url = self._read_url()
        if url is None:
            return
        self.result = LoginRequest("api_key", url, remember=False)
        self.destroy()

    def _on_cancel(self) -> None:
        self.result = None
        self.destroy()


# ===========================================================================
# Ana uygulama
# ===========================================================================
class EvOtomasyonServisApp(tk.Tk):
    """Servis ve üretim konsolu.

    Test/QA kancaları: ``transport`` / ``device_transport`` (sahte HTTP), ``serial_backend`` / ``serial_clock``
    (sahte seri port ve saat), ``synchronous=True`` (arka plan işleri aynı iş parçacığında çalışır)."""

    def __init__(
        self,
        *,
        server_url: Optional[str] = None,
        device_host: Optional[str] = None,
        transport: Optional[Callable[..., Any]] = None,
        device_transport: Optional[Callable[..., Any]] = None,
        synchronous: bool = False,
        serial_backend: Optional[Any] = None,
        serial_clock: Optional[Any] = None,
        session_store: Optional[SessionStore] = None,
    ) -> None:
        super().__init__()

        self._synchronous = bool(synchronous)
        self._ui_queue: "queue.Queue[tuple[Callable[..., Any], tuple[Any, ...], dict[str, Any]]]" = queue.Queue()
        self._closing = False
        self._reporting_error = False
        self._callback_errors: list[BaseException] = []
        self._startup_notes: list[str] = []
        self.scrubber = SecretScrubber()

        # "Beni hatırla": kimlik (sunucu adresi + e-posta) açık ayar dosyasından, refresh token DPAPI dosyasından gelir.
        # Sunucu adresi AÇIKÇA verilmemişse ve EV_SERVER_URL tanımlı değilse hatırlanan adres kullanılır.
        self.session_store = session_store if session_store is not None else SessionStore()
        remembered_url, remembered_email = self.session_store.identity()
        if server_url is None and remembered_url and not os.environ.get(ENV_SERVER_URL):
            try:
                server_url = normalize_server_url(remembered_url)
            except ValueError:
                server_url = None
        try:
            self.client = ServerClient(server_url, transport=transport, scrubber=self.scrubber)
        except ValueError as exc:
            self._startup_notes.append(f"Sunucu adresi kullanılamadı ({exc}); varsayılan adres kullanılıyor.")
            self.client = ServerClient(DEFAULT_SERVER_URL, transport=transport, scrubber=self.scrubber)
        try:
            self.device = DeviceClient(device_host, transport=device_transport)
        except ValueError as exc:
            self._startup_notes.append(f"Cihaz adresi kullanılamadı ({exc}); {DEFAULT_DEVICE_HOST} kullanılıyor.")
            self.device = DeviceClient(DEFAULT_DEVICE_HOST, transport=device_transport)

        self.title("AHBU - Ev Otomasyon Sistemi | Servis & Üretim Konsolu")
        self.geometry("1024x860")  # kartlar (rim + iç boşluk) ve 10 punto yazıyla üç sekme de kırpılmadan sığar
        self.minsize(900, 720)

        # Görsel tema ("Neon Glass"): tüm renk belirteçleri ve ttk stili tool_theme.py'dedir; tercih (koyu/açık)
        # ortam değişkeninden ya da kullanıcı ayar dosyasından okunur, anahtarla değiştirilince kaydedilir.
        self.theme = ThemeManager(self, load_theme_preference(), persist=True)
        self.theme.register(self, "root")
        self.is_flashing = False
        self.current_label_img = None
        self.saved_label_path: Optional[str] = None
        self.current_record: Optional[DeviceRecord] = None
        self._esptool_busy = False
        self._prov_busy = False
        self._register_busy = False
        self._login_busy = False
        self._last_email = remembered_email  # "Beni hatırla": giriş penceresi e-postayla ön dolu açılır
        self.keeper = SessionKeeper(self.client, self.session_store)
        self._restoring = False  # açılışta kayıtlı oturumla sessiz giriş sürüyor
        self._after_restore: Optional[Callable[[], None]] = None  # sessiz giriş sürerken istenen işlem (ensure_login)
        self._known_ports: set[str] = set()
        self._clipboard_secret: Optional[str] = None
        self._clipboard_job: Optional[str] = None
        self._pump_job: Optional[str] = None
        self._pin_visible = False
        self._prov_cancel = threading.Event()
        self._prov_mode = ""  # "" | "serial" | "wifi": süren provizyonun yolu
        self._flash_port: Optional[str] = None
        self._serial_backend = serial_backend
        self._serial_backend_error: Optional[str] = None
        self._serial_backend_lock = threading.Lock()
        self._serial_clock = serial_clock

        self.mode_var = tk.StringVar(value="custom")
        self.version_data = load_version_info()

        self._create_main_layout()
        self.refresh_ports()
        self.apply_mode_selection()
        self.update_session_bar()
        self._set_inventory_placeholder("Envanteri görmek için sunucuya giriş yapın ('Sunucuya Giriş' düğmesi).")
        self._refresh_provision_tab()
        for note in self._startup_notes:
            self.log(f"[UYARI] {note}")

        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self._pump_ui_queue()
        self.update_idletasks()  # bekleyen ttk tema olayları pencere yok edilmeden önce işlensin
        if self.session_store.has_token():  # "Beni hatırla": pencere açıldıktan sonra kayıtlı oturumla SESSİZ giriş
            self.after(250, self._startup_restore)

    # =========================================================================
    # Altyapı: arka plan işleri, arayüz kuyruğu, iletişim kutuları
    # =========================================================================
    def post_ui(self, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> None:
        """Herhangi bir iş parçacığından arayüz iş parçacığında ``fn`` çalıştırılmasını ister (Tk'ye yalnızca
        ana iş parçacığı dokunur)."""
        if self._synchronous:
            fn(*args, **kwargs)
        else:
            self._ui_queue.put((fn, args, kwargs))

    def _pump_ui_queue(self) -> None:
        if self._closing:
            return
        try:
            while True:
                fn, args, kwargs = self._ui_queue.get_nowait()
                try:
                    fn(*args, **kwargs)
                except Exception:  # noqa: BLE001 - tek geri çağrı diğerlerini durdurmasın
                    self.report_callback_exception(*sys.exc_info())
        except queue.Empty:
            pass
        try:
            self._pump_job = self.after(50, self._pump_ui_queue)
        except tk.TclError:
            self._pump_job = None

    def run_background(self, work: Callable[[], Any], on_done: Optional[Callable[[Any, Optional[BaseException]], None]] = None) -> None:
        """``work`` arka plan iş parçacığında çalışır; ``on_done(sonuç, hata)`` arayüz iş parçacığında çağrılır."""

        def runner() -> None:
            result: Any = None
            error: Optional[BaseException] = None
            try:
                result = work()
            except BaseException as exc:  # noqa: BLE001 - hata arayüze iletilir
                error = exc
            if on_done is not None:
                self.post_ui(on_done, result, error)

        if self._synchronous:
            runner()
        else:
            threading.Thread(target=runner, name="ev-worker", daemon=True).start()

    def report_callback_exception(self, exc, val, tb) -> None:  # noqa: D102 - Tk kancası
        self._callback_errors.append(val)
        if DEBUG_ENABLED:  # yalnızca sınıf adı: istisna metni gizli değer içerebilir
            sys.stderr.write(f"[HATA-AYIKLAMA] Geri çağrı istisnası: {getattr(exc, '__name__', exc)}\n")
            traceback.print_tb(tb, file=sys.stderr)
        if self._reporting_error:
            return
        self._reporting_error = True
        try:
            self.ui_error(
                "Beklenmeyen Hata",
                f"Beklenmeyen bir hata oluştu ({getattr(exc, '__name__', 'Hata')}).\n"
                "İşlem tamamlanamadı; tekrar deneyin. Sorun sürerse aracı yeniden başlatın.",
            )
        finally:
            self._reporting_error = False

    # Tüm iletişim kutuları buradan geçer (testte tek noktadan değiştirilebilir)
    def _notify(self, show: Callable[..., Any], title: str, text: str) -> None:
        """Bilgi/uyarı/hata kutusu. Gerçek çalışmada kutu ayrı bir Tk olayı olarak açılır: böylece kutu açıkken
        arka plan iş parçacıklarının ilerleme/sonuç güncellemeleri (arayüz kuyruğu) işlenmeye devam eder."""
        if self._synchronous or self._closing:
            show(title, text, parent=self)
        else:
            self.after(0, lambda: show(title, text, parent=self))

    def ui_info(self, title: str, text: str) -> None:
        self._notify(messagebox.showinfo, title, text)

    def ui_warn(self, title: str, text: str) -> None:
        self._notify(messagebox.showwarning, title, text)

    def ui_error(self, title: str, text: str) -> None:
        self._notify(messagebox.showerror, title, text)

    def ui_confirm(self, title: str, text: str) -> bool:
        return bool(messagebox.askyesno(title, text, parent=self))

    def _error_text(self, err: BaseException) -> str:
        if isinstance(err, (FactoryError, ToolError)):
            return str(err)
        if DEBUG_ENABLED:
            sys.stderr.write(f"[HATA-AYIKLAMA] {type(err).__name__}\n")
        return f"Beklenmeyen bir hata oluştu ({type(err).__name__}). İşlemi tekrar deneyin."

    def _handle_error(self, title: str, err: BaseException) -> None:
        if isinstance(err, SessionExpiredError):
            self.update_session_bar()
            self._set_inventory_placeholder("Oturum kapandı. Yeniden giriş yapın.")
            self.ui_warn(title, f"{err}\nYeniden giriş için 'Sunucuya Giriş' düğmesini kullanın.")
        else:
            self.ui_error(title, self._error_text(err))

    # =========================================================================
    # Arayüz iskeleti
    # =========================================================================
    def _create_main_layout(self) -> None:
        theme = self.theme
        # Üst başlık şeridi: marka + alt başlık (sol), firmware sürüm rozeti + tema anahtarı (sağ)
        header_frame = theme.frame(self, "frame.header", padx=16, pady=10)
        header_frame.pack(fill=tk.X)
        title_row = theme.frame(header_frame, "frame.header")
        title_row.pack(fill=tk.X)
        theme.label(title_row, "label.brand", text="🏠 AHBU AKILLI EV SİSTEMLERİ").pack(side=tk.LEFT)
        theme.label(
            title_row,
            "label.header.sub",
            text="Üretim, Firmware Yükleme, Envanter ve Provizyon Konsolu",
            padx=12,
        ).pack(side=tk.LEFT, pady=(4, 0))
        self._theme_dark_var = tk.BooleanVar(value=theme.is_dark)
        self._theme_label_var = tk.StringVar()
        self.theme_switch = ttk.Checkbutton(
            title_row,
            style="Switch.TCheckbutton",
            variable=self._theme_dark_var,
            textvariable=self._theme_label_var,
            command=self._on_theme_switch,
            cursor="hand2",
        )
        self.theme_switch.pack(side=tk.RIGHT, padx=(8, 0))
        self.lbl_fw_version = theme.label(
            title_row, "label.badge", text=f"Firmware v{self.version_data.get('current_version', '1.0.0')}", size=9, weight="bold"
        )
        self.lbl_fw_version.pack(side=tk.RIGHT, padx=(8, 0))
        self._update_theme_switch_text()
        theme.frame(self, "frame.header.line", height=2).pack(fill=tk.X)

        self._build_session_bar()

        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=12, pady=(10, 12))
        try:
            self.notebook.enable_traversal()  # Ctrl+Tab / Ctrl+Shift+Tab ile sekme gezinimi
        except tk.TclError:
            pass

        self.tab_flasher = theme.frame(self.notebook, "frame.bg")
        self.notebook.add(self.tab_flasher, text="⚡ 1. Firmware Yükleyici (Flasher)")
        self.tab_inventory = theme.frame(self.notebook, "frame.bg")
        self.notebook.add(self.tab_inventory, text="🏷️ 2. Karekod Üret & Etiket Bas (Envanter)")
        self.tab_provision = theme.frame(self.notebook, "frame.bg")
        self.notebook.add(self.tab_provision, text="📡 3. Cihaz Provizyonu (USB / Wi-Fi)")

        self._build_flasher_tab()
        self._build_inventory_tab()
        self._build_provision_tab()

    def _update_theme_switch_text(self) -> None:
        self._theme_label_var.set("🌙 Koyu tema" if self.theme.is_dark else "☀️ Açık tema")

    def _on_theme_switch(self) -> None:
        """Tema anahtarı: koyu <-> açık; tercih kullanıcı ayar dosyasına yazılır (gizli bilgi içermez)."""
        self.theme.set_theme(THEME_DARK if self._theme_dark_var.get() else THEME_LIGHT)
        self._update_theme_switch_text()

    def _build_session_bar(self) -> None:
        theme = self.theme
        bar = theme.frame(self, "frame.session", padx=16, pady=7)
        bar.pack(fill=tk.X)
        self.lbl_server = theme.label(bar, "label.session.text", text="", size=9)
        self.lbl_server.pack(side=tk.LEFT)
        self.btn_logout = theme.button(bar, role="header", size="sm", text="🚪 Oturumu Kapat", command=self.logout_clicked, state=tk.DISABLED)
        self.btn_logout.pack(side=tk.RIGHT, padx=(8, 0))
        self.btn_login = theme.button(bar, role="header.primary", size="sm", text="🔐 Sunucuya Giriş", command=self.login_clicked)
        self.btn_login.pack(side=tk.RIGHT)
        self.lbl_session = theme.label(bar, "label.badge.amber", text="", size=9, weight="bold")
        self.lbl_session.pack(side=tk.RIGHT, padx=12)

    def update_session_bar(self) -> None:
        url = self.client.base_url
        custom = url != DEFAULT_SERVER_URL
        self.lbl_server.config(text=f"🌐 Sunucu: {url}" + ("   (özel / QA adresi)" if custom else ""))
        self.theme.restyle(self.lbl_server, "label.session.accent.amber" if custom else "label.session.text", size=9)
        if self.client.is_authenticated:
            who = self.client.user_email or "oturum açık"
            how = "API anahtarı" if self.client.auth_mode == "api_key" else "süper kullanıcı"
            if self.keeper.remembered and self.client.auth_mode == "jwt":
                how += ", hatırlanıyor"  # şifreli oturum anahtarı bu bilgisayarda saklı ('Oturumu Kapat' siler)
            self.lbl_session.config(text=f"👤 {who} ({how})")
            self.theme.restyle(self.lbl_session, "label.badge.emerald", size=9, weight="bold")
            self.btn_login.config(text="🔄 Hesap Değiştir", state=tk.NORMAL)
            self.btn_logout.config(state=tk.NORMAL)
        else:
            self.lbl_session.config(text="👤 Giriş yapılmadı")
            self.theme.restyle(self.lbl_session, "label.badge.amber", size=9, weight="bold")
            self.btn_login.config(text="🔐 Sunucuya Giriş", state=tk.NORMAL)
            self.btn_logout.config(state=tk.DISABLED)

    # =========================================================================
    # SEKME 1: FİRMWARE YÜKLEYİCİ (FLASHER)
    # =========================================================================
    def _build_flasher_tab(self) -> None:
        theme = self.theme
        content_frame = theme.frame(self.tab_flasher, "frame.bg", padx=12, pady=12)
        content_frame.pack(fill=tk.BOTH, expand=True)

        conn_card, conn_frame = theme.card(content_frame, "🔌 Bağlantı ve Çip Ayarları", accent="cyan")
        conn_card.pack(fill=tk.X, pady=(0, 10))

        theme.label(conn_frame, "label.field", text="COM Port:").grid(row=0, column=0, sticky="w", pady=4)
        self.port_combo = ttk.Combobox(conn_frame, width=32, state="readonly")
        self.port_combo.grid(row=0, column=1, padx=(8, 10), pady=4, sticky="w")
        theme.on_change(lambda _tokens: theme.retint_combobox_popdown(self.port_combo))
        theme.button(conn_frame, role="secondary", size="sm", text="🔄 Portları Yenile", command=self.refresh_ports).grid(
            row=0, column=2, padx=5, pady=4
        )

        theme.label(conn_frame, "label.field", text="Hedef Donanım:").grid(row=1, column=0, sticky="w", pady=4)
        theme.label(
            conn_frame,
            "label.chip.sky",
            text="Waveshare ESP32-S3 (8DI-8RO Pano Modülü) | 460.800 bps Yüksek Hız",
            size=9,
        ).grid(row=1, column=1, columnspan=2, sticky="w", padx=(8, 0), pady=4)

        fw_card, fw_frame = theme.card(content_frame, "📦 Yüklenecek Firmware Seçimi", accent="violet")
        fw_card.pack(fill=tk.X, pady=(0, 10))

        r1_frame = theme.frame(fw_frame, "frame.surface")
        r1_frame.pack(fill=tk.X, pady=(2, 4))
        self.r_custom = theme.radio(
            r1_frame,
            text="🚀 Bizim Geliştirdiğimiz Yazılım (Otomatik Seçili)",
            variable=self.mode_var,
            value="custom",
            command=self.apply_mode_selection,
            weight="bold",
            accent="sky",
        )
        self.r_custom.pack(side=tk.LEFT)
        self.inc_ver_btn = theme.button(r1_frame, role="tint.emerald", size="sm", text="➕ Versiyon Arttır", command=self.inc_version)
        self.inc_ver_btn.pack(side=tk.RIGHT, padx=5)
        self.ver_label = theme.label(
            r1_frame, "label.accent.emerald", text=f"Mevcut: v{self.version_data.get('current_version', '1.0.0')}", weight="bold"
        )
        self.ver_label.pack(side=tk.RIGHT, padx=5)

        r2_frame = theme.frame(fw_frame, "frame.surface")
        r2_frame.pack(fill=tk.X, pady=(2, 6))
        self.r_factory = theme.radio(
            r2_frame,
            text="🛡️ Fabrika Çıkış Orijinal Yazılımı (Test / Kurtarma Modu)",
            variable=self.mode_var,
            value="factory",
            command=self.apply_mode_selection,
        )
        self.r_factory.pack(side=tk.LEFT)

        path_frame = theme.frame(fw_frame, "frame.surface")
        path_frame.pack(fill=tk.X, pady=(4, 2))
        theme.label(path_frame, "label.field", text="Dosya:").pack(side=tk.LEFT, padx=(0, 8))
        self.file_entry = theme.entry(path_frame)
        self.file_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 8))
        self.browse_btn = theme.button(path_frame, role="secondary", size="sm", text="📁 Gözat...", command=self.browse_custom_file)
        self.browse_btn.pack(side=tk.RIGHT)

        btn_frame = theme.frame(content_frame, "frame.bg")
        btn_frame.pack(fill=tk.X, pady=(0, 10))
        self.btn_flash = theme.button(btn_frame, role="primary", size="lg", text="⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)", command=self.start_flash)
        self.btn_flash.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 6))
        self.btn_read_info = theme.button(btn_frame, role="secondary", size="md", text="🔍 Çip Bilgisi Oku", command=self.start_read_info)
        self.btn_read_info.pack(side=tk.LEFT, fill=tk.Y, padx=6)
        self.btn_erase = theme.button(btn_frame, role="danger", size="md", text="🗑️ Hafızayı Sil (Erase Flash)", command=self.start_erase)
        self.btn_erase.pack(side=tk.LEFT, fill=tk.Y, padx=(6, 0))

        log_card, log_frame = theme.card(content_frame, "📋 İşlem Log Çıktısı", accent="emerald", padx=10, pady=10)
        log_card.pack(fill=tk.BOTH, expand=True)
        self.log_text = theme.text(log_frame, "text.log", wrap=tk.WORD)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar = theme.scrollbar(log_frame, orient="vertical", command=self.log_text.yview)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.config(yscrollcommand=scrollbar.set)

    # =========================================================================
    # SEKME 2: KAREKOD ÜRET & ETİKET BAS (CİHAZ ENVANTERİ)
    # =========================================================================
    def _build_inventory_tab(self) -> None:
        theme = self.theme
        inv_content = theme.frame(self.tab_inventory, "frame.bg", padx=12, pady=10)
        inv_content.pack(fill=tk.BOTH, expand=True)

        top_split = theme.frame(inv_content, "frame.bg")
        top_split.pack(fill=tk.X, pady=(0, 10))

        form_card, form_frame = theme.card(top_split, "⚙️ Cihaz Tanımlama & Otomatik Kimlik Üretimi", accent="sky")
        form_card.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(0, 6))

        theme.label(form_frame, "label.field", text="1. Donanım MAC:").grid(row=0, column=0, sticky="w", pady=4)
        mac_row = theme.frame(form_frame, "frame.surface")
        mac_row.grid(row=0, column=1, sticky="ew", pady=4)
        self.inv_mac_entry = theme.entry(mac_row, "entry.mono", width=18, weight="bold", accent="sky")
        self.inv_mac_entry.pack(side=tk.LEFT, padx=(0, 6))
        self.btn_read_mac = theme.button(mac_row, role="tint.sky", size="sm", text="📡 Karttan MAC Oku", command=self.read_mac_from_board)
        self.btn_read_mac.pack(side=tk.LEFT)

        theme.label(form_frame, "label.field", text="2. Cihaz Seri No (UID):").grid(row=1, column=0, sticky="w", pady=4)
        uuid_row = theme.frame(form_frame, "frame.surface")
        uuid_row.grid(row=1, column=1, sticky="ew", pady=4)
        self.inv_uuid_entry = theme.entry(uuid_row, "entry.mono", width=18, weight="bold", accent="sky")
        self.inv_uuid_entry.pack(side=tk.LEFT, padx=(0, 6))
        theme.button(uuid_row, role="secondary", size="sm", text="🔄 UID Üret (MAC'ten)", command=self.generate_device_uuid).pack(side=tk.LEFT)

        theme.label(form_frame, "label.field", text="3. Kurulum PIN (6 Hane):").grid(row=2, column=0, sticky="w", pady=4)
        pin_row = theme.frame(form_frame, "frame.surface")
        pin_row.grid(row=2, column=1, sticky="ew", pady=4)
        self.inv_pin_entry = theme.entry(pin_row, "entry.mono", width=9, size=11, weight="bold", accent="rose", show="•")
        self.inv_pin_entry.pack(side=tk.LEFT, padx=(0, 6))
        theme.button(pin_row, role="secondary", size="sm", text="🎲 Rastgele PIN Üret", command=self.generate_random_pin).pack(side=tk.LEFT)
        theme.button(pin_row, role="ghost", size="sm", text="👁️", command=self._toggle_pin_visibility, width=3).pack(side=tk.LEFT, padx=(6, 0))

        theme.label(form_frame, "label.field", text="4. Donanım Modeli:").grid(row=3, column=0, sticky="w", pady=4)
        self.inv_model_entry = theme.entry(form_frame, width=28)
        self.inv_model_entry.insert(0, DEFAULT_MODEL)
        self.inv_model_entry.grid(row=3, column=1, sticky="w", pady=4)

        theme.label(form_frame, "label.field", text="5. Üretim Partisi:").grid(row=4, column=0, sticky="w", pady=4)
        self.inv_batch_entry = theme.entry(form_frame, width=28)
        self.inv_batch_entry.insert(0, datetime.now().strftime("BATCH-%Y-%m"))
        self.inv_batch_entry.grid(row=4, column=1, sticky="w", pady=4)

        theme.label(
            form_frame,
            "label.note.emerald",
            text="🛡️ Aynı MAC veya UID sunucuya 2. kez eklenemez.\nℹ️ PIN ve yerel anahtar yalnızca BİR KEZ gelir: etiketi kaydetmeden/provizyon bitmeden pencereyi kapatmayın.\n⚠ Sıra: kaydet -> firmware yükle -> HEMEN provizyon (kurulum ağı parolasızdır).",
            slant="italic",
            justify="left",
            wraplength=440,
        ).grid(row=5, column=0, columnspan=2, sticky="w", pady=(8, 10))

        self.btn_register_device = theme.button(
            form_frame, role="primary", size="md", text="☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET", command=self.register_device_and_generate_label
        )
        self.btn_register_device.grid(row=6, column=0, columnspan=2, sticky="ew", pady=(2, 0))

        preview_card, preview_frame = theme.card(top_split, "🖨️ Termal Etiket & Karekod Önizleme", accent="cyan")
        preview_card.pack(side=tk.RIGHT, fill=tk.BOTH, expand=False, padx=(6, 0))

        self.label_canvas_img = theme.label(preview_frame, "label.preview", text=LABEL_PLACEHOLDER_TEXT, size=9, width=50, height=12)
        self.label_canvas_img.pack(pady=(0, 10))

        btn_label_row = theme.frame(preview_frame, "frame.surface")
        btn_label_row.pack(fill=tk.X)
        self.btn_save_label = theme.button(
            btn_label_row, role="secondary", size="sm", text="💾 Etiketi Kaydet (PNG)", command=self.save_label_file, state=tk.DISABLED
        )
        self.btn_save_label.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))
        self.btn_print_label = theme.button(
            btn_label_row, role="tint.cyan", size="sm", text="🖨️ Yazdır (Barkod / Termal)", command=self.print_label_file, state=tk.DISABLED
        )
        self.btn_print_label.pack(side=tk.RIGHT, fill=tk.X, expand=True, padx=(4, 0))

        table_card, table_frame = theme.card(
            inv_content, "📊 Sunucu Cihaz Envanteri & Durum Yönetimi (Süper Yönetici)", accent="violet", padx=10, pady=8
        )
        table_card.pack(fill=tk.BOTH, expand=True)

        table_action_row = theme.frame(table_frame, "frame.surface")
        table_action_row.pack(fill=tk.X, pady=(0, 6))
        theme.button(table_action_row, role="secondary", size="sm", text="🔄 Listeyi Yenile", command=self.refresh_inventory_list).pack(
            side=tk.LEFT, padx=(0, 6)
        )
        self.btn_suspend = theme.button(table_action_row, role="tint.amber", size="sm", text="⏸️ Askıya Al (Kilit)", command=self.suspend_selected_device)
        self.btn_suspend.pack(side=tk.LEFT, padx=4)
        self.btn_activate = theme.button(table_action_row, role="tint.emerald", size="sm", text="▶️ Aktif Et (Stok)", command=self.activate_selected_device)
        self.btn_activate.pack(side=tk.LEFT, padx=4)
        self.btn_delete_device = theme.button(table_action_row, role="danger", size="sm", text="🗑️ Envanterden Sil", command=self.delete_selected_device)
        self.btn_delete_device.pack(side=tk.LEFT, padx=4)

        self.inv_status_var = tk.StringVar(value="")
        theme.label(table_frame, "label.status", textvariable=self.inv_status_var, anchor="w", justify="left").pack(fill=tk.X, pady=(0, 6))

        columns = ("serial_no", "device_uuid", "mac_address", "model", "status", "created_at", "claimed_at")
        self.inv_tree = ttk.Treeview(table_frame, columns=columns, show="headings", height=6, selectmode="browse")
        headings = {
            "serial_no": ("Sıra No", 65, "center"),
            "device_uuid": ("Cihaz UUID (Seri No)", 170, "w"),
            "mac_address": ("MAC Adresi", 140, "center"),
            "model": ("Model", 180, "w"),
            "status": ("Durum", 95, "center"),
            "created_at": ("Kayıt Tarihi", 130, "center"),
            "claimed_at": ("Daire Eşleme Tarihi", 130, "center"),
        }
        for key, (text, width, anchor) in headings.items():
            self.inv_tree.heading(key, text=text)
            self.inv_tree.column(key, width=width, anchor=anchor)
        tree_scroll = theme.scrollbar(table_frame, orient="vertical", command=self.inv_tree.yview)
        self.inv_tree.configure(yscrollcommand=tree_scroll.set)
        self.inv_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        tree_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self._apply_tree_tags()
        theme.on_change(lambda _tokens: self._apply_tree_tags())

        self.generate_random_pin()

    def _apply_tree_tags(self) -> None:
        """Envanter satır durum renkleri (tema belirteçlerinden; tema değişince yeniden uygulanır)."""
        for status, color in self.theme.tree_status_colors().items():
            self.inv_tree.tag_configure(status, foreground=color)

    # =========================================================================
    # SEKME 3: CİHAZ PROVİZYONU
    # =========================================================================
    def _build_provision_tab(self) -> None:
        theme = self.theme
        outer = theme.frame(self.tab_provision, "frame.bg", padx=12, pady=10)
        outer.pack(fill=tk.BOTH, expand=True)

        info_card, info = theme.card(outer, "📟 Provizyon Bekleyen Cihaz", accent="cyan", pady=8)
        info_card.pack(fill=tk.X, pady=(0, 8))
        self.prov_device_var = tk.StringVar(value="")
        theme.label(info, "label.field", textvariable=self.prov_device_var, justify="left", anchor="w").pack(fill=tk.X)

        steps_card, steps = theme.card(outer, "🧭 Adım Adım", accent="violet", pady=8)
        steps_card.pack(fill=tk.X, pady=(0, 8))
        self.prov_warn_var = tk.StringVar(value="")
        theme.label(
            steps, "label.panel.rose", textvariable=self.prov_warn_var, size=9, weight="bold", justify="left", anchor="w", wraplength=880
        ).pack(fill=tk.X, pady=(0, 6))
        self.prov_steps_var = tk.StringVar(value="")
        theme.label(steps, "label.body", textvariable=self.prov_steps_var, size=9, justify="left", anchor="w", wraplength=920).pack(fill=tk.X)

        secrets_card, secrets_frame = theme.card(outer, "🔐 Gizli Bilgiler (yalnızca bellekte; diske yazılmaz)", accent="rose", pady=6)
        secrets_card.pack(fill=tk.X, pady=(0, 8))
        self.prov_key_var = tk.StringVar(value="")
        self.prov_ap_var = tk.StringVar(value="")
        self._prov_secret_entries: list[tk.Entry] = []
        for row, (label, var, command, btn_text) in enumerate(
            (
                ("Yerel anahtar:", self.prov_key_var, self.copy_local_key, "📋 Anahtarı kopyala"),
                ("AP parolası:", self.prov_ap_var, self.copy_ap_pass, "📋 AP parolasını kopyala"),
            )
        ):
            theme.label(secrets_frame, "label.field", text=label).grid(row=row, column=0, sticky="w", pady=2)
            entry = theme.entry(secrets_frame, "entry.mono", textvariable=var, show="•", state="readonly", width=34)
            entry.grid(row=row, column=1, padx=8, pady=2, sticky="w")
            self._prov_secret_entries.append(entry)
            theme.button(secrets_frame, role="secondary", size="sm", text=btn_text, command=command).grid(row=row, column=2, padx=4)
        self._prov_show_secrets = tk.BooleanVar(value=False)
        theme.check(
            secrets_frame,
            text="Değerleri göster",
            variable=self._prov_show_secrets,
            command=self._toggle_prov_secret_visibility,
            size=9,
        ).grid(row=0, column=3, rowspan=2, padx=12)

        buttons = theme.frame(outer, "frame.bg")
        buttons.pack(fill=tk.X, pady=(0, 4))
        self.btn_prov_serial = theme.button(
            buttons, role="primary", size="md", text="🔌 Seri (USB) ile Provizyonla (Önerilen)", command=self.start_serial_provision
        )
        self.btn_prov_serial.pack(side=tk.LEFT, padx=(0, 6))
        self.btn_prov_cancel = theme.button(buttons, role="secondary", size="md", text="⏹ Beklemeyi İptal Et", command=self.cancel_provision, state=tk.DISABLED)
        self.btn_prov_cancel.pack(side=tk.LEFT, padx=6)
        self.btn_prov_manual = theme.button(buttons, role="secondary", size="md", text="📖 Elle Provizyon Talimatı", command=self.show_manual_provision_help)
        self.btn_prov_manual.pack(side=tk.LEFT, padx=6)
        self.btn_prov_forget = theme.button(buttons, role="danger", size="md", text="🧹 Kaydı Bellekten Sil / Yeni Cihaz", command=self.forget_record)
        self.btn_prov_forget.pack(side=tk.RIGHT)

        fallback = theme.frame(outer, "frame.bg")
        fallback.pack(fill=tk.X, pady=(0, 8))
        theme.label(fallback, "label.accent_bg.amber", text="Yedek (güvensiz) yol:", weight="bold").pack(side=tk.LEFT, padx=(0, 8))
        self.btn_prov_start = theme.button(
            fallback, role="tint.amber", size="sm", text="📶 Wi-Fi ile Provizyonla (güvensiz yedek yol)", command=self.provision_via_wifi_clicked
        )
        self.btn_prov_start.pack(side=tk.LEFT, padx=(0, 6))
        self.btn_prov_verify = theme.button(fallback, role="tint.emerald", size="sm", text="✅ Wi-Fi ile Doğrula", command=self.verify_provision)
        self.btn_prov_verify.pack(side=tk.LEFT, padx=6)

        result_card, result_frame = theme.card(outer, "📋 Sonuç", accent="emerald", padx=10, pady=10)
        result_card.pack(fill=tk.BOTH, expand=True)
        self.prov_log = theme.text(result_frame, "text.log", wrap=tk.WORD, height=6, state=tk.DISABLED)
        self.prov_log.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        prov_scroll = theme.scrollbar(result_frame, orient="vertical", command=self.prov_log.yview)
        prov_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.prov_log.config(yscrollcommand=prov_scroll.set)

    def _toggle_prov_secret_visibility(self) -> None:
        show = "" if self._prov_show_secrets.get() else "•"
        for entry in self._prov_secret_entries:
            entry.config(show=show)

    def _prov_say(self, text: str) -> None:
        """Provizyon sonuç alanına (gizli değer içermeyen) satır ekler."""
        line = self.scrubber.scrub(text) + "\n"
        tag = log_line_tag(line)  # yalnızca renk etiketi; metin aynen yazılır
        self.prov_log.config(state=tk.NORMAL)
        if tag:
            self.prov_log.insert(tk.END, line, tag)
        else:
            self.prov_log.insert(tk.END, line)
        self.prov_log.see(tk.END)
        self.prov_log.config(state=tk.DISABLED)

    def _prov_clear_log(self) -> None:
        self.prov_log.config(state=tk.NORMAL)
        self.prov_log.delete("1.0", tk.END)
        self.prov_log.config(state=tk.DISABLED)

    def _alive_record(self) -> Optional[DeviceRecord]:
        rec = self.current_record
        return rec if rec is not None and rec.state != "wiped" else None

    def _refresh_provision_tab(self) -> None:
        rec = self._alive_record()
        if rec is None:
            self.prov_device_var.set("Henüz kayıtlı cihaz yok. Önce 2. sekmede cihazı sunucu envanterine kaydedin.")
            self.prov_warn_var.set(provision_urgency_notice())
            self.prov_steps_var.set(
                "Akış: (1) 2. sekmede cihazı kaydedin ve etiketi alın -> (2) 1. sekmeden firmware'i yükleyin "
                "(yükleme bitince provizyon USB (seri) üzerinden OTOMATİK başlar) -> (3) 'Provizyon doğrulandı' görünce "
                "etiketi cihaza yapıştırın."
            )
            self.prov_key_var.set("")
            self.prov_ap_var.set("")
        else:
            ssid = rec.ap_ssid or "AHBU-XXXXXX"
            state_text = {
                "registered": "Provizyon bekliyor",
                "init_sent": "Anahtar yazıldı (Wi-Fi) - doğrulama bekliyor",
                "verified": "Provizyon doğrulandı ✔" + {"serial": " (USB seri)", "wifi": " (Wi-Fi)"}.get(rec.path, ""),
            }.get(rec.state, rec.state)
            self.prov_device_var.set(
                f"Cihaz: {rec.uid}     MAC: {rec.mac}\n"
                f"Kurulum Wi-Fi ağı (SSID): {ssid}     Yedek Wi-Fi adresi: {self.device.base_url}     Durum: {state_text}"
            )
            self.prov_warn_var.set(provision_urgency_notice(ssid) if not rec.provisioned else "")
            self.prov_steps_var.set(
                "ÖNERİLEN YOL - USB (seri): yerel anahtar kablosuz ağdan GEÇMEZ.\n"
                "1) Kartı, firmware'i yüklediğiniz USB kablosuyla bağlı tutun ve 1. sekmedeki COM Port'un doğru olduğundan emin olun.\n"
                "2) Firmware yüklemesi bitince araç provizyonu OTOMATİK başlatır: kartın açılmasını bekler, STATUS ile kartı (MAC) "
                "ve provizyonsuz olduğunu denetler, FACTORYINIT ile anahtarı yazar, STATUS ile doğrular. Wi-Fi'ye bağlanmanız "
                "GEREKMEZ. Kendiniz başlatmak için 'Seri (USB) ile Provizyonla'ya basın.\n"
                "3) 'Provizyon doğrulandı' görünce (önerilir) telefon kamerasıyla etiketteki 2. karekodu okutup kurulum ağına "
                "bağlanabildiğinizi deneyin (ağ provizyondan sonra yaklaşık 10 dk açıktır); sonra etiketi cihaza yapıştırın "
                "(etiket 2. sekmede kaydedilir/yazdırılır).\n"
                "YEDEK (GÜVENSİZ) YOL - Wi-Fi: yalnızca USB seri kullanılamıyorsa. Anahtar açık kurulum ağından DÜZ HTTP ile gider. "
                f"Bilgisayarı '{ssid}' ağına bağlayıp 'Wi-Fi ile Provizyonla'ya basın; kart ağı parolalı (WPA2) yapınca etiketteki "
                "AP PAROLASI ile yeniden bağlanıp 'Wi-Fi ile Doğrula'ya basın. Kart daha önce başka bir Wi-Fi'ye kaydedildiyse "
                "ağ hemen açılmaz: önce 'Hafızayı Sil', sonra firmware yükleyin; ağ görünmüyorsa seri terminalde (115200 baud) AP ON yazın."
            )
            self.prov_key_var.set(rec.local_key)
            self.prov_ap_var.set(rec.ap_pass)
        self._update_provision_buttons()

    def _update_provision_buttons(self) -> None:
        rec = self._alive_record()
        busy = self._prov_busy
        can_serial = rec is not None and rec.state in ("registered", "init_sent") and not busy and not self._esptool_busy
        can_wifi = rec is not None and rec.state == "registered" and not busy
        can_verify = rec is not None and rec.state in ("registered", "init_sent") and not busy
        self.btn_prov_serial.config(state=tk.NORMAL if can_serial else tk.DISABLED)
        self.btn_prov_start.config(state=tk.NORMAL if can_wifi else tk.DISABLED)
        self.btn_prov_verify.config(state=tk.NORMAL if can_verify else tk.DISABLED)
        self.btn_prov_cancel.config(state=tk.NORMAL if busy else tk.DISABLED)
        self.btn_prov_manual.config(state=tk.NORMAL)
        self.btn_prov_forget.config(state=tk.NORMAL if (rec is not None and not busy) else tk.DISABLED)

    # ---- Seri (USB) provizyon: TERCİH EDİLEN YOL (CONTRACTS §3c) --------------------------------------------
    def _get_serial_backend(self) -> Any:
        """Seri port arka ucunu bulur: aracın kendi pyserial'ı, yoksa PlatformIO penv'deki pyserial (röle).
        Hiçbiri yoksa ``SerialUnavailableError`` (yeni paket KURULMAZ). Arka plan iş parçacığından da çağrılabilir."""
        with self._serial_backend_lock:
            if self._serial_backend is None:
                if self._serial_backend_error:
                    raise SerialUnavailableError(self._serial_backend_error)
                try:
                    self._serial_backend = select_serial_backend(platformio_python_candidates(_platformio_core_dirs()))
                except SerialUnavailableError as exc:
                    self._serial_backend_error = str(exc)
                    raise
            return self._serial_backend

    def _make_serial_provisioner(self) -> SerialProvisioner:
        backend = self._get_serial_backend()
        clock = self._serial_clock
        if clock is not None:  # test/QA: sahte saat
            return SerialProvisioner(backend, clock=clock.now, sleep=clock.sleep)
        return SerialProvisioner(backend)

    def start_serial_provision(
        self,
        *,
        port: Optional[str] = None,
        wait_for_port: bool = False,
        reset_existing: bool = False,
        auto: bool = False,
    ) -> None:
        """USB-seri provizyon: kartın açılmasını bekler, STATUS ile kartı/durumu denetler, ``FACTORYINIT`` ile yerel
        anahtarı + AP parolasını yazar, ``STATUS`` ile doğrular. Anahtar kablosuz ağdan veya düz HTTP'den geçmez.

        ``wait_for_port``: flash sonrası (kart yeniden başlar) portun yeniden görünmesini bekler."""
        rec = self._alive_record()
        if rec is None:
            self.ui_warn("Kayıt Yok", "Önce 2. sekmede cihazı sunucu envanterine kaydedin.")
            return
        if self._prov_busy:
            return
        if self._esptool_busy:
            self.ui_info("Meşgul", "Kartla (flash/MAC okuma) başka bir işlem sürüyor. Bitmesini bekleyin.")
            return
        if rec.state not in ("registered", "init_sent"):
            self.ui_info("Provizyon", "Bu cihazın provizyonu zaten doğrulandı.")
            return
        chosen = port or self._selected_port_or_warn()
        if not chosen:
            return
        self._prov_busy = True
        self._prov_mode = "serial"
        self._prov_cancel = cancel = threading.Event()
        self.set_ui_state(False)  # seri port tek işleme açık: flash/MAC düğmeleri kilitlenir
        self._prov_clear_log()
        self._prov_say(f"USB (seri) provizyon başlıyor ({chosen}, {SERIAL_BAUD} baud)...")
        local_key, ap_pass, mac = rec.local_key, rec.ap_pass, rec.mac

        def work() -> Any:
            return self._make_serial_provisioner().provision(
                chosen,
                local_key,
                ap_pass,
                expected_mac=mac,
                reset_existing=reset_existing,
                wait_for_port=wait_for_port,
                progress=lambda message: self.post_ui(self._prov_say, message),
                cancel=cancel,
            )

        self.run_background(work, lambda outcome, err: self._on_serial_provision_done(rec, outcome, err, port=chosen, auto=auto))

    # USB seri yolu kullanılamıyorsa (kablo/sürücü/pyserial/yanıt) yedek Wi-Fi yolu önerilebilir; diğer hatalar (yanlış kart,
    # anahtar reddi, yazma hatası...) yedekle çözülmez.
    _SERIAL_FALLBACK_CODES = frozenset({"serial_unavailable", "port_not_found", "port_busy", "port_io", "serial_error", "no_response"})

    def _on_serial_provision_done(
        self, rec: DeviceRecord, outcome: Any, err: Optional[BaseException], *, port: str, auto: bool
    ) -> None:
        self._prov_busy = False
        self._prov_mode = ""
        self.set_ui_state(True)
        if rec.state == "wiped":  # kayıt işlem sürerken bellekten silindi: sonuç yok sayılır
            self._refresh_provision_tab()
            return
        if isinstance(err, SerialUnavailableError):
            err = ProvisionError(
                "serial_unavailable",
                "USB (seri) provizyon bu bilgisayarda kullanılamıyor.",
                hint=str(err),
            )
        if err is None:
            rec.state = "verified"
            rec.path = "serial"
            self._prov_say("✅ USB (seri) provizyon tamamlandı ve doğrulandı (STATUS: yerel anahtar tanımlı). Anahtar kablosuz ağdan geçmedi.")
            self.ui_info(
                "Provizyon Tamamlandı",
                "Cihaz USB (seri) üzerinden provizyonlandı ve STATUS ile doğrulandı.\n" + LABEL_PHONE_CHECK_HINT
                + "\nSonra etiketi cihaza yapıştırabilirsiniz.",
            )
        elif isinstance(err, ProvisionError) and err.code == "cancelled":
            self._prov_say("İşlem iptal edildi. Hazır olunca 'Seri (USB) ile Provizyonla'ya basın.")
        elif isinstance(err, ProvisionError):
            text = provision_error_text(err, rec.ap_ssid)
            self._prov_say("❌ " + text)
            if err.code == "already_provisioned" and getattr(err, "can_reset", False):
                if self.ui_confirm(
                    "Kartta Eski Anahtar Var",
                    "Kartta zaten bir yerel anahtar var (daha önce provizyonlanmış).\n\n"
                    "Anahtarı SIFIRLAYIP (RESETKEY) bu kayıttaki anahtarla yeniden provizyon yapılsın mı?\n"
                    "UYARI: Karttaki eski anahtar KULLANILAMAZ hale gelir; kart daha önce bir daireye/bulut hesabına "
                    "bağlandıysa bağlantısı kopar. Fabrikada yeni yazılan kartlar için güvenlidir.",
                ):
                    self._refresh_provision_tab()
                    self.start_serial_provision(port=port, reset_existing=True, auto=auto)
                    return
            elif err.code in self._SERIAL_FALLBACK_CODES:
                self._refresh_provision_tab()
                self._offer_wifi_fallback(rec, text, auto=auto)
                return
            else:
                self.ui_error("USB (Seri) Provizyon Başarısız", text)
        else:
            self._prov_say("❌ USB (seri) provizyon sırasında beklenmeyen bir hata oluştu.")
            self.ui_error("USB (Seri) Provizyon Başarısız", self._error_text(err))
        self._refresh_provision_tab()

    def _offer_wifi_fallback(self, rec: DeviceRecord, reason: str, *, auto: bool) -> None:
        """USB seri kullanılamadığında, kullanıcı onayıyla GÜVENSİZ yedek Wi-Fi yolunu başlatır."""
        if self.ui_confirm(
            "USB (Seri) Provizyon Yapılamadı - Yedek Yol?",
            f"{reason}\n\n"
            "YEDEK (GÜVENSİZ) YOL: Wi-Fi ile provizyon. Yerel anahtar ve AP parolası AÇIK kurulum ağından DÜZ HTTP ile gider; "
            "menzildeki biri dinleyebilir veya kartı sahiplenebilir. Yalnızca kontrollü ortamda kullanın.\n\n"
            "Yedek yolla devam edilsin mi?",
        ):
            self.start_provision(wait_seconds=PROVISION_WAIT_AFTER_FLASH_S if auto else None)
        else:
            self._prov_say("Yedek Wi-Fi yolu seçilmedi. USB bağlantısını düzeltip 'Seri (USB) ile Provizyonla'ya tekrar basın.")
            self.ui_error("USB (Seri) Provizyon Başarısız", reason)

    def provision_via_wifi_clicked(self) -> None:
        """'Wi-Fi ile Provizyonla (güvensiz yedek yol)' düğmesi: önce riski açıkça söyler."""
        if self._alive_record() is None:
            self.start_provision()  # kayıt yok uyarısını verir
            return
        if self.ui_confirm(
            "Güvensiz Yedek Yol",
            "Wi-Fi ile provizyon, yerel anahtarı ve AP parolasını AÇIK (parolasız) kurulum ağından DÜZ HTTP ile gönderir; "
            "menzildeki biri dinleyebilir veya kartı sahiplenebilir.\n\n"
            "Önerilen yol USB (seri) provizyondur. Yalnızca USB seri kullanılamıyorsa ve kontrollü ortamda devam edin.\n\n"
            "Wi-Fi yoluyla devam edilsin mi?",
        ):
            self.start_provision()

    # ---- Wi-Fi (açık AP + düz HTTP) provizyonu: GÜVENSİZ YEDEK YOL -----------------------------------------
    def start_provision(self, wait_seconds: Optional[float] = None) -> None:
        """YEDEK (güvensiz) yol: cihazın açık kurulum AP'sine bağlı bilgisayardan POST /api/factory/init.

        ``wait_seconds``: cihaz ulaşılabilir olana kadar beklenecek süre (flash sonrası otomatik başlatmada uzun)."""
        rec = self._alive_record()
        if rec is None:
            self.ui_warn("Kayıt Yok", "Önce 2. sekmede cihazı sunucu envanterine kaydedin.")
            return
        if self._prov_busy:
            return
        if rec.state != "registered":
            self.ui_info("Provizyon", "Bu cihazın anahtarı zaten yazıldı. 'Wi-Fi ile Doğrula'ya basın.")
            return
        wait = PROVISION_WAIT_MANUAL_S if wait_seconds is None else float(wait_seconds)
        self._prov_busy = True
        self._prov_mode = "wifi"
        self._prov_cancel = cancel = threading.Event()
        self._update_provision_buttons()
        self._prov_clear_log()
        self._prov_say(f"YEDEK (güvensiz) Wi-Fi yolu: cihaza bağlanılıyor ({self.device.base_url})...")
        local_key, ap_pass, uid = rec.local_key, rec.ap_pass, rec.uid

        def work() -> Any:
            return self.device.provision(
                local_key,
                ap_pass,
                expected_uid=uid,
                progress=lambda message: self.post_ui(self._prov_say, message),
                wait_seconds=wait,
                cancel=cancel,
            )

        self.run_background(work, lambda outcome, err: self._on_provision_done(rec, outcome, err))

    def cancel_provision(self) -> None:
        """Süren provizyon beklemesini/doğrulamasını keser."""
        if self._prov_busy:
            self._prov_cancel.set()
            self._prov_say("İptal isteniyor...")

    def _on_provision_done(self, rec: DeviceRecord, outcome: Any, err: Optional[BaseException]) -> None:
        self._prov_busy = False
        self._prov_mode = ""
        if rec.state == "wiped":  # kayıt işlem sürerken bellekten silindi: sonuç yok sayılır
            self._refresh_provision_tab()
            return
        ssid = rec.ap_ssid
        if isinstance(err, ProvisionError) and err.code == "cancelled":
            self._prov_say("İşlem iptal edildi. Hazır olunca 'Seri (USB) ile Provizyonla'ya (veya yedek Wi-Fi yoluna) basın.")
        elif err is not None:
            if isinstance(err, ProvisionError):
                text = provision_error_text(err, ssid)
                self._prov_say("❌ " + text)
                self.ui_error("Provizyon Başarısız", text + "\n\nİsterseniz 'Elle Provizyon Talimatı' düğmesine bakın.")
            else:
                self._prov_say("❌ Provizyon sırasında beklenmeyen bir hata oluştu.")
                self.ui_error("Provizyon Başarısız", self._error_text(err))
        elif outcome.verified:
            rec.state = "verified"
            rec.path = "wifi"
            self._prov_say("✅ Provizyon tamamlandı ve doğrulandı (GET /api/auth/check = 200).")
            self.ui_info("Provizyon Tamamlandı", "Cihaz anahtarı doğrulandı.\n" + LABEL_PHONE_CHECK_HINT + "\nSonra etiketi cihaza yapıştırabilirsiniz.")
        else:
            rec.state = "init_sent"
            text = (
                "Cihaz anahtarı yazıldı. Kart kurulum ağını parolalı (WPA2) olarak yeniden başlattı ve bağlantınız koptu.\n"
                f"Bilgisayarın Wi-Fi'sini '{ssid}' ağına etiketteki AP PAROLASI ile yeniden bağlayın, ardından 'Wi-Fi ile Doğrula'ya basın."
            )
            self._prov_say("✅ " + text)
            self.ui_info("Anahtar Yazıldı - Doğrulama Gerekli", text)
        self._refresh_provision_tab()

    def verify_provision(self) -> None:
        """GET /api/auth/check (X-Device-Key) ile anahtarın cihazda geçerli olduğunu doğrular (Wi-Fi yolu)."""
        rec = self._alive_record()
        if rec is None:
            self.ui_warn("Kayıt Yok", "Önce 2. sekmede cihazı sunucu envanterine kaydedin.")
            return
        if self._prov_busy:
            return
        self._prov_busy = True
        self._prov_mode = "wifi"
        self._prov_cancel = cancel = threading.Event()
        self._update_provision_buttons()
        self._prov_say(f"Doğrulanıyor ({self.device.base_url}/api/auth/check)...")
        local_key = rec.local_key

        def work() -> Any:
            return self.device.verify(
                local_key, attempts=6, delay=2.0, progress=lambda message: self.post_ui(self._prov_say, message), cancel=cancel
            )

        self.run_background(work, lambda ok, err: self._on_verify_done(rec, ok, err))

    def _on_verify_done(self, rec: DeviceRecord, ok: Any, err: Optional[BaseException]) -> None:
        self._prov_busy = False
        self._prov_mode = ""
        if rec.state == "wiped":
            self._refresh_provision_tab()
            return
        if err is None and ok:
            rec.state = "verified"
            rec.path = "wifi"
            self._prov_say("✅ Doğrulama başarılı: cihaz bu kayıttaki yerel anahtarı kabul ediyor.")
            self.ui_info("Doğrulandı", "Cihaz anahtarı doğrulandı.\n" + LABEL_PHONE_CHECK_HINT + "\nSonra etiketi cihaza yapıştırabilirsiniz.")
        elif isinstance(err, ProvisionError) and err.code == "cancelled":
            self._prov_say("Doğrulama iptal edildi.")
        elif isinstance(err, ProvisionError):
            if err.code == "not_provisioned" and rec.state == "init_sent":
                rec.state = "registered"  # anahtar kalıcı yazılmamış: yeniden başlatılabilir
            text = provision_error_text(err, rec.ap_ssid)
            self._prov_say("❌ " + text)
            self.ui_error("Doğrulama Başarısız", text)
        elif err is not None:
            self._prov_say("❌ Doğrulama sırasında beklenmeyen bir hata oluştu.")
            self.ui_error("Doğrulama Başarısız", self._error_text(err))
        self._refresh_provision_tab()

    def show_manual_provision_help(self) -> None:
        rec = self._alive_record()
        text = manual_provision_instructions(rec.ap_ssid if rec else None)
        self._prov_say(text)
        self.ui_info("Elle Provizyon Talimatı", text)

    def copy_local_key(self) -> None:
        rec = self._alive_record()
        if rec is not None:
            self._copy_secret(rec.local_key, "Yerel anahtar")

    def copy_ap_pass(self) -> None:
        rec = self._alive_record()
        if rec is not None:
            self._copy_secret(rec.ap_pass, "AP parolası")

    def _copy_secret(self, value: str, label: str) -> None:
        if not value:
            return
        self.clipboard_clear()
        self.clipboard_append(value)
        self._clipboard_secret = value
        self._prov_say(f"{label} panoya kopyalandı (45 sn sonra panodan silinecek).")
        if self._clipboard_job:
            try:
                self.after_cancel(self._clipboard_job)
            except tk.TclError:
                pass
        self._clipboard_job = self.after(45_000, lambda v=value: self._clear_clipboard_if(v))

    def _clear_clipboard_if(self, value: str) -> None:
        try:
            if self.clipboard_get() == value:
                self.clipboard_clear()
        except tk.TclError:
            pass
        if self._clipboard_secret == value:
            self._clipboard_secret = None

    def forget_record(self) -> None:
        """Bellekteki cihaz kaydını (PIN/anahtar/AP parolası/etiket) siler."""
        rec = self._alive_record()
        if rec is None or self._prov_busy:  # provizyon sürerken önce 'Beklemeyi İptal Et'
            return
        if not rec.provisioned and not self.ui_confirm(
            "Kaydı Sil",
            f"{rec.uid} cihazının provizyonu tamamlanmadı.\nBellekten silerseniz yerel anahtar ve PIN bir daha GÖSTERİLEMEZ.\n\nYine de silinsin mi?",
        ):
            return
        self._discard_record()
        self._prov_clear_log()

    def _discard_record(self) -> None:
        """Kaydı, etiket görselini ve ilgili gizli değerleri bellekten siler; arayüzü sıfırlar."""
        rec = self.current_record
        if rec is not None:
            self.scrubber.discard(*rec.secret_values())
            rec.wipe()
        self.current_record = None
        self.current_label_img = None
        self.saved_label_path = None
        self.label_canvas_img.config(image="", text=LABEL_PLACEHOLDER_TEXT, width=50, height=12)
        self.label_canvas_img.image = None
        self.btn_save_label.config(state=tk.DISABLED)
        self.btn_print_label.config(state=tk.DISABLED)
        self._refresh_provision_tab()

    # =========================================================================
    # Sunucu oturumu
    # =========================================================================
    def login_clicked(self) -> None:
        self.open_login_dialog()

    def logout_clicked(self) -> None:
        """Yerel oturumu hemen siler; sunucudaki oturum ailesini arka planda iptal eder. Hatırlanan oturum (şifreli
        token + kimlik) da silinir: ortak bilgisayarda 'Oturumu Kapat' hiçbir iz bırakmaz."""
        was_remembered = self.keeper.remembered
        self.keeper.forget()
        refresh = self.client.end_session_local()
        self._last_email = ""
        self.update_session_bar()
        self._set_inventory_placeholder("Oturum kapatıldı. Envanteri görmek için yeniden giriş yapın.")
        if was_remembered:
            self.log("[BİLGİ] Hatırlanan oturum bu bilgisayardan silindi.")
        if refresh:
            self.run_background(lambda: self.client.revoke_refresh_token(refresh), None)

    def ensure_login(self, on_ready: Callable[[], None], note: str = "") -> None:
        if self.client.is_authenticated:
            on_ready()
        elif self._restoring:
            self._after_restore = on_ready  # kayıtlı oturumla sessiz giriş sürüyor: bitince işlem devam eder
        else:
            self.open_login_dialog(on_success=on_ready, note=note)

    def _startup_restore(self) -> None:
        """Açılışta kayıtlı oturumla SESSİZ giriş (parola sorulmaz). Başarısızlıkta giriş penceresine düşülmez; araç
        eskisi gibi 'Sunucuya Giriş' bekler. Ağ/sunucu hatasında kayıt silinmez (bir sonraki açılışta yeniden denenir)."""
        if self._closing or self._restoring or self.client.is_authenticated or not self.session_store.has_token():
            return
        self._restoring = True
        self._login_busy = True
        self.btn_login.config(state=tk.DISABLED, text="⏳ Kayıtlı oturum açılıyor...")

        def done(result: Any, err: Optional[BaseException]) -> None:
            self._restoring = False
            self._login_busy = False
            pending, self._after_restore = self._after_restore, None
            outcome, email = (RESTORE_NETWORK, "") if (err is not None or not result) else result
            if outcome == RESTORE_OK:
                self._last_email = email or self._last_email
                self.log("[BAŞARILI] Kayıtlı oturum sessizce açıldı. 'Oturumu Kapat' hatırlanan oturumu siler.")
                self._after_login(pending)
                return
            if outcome in (RESTORE_EXPIRED, RESTORE_FORBIDDEN):
                self.log("[UYARI] Kayıtlı oturum artık geçerli değil; kayıt silindi. Yeniden giriş yapın.")
            elif outcome == RESTORE_MISMATCH:
                self.log("[UYARI] Kayıtlı oturum başka bir sunucu adresine ait; bu adres için giriş yapın.")
            elif outcome == RESTORE_NETWORK:
                self.log("[UYARI] Kayıtlı oturum şimdi denetlenemedi (ağ/sunucu); kayıt korundu, gerektiğinde yeniden denenir.")
            self.update_session_bar()
            if pending is not None:  # sessiz giriş sürerken istenen işlem: şimdi normal giriş penceresi
                self.open_login_dialog(on_success=pending)

        self.run_background(self.keeper.try_restore, done)

    def open_login_dialog(self, on_success: Optional[Callable[[], None]] = None, note: str = "") -> None:
        if self._login_busy:
            return
        request = ServerLoginDialog.ask(
            self,
            server_url=self.client.base_url,
            email=self._last_email,
            api_key_available=self.client.api_key_available(),
            note=note,
            remember_default=True,
            can_remember=self.session_store.can_store_token,
        )
        if request is None:
            return
        try:
            changed = self.client.set_base_url(request.server_url)
        except ValueError as exc:
            self.ui_warn("Sunucu Adresi", str(exc))
            return
        if changed:
            self._set_inventory_placeholder("Sunucu adresi değişti; yeniden giriş yapın.")
        if request.mode == "api_key":
            try:
                self.client.use_api_key()
            except FactoryError as exc:
                self.ui_error("API Anahtarı", str(exc))
                self.update_session_bar()
                return
            self._after_login(on_success)
            return

        self._login_busy = True
        self.btn_login.config(state=tk.DISABLED, text="⏳ Giriş yapılıyor...")
        email, password = request.email, request.password

        def done(_user: Any, err: Optional[BaseException]) -> None:
            self._login_busy = False
            if err is None:
                self._last_email = email
                if request.remember:
                    if self.keeper.remember(email):
                        self.log("[BİLGİ] Oturum bu bilgisayarda ŞİFRELİ olarak hatırlanacak (parola saklanmaz); 'Oturumu Kapat' siler.")
                    else:
                        self.log("[UYARI] Oturum anahtarı şifrelenip saklanamadı; yalnızca e-posta hatırlanacak.")
                else:
                    self.keeper.forget()  # 'Beni hatırla' işaretsiz: önceki kayıt (varsa) silinir
                self._after_login(on_success)
            else:
                self.update_session_bar()
                self._handle_error("Giriş Başarısız", err)

        self.run_background(lambda: self.client.login(email, password), done)

    def _after_login(self, on_success: Optional[Callable[[], None]]) -> None:
        self.update_session_bar()
        if self.client.must_change_password:
            self.ui_warn(
                "Parola Değişikliği Gerekli",
                "Bu hesap için parola değişikliği isteniyor. Uygulamadan parolanızı değiştirmenizi öneririz.",
            )
        if on_success is not None:
            on_success()
        else:
            self.refresh_inventory_list()

    # =========================================================================
    # KAREKOD & ENVANTER İŞ MANTIĞI
    # =========================================================================
    def _toggle_pin_visibility(self) -> None:
        self._pin_visible = not self._pin_visible
        self.inv_pin_entry.config(show="" if self._pin_visible else "•")

    def generate_random_pin(self) -> None:
        """6 basamaklı kurulum PIN'i üretir (yalnızca `secrets`)."""
        self.inv_pin_entry.delete(0, tk.END)
        self.inv_pin_entry.insert(0, generate_setup_pin())

    def generate_device_uuid(self) -> None:
        """UID'yi MAC adresinden türetir (firmware da aynı kuralı kullanır: AHBU-S3-<MAC son 6>)."""
        uid = uid_from_mac(self.inv_mac_entry.get())
        if uid is None:
            self.ui_warn(
                "MAC Gerekli",
                "UID, kartın MAC adresinden türetilir (firmware aynı kuralı kullanır).\n"
                "Önce geçerli bir MAC girin veya 'Karttan MAC Oku'ya basın.",
            )
            return
        self.inv_uuid_entry.delete(0, tk.END)
        self.inv_uuid_entry.insert(0, uid)

    def _selected_port_or_warn(self) -> Optional[str]:
        value = self.port_combo.get()
        if not value or "bulunamadı" in value:
            self.ui_warn("Port Seçilmedi", "Lütfen önce bir COM portu seçin!")
            return None
        try:
            return validate_serial_port(value.split(" ")[0].strip(), self._known_ports or None)
        except ToolError as exc:
            self.ui_warn("Port Sorunu", str(exc))
            return None

    def read_mac_from_board(self) -> None:
        """COM port üzerinden bağlı ESP32-S3 çipinden MAC adresini okur."""
        port = self._selected_port_or_warn()
        if not port:
            return
        try:
            cmd = self.build_esptool_cmd(["--chip", DEFAULT_CHIP, "--port", port, "read_mac"])
        except ToolError as exc:
            self.ui_error("esptool Bulunamadı", str(exc))
            return
        collected: list[str] = []

        def on_finish(code: Optional[int], timed_out: bool, err: Optional[BaseException]) -> None:
            self.btn_read_mac.config(text="📡 Karttan MAC Oku")
            if err is not None:
                self.ui_error("Hata", "esptool çalıştırılamadı. Python/esptool kurulumunu kontrol edin.")
                return
            if timed_out:
                self.ui_error("MAC Okunamadı", "Kart zamanında yanıt vermedi. BOOT düğmesini basılı tutup RESET'e basarak tekrar deneyin.")
                return
            output = "\n".join(collected)
            match = _ESPTOOL_MAC_LINE.search(output)
            mac = normalize_mac(match.group(1)) if match else None
            if mac:
                self._on_mac_read_success(mac)
            else:
                tail = re.sub(r"[^\x20-\x7E\n]", "?", output[-300:])
                self.ui_error("MAC Okunamadı", f"Çipten MAC adresi okunamadı.\nesptool çıktısı:\n{tail}")

        self.btn_read_mac.config(text="⏳ Okunuyor...")
        if not self._launch_esptool(cmd, timeout=ESPTOOL_TIMEOUT_S["read_mac"], on_line=collected.append, on_finish=on_finish):
            self.btn_read_mac.config(text="📡 Karttan MAC Oku")  # başka işlem sürüyor: iş başlatılmadı

    def _on_mac_read_success(self, mac: str) -> None:
        self.inv_mac_entry.delete(0, tk.END)
        self.inv_mac_entry.insert(0, mac)
        self.generate_device_uuid()
        self.ui_info("MAC Okundu", f"Bağlı kartın fabrikasyon MAC adresi başarıyla tespit edildi:\n{mac}")

    def _read_registration_form(self) -> Optional[dict[str, str]]:
        mac = normalize_mac(self.inv_mac_entry.get())
        uid = self.inv_uuid_entry.get().strip().upper()
        pin = self.inv_pin_entry.get().strip()
        model = self.inv_model_entry.get().strip() or DEFAULT_MODEL
        batch = self.inv_batch_entry.get().strip() or datetime.now().strftime("BATCH-%Y-%m")

        if mac is None:
            self.ui_warn("Eksik Bilgi", "Lütfen geçerli bir MAC adresi girin (örn. E8:F6:0A:DD:87:54) veya 'Karttan MAC Oku' düğmesini kullanın.")
            return None
        if not UID_PATTERN.match(uid):
            self.ui_warn("Eksik Bilgi", "Cihaz Seri No (UID) 'AHBU-' ile başlamalı ve yalnızca büyük harf, rakam ve '-' içermelidir.")
            return None
        if not PIN_PATTERN.match(pin):
            self.ui_warn("Geçersiz PIN", "Kurulum PIN kodu tam olarak 6 haneli rakamlardan oluşmalıdır.")
            return None
        if not LABEL_TEXT_PATTERN.match(model) or not LABEL_TEXT_PATTERN.match(batch):
            self.ui_warn("Geçersiz Alan", "Model ve parti yalnızca harf, rakam ve . _ - / karakterlerini içerebilir (en çok 64).")
            return None
        if uid != uid_from_mac(mac) and not self.ui_confirm(
            "UID MAC ile Uyuşmuyor",
            "Firmware kendi UID'sini MAC adresinden türetir (AHBU-S3-<MAC son 6>).\n"
            "Girilen UID bundan farklı: bulut eşlemesi ve provizyon doğrulaması bozulabilir.\n\nYine de kaydedilsin mi?",
        ):
            return None
        return {"mac": mac, "uid": uid, "pin": pin, "model": model, "batch": batch}

    def register_device_and_generate_label(self) -> None:
        """Cihazı sunucu envanterine kaydeder ve etiket üretir (süper kullanıcı oturumu gerekir)."""
        form = self._read_registration_form()
        if form is None:
            return
        pending = self._alive_record()
        if pending is not None and not pending.provisioned and not self.ui_confirm(
            "Önceki Cihaz Tamamlanmadı",
            f"{pending.uid} cihazının provizyonu tamamlanmadı.\nYeni kayıtla önceki cihazın yerel anahtarı/PIN'i bellekten silinir ve bir daha GÖSTERİLEMEZ.\n\nDevam edilsin mi?",
        ):
            return
        self.ensure_login(lambda: self._start_registration(form), note="Cihazı sunucu envanterine kaydetmek için giriş yapın.")

    def _start_registration(self, form: dict[str, str]) -> None:
        if self._register_busy:
            return
        self._register_busy = True
        self.btn_register_device.config(state=tk.DISABLED, text="⏳ Sunucuya Kaydediliyor...")

        def work() -> Any:
            return self.client.register_device(
                uid=form["uid"], mac=form["mac"], pin=form["pin"], model=form["model"], batch_no=form["batch"]
            )

        def done(result: Any, err: Optional[BaseException]) -> None:
            self._register_busy = False
            self.btn_register_device.config(state=tk.NORMAL, text="☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET")
            if err is not None:
                if isinstance(err, ApiError) and err.status == 409:
                    self.ui_error(
                        "Mükerrer Cihaz Uyarısı",
                        f"{err}\n\nBu cihaz daha önce kaydedilmiş olabilir (ör. yarıda kalan bir deneme). PIN ve yerel anahtar "
                        "yeniden gösterilemez; gerekirse envanter tablosundan 'Stokta' durumundaki kaydı silip yeniden kaydedin.",
                    )
                else:
                    self._handle_error("Kayıt Başarısız", err)
                return
            self._on_register_success(result, form)

        self.run_background(work, done)

    def _on_register_success(self, result: Any, form: dict[str, str]) -> None:
        """Kayıt başarılı: gizli değerler belleğe alınır, etiket üretilir (DİSKE YAZILMAZ)."""
        self._discard_record()
        device = result.device if isinstance(result.device, dict) else {}
        record = DeviceRecord(
            uid=form["uid"],
            mac=normalize_mac(device.get("mac_address")) or form["mac"],
            pin=form["pin"],
            local_key=result.local_key,
            ap_pass=generate_ap_pass(),
            qr_claim_url=result.qr_claim_url,
            serial_no=device.get("serial_no"),
            model=str(device.get("model") or form["model"]),
            batch_no=str(device.get("batch_no") or form["batch"]),
            created_at=device.get("created_at") if isinstance(device.get("created_at"), str) else None,
        )
        self.current_record = record
        self.scrubber.add(*record.secret_values())
        self._display_label_preview(build_label_image(record))
        self._refresh_provision_tab()
        self.generate_random_pin()  # aynı PIN ikinci cihazda kullanılmasın
        self.refresh_inventory_list()
        self.ui_info(
            "Cihaz Envantere Eklendi!",
            "✅ Başarılı!\n\n"
            f"Sıra No: {format_serial_badge(record.serial_no)}\n"
            f"Cihaz UID: {record.uid}\n"
            f"MAC: {record.mac}\n\n"
            "PIN ve yerel anahtar bir daha gösterilemez; etiket önizlemede hazır.\n"
            f"Etiket İKİ karekod içerir: '{LABEL_HEADING_CLAIM}' ve '{LABEL_HEADING_WIFI}'. Etiket GİZLİDİR (PIN + kurulum "
            "parolası): yalnızca cihaz üzerinde/elde saklanır, fotoğrafı paylaşılmaz.\n"
            "Sıradaki adımlar:\n"
            "1) 'Etiketi Kaydet' ile etiketi alın (yalnızca siz isterseniz diske yazılır).\n"
            "2) Kartı USB ile bağlı tutup 1. sekmeden firmware'i yükleyin: yükleme bitince araç provizyonu USB (seri) "
            "üzerinden OTOMATİK yapar (Wi-Fi'ye bağlanmanız gerekmez).\n"
            "3) 3. sekmede 'Provizyon doğrulandı' görünce etiketi cihaza yapıştırın.\n\n"
            f"⚠ Firmware yüklenince kart provizyon bitene kadar PAROLASIZ kurulum ağı ('{record.ap_ssid}') yayınlar; yakındaki biri "
            "kartı sahiplenebilir. Provizyon yükleme biter bitmez yapılır (araç otomatik yapar; USB kabloyu çıkarmayın).",
        )

    def _display_label_preview(self, pil_img: Any) -> None:
        """Etiket resmini sağdaki önizleme kutusuna yerleştirir."""
        self.current_label_img = pil_img
        self.saved_label_path = None
        preview_copy = pil_img.copy()
        preview_copy.thumbnail((420, 240))
        tk_img = ImageTk.PhotoImage(preview_copy)
        self.label_canvas_img.config(image=tk_img, text="", width=420, height=240)
        self.label_canvas_img.image = tk_img
        self.btn_save_label.config(state=tk.NORMAL)
        self.btn_print_label.config(state=tk.NORMAL)

    def save_label_file(self) -> bool:
        """Etiketi YALNIZCA kullanıcının seçtiği konuma yazar (diske yazılan tek yer). True = kaydedildi."""
        if self.current_label_img is None:
            return False
        rec = self._alive_record()
        initial = f"{rec.uid}_etiket.png" if rec else "etiket.png"
        path = filedialog.asksaveasfilename(
            parent=self,
            title="Etiketi Kaydet",
            defaultextension=".png",
            filetypes=[("PNG Görseli", "*.png"), ("Tüm Dosyalar", "*.*")],
            initialfile=initial,
        )
        if not path:
            return False
        try:
            self.current_label_img.save(path, "PNG", dpi=LABEL_DPI)  # gerçek boyut (100 x 50 mm) PNG'ye yazılır
        except (OSError, ValueError):
            self.ui_error("Kaydedilemedi", "Etiket dosyası yazılamadı (yol/izin sorunu). Başka bir konum seçin.")
            return False
        self.saved_label_path = path
        self.ui_info("Kaydedildi", f"Etiket görseli kaydedildi:\n{path}\n\n{LABEL_PRINT_NOTE}")
        return True

    def print_label_file(self) -> None:
        """Etiketi Windows varsayılan yazıcısına gönderir. Etiket önce (kullanıcı onayıyla) kaydedilir."""
        if self.current_label_img is None:
            self.ui_warn("Etiket Yok", "Lütfen önce bir etiket oluşturun.")
            return
        if not (self.saved_label_path and os.path.isfile(self.saved_label_path)):
            if not self.save_label_file():
                return
        path = self.saved_label_path or ""
        if os.name != "nt":
            self.ui_info("Yazdırma", f"Etiket dosyası: {path}\n{LABEL_PRINT_NOTE}")
            return
        try:
            os.startfile(path, "print")  # type: ignore[attr-defined]
        except OSError:
            self.ui_error("Yazdırma Hatası", "Etiket yazıcıya gönderilemedi. Dosyayı elle açıp yazdırın.")
            return
        self.ui_info("Yazıcıya Gönderildi", f"Etiket yazdırma sırasına gönderildi.\n{LABEL_PRINT_NOTE}")

    # ---- Envanter listesi ------------------------------------------------------
    def _set_inventory_placeholder(self, text: str) -> None:
        for row in self.inv_tree.get_children():
            self.inv_tree.delete(row)
        self.inv_status_var.set(text)

    def refresh_inventory_list(self) -> None:
        """Sunucudan envanter listesini çeker (giriş gerekir) ve tabloya doldurur."""
        if not self.client.is_authenticated:
            self.ensure_login(self.refresh_inventory_list, note="Envanteri görmek için süper kullanıcı hesabıyla giriş yapın.")
            return
        self.inv_status_var.set("⏳ Envanter yükleniyor...")
        self.run_background(lambda: self.client.list_inventory(limit=100), self._on_inventory_loaded)

    def _on_inventory_loaded(self, data: Any, err: Optional[BaseException]) -> None:
        if err is not None:
            if isinstance(err, SessionExpiredError):
                self.update_session_bar()
                self._set_inventory_placeholder("Oturum süresi doldu. Yeniden giriş yapın.")
            else:
                self.inv_status_var.set("⚠ Liste yüklenemedi: " + self._error_text(err))
            return
        items = data.get("items") if isinstance(data, dict) else None
        self._populate_inventory_tree(items if isinstance(items, list) else [])
        stats = data.get("stats") if isinstance(data, dict) and isinstance(data.get("stats"), dict) else {}
        total = data.get("total") if isinstance(data, dict) else None
        self.inv_status_var.set(
            f"Toplam: {total if total is not None else len(items or [])}   |   Stokta: {stats.get('in_stock', '-')}   |   "
            f"Sahiplenilmiş: {stats.get('claimed', '-')}   |   Askıda: {stats.get('suspended', '-')}   |   İptal: {stats.get('revoked', '-')}"
        )

    @staticmethod
    def _format_server_date(value: Any) -> str:
        return _local_datetime_text(value)

    def _populate_inventory_tree(self, items: list[Any]) -> None:
        for row in self.inv_tree.get_children():
            self.inv_tree.delete(row)
        for item in items:
            if not isinstance(item, dict):
                continue
            status = str(item.get("status") or "IN_STOCK")
            claimed = self._format_server_date(item.get("claimed_at")) or "Henüz Eşlenmedi"
            self.inv_tree.insert(
                "",
                tk.END,
                values=(
                    format_serial_badge(item.get("serial_no", 1)),
                    str(item.get("device_uuid") or ""),
                    str(item.get("mac_address") or ""),
                    str(item.get("model") or ""),
                    status,
                    self._format_server_date(item.get("created_at")),
                    claimed,
                ),
                tags=(status,),
            )
        self._apply_tree_tags()

    def _selected_uid(self) -> Optional[str]:
        selected = self.inv_tree.selection()
        if not selected:
            self.ui_info("Seçim Yapın", "Lütfen önce tablodan bir cihaz seçin.")
            return None
        values = self.inv_tree.item(selected[0]).get("values", [])
        uid = str(values[1]).strip().upper() if len(values) > 1 else ""
        if not UID_PATTERN.match(uid):
            self.ui_warn("Geçersiz Seçim", "Seçilen satırın cihaz kimliği geçersiz.")
            return None
        return uid

    def suspend_selected_device(self) -> None:
        """Seçilen cihazı askıya alır (SUSPENDED)."""
        uid = self._selected_uid()
        if uid is None:
            return
        if not self.ui_confirm("Onay", f"Cihaz ({uid}) askıya alınacaktır.\nAskıdaki cihazlar sahada daireye tanımlanamaz.\nDevam edilsin mi?"):
            return
        self._change_status(uid, "SUSPENDED")

    def activate_selected_device(self) -> None:
        """Seçilen cihazı tekrar aktif stok durumuna getirir."""
        uid = self._selected_uid()
        if uid is not None:
            self._change_status(uid, "IN_STOCK")

    def _change_status(self, uid: str, new_status: str) -> None:
        def run() -> None:
            def done(_result: Any, err: Optional[BaseException]) -> None:
                if err is not None:
                    self._handle_error("Durum Güncellenemedi", err)
                    return
                self.ui_info("Başarılı", f"Cihaz durumu '{new_status}' olarak güncellendi.")
                self.refresh_inventory_list()

            self.run_background(lambda: self.client.update_status(uid, new_status), done)

        self.ensure_login(run, note="Durum değişikliği için e-posta + parola ile süper kullanıcı girişi gerekir.")

    def delete_selected_device(self) -> None:
        """Seçilen cihazı envanterden siler (cihaz UID'si yazılarak onaylanır)."""
        uid = self._selected_uid()
        if uid is None:
            return
        if not self.ui_confirm("Kritik Onay", f"DİKKAT!\n\nCihaz ({uid}) envanterden tamamen silinecektir.\nBu işlem geri alınamaz.\n\nEmin misiniz?"):
            return
        typed = simpledialog.askstring("Silme Onayı", f"Silmeyi onaylamak için cihaz UID'sini aynen yazın:\n{uid}", parent=self)
        if not typed or typed.strip().upper() != uid:
            self.ui_info("İptal Edildi", "UID eşleşmedi; silme işlemi yapılmadı.")
            return

        def run() -> None:
            def done(_result: Any, err: Optional[BaseException]) -> None:
                if err is not None:
                    self._handle_error("Silinemedi", err)
                    return
                self.ui_info("Silindi", f"Cihaz ({uid}) envanterden silindi.")
                self.refresh_inventory_list()

            self.run_background(lambda: self.client.delete_device(uid), done)

        self.ensure_login(run, note="Silme işlemi için e-posta + parola ile süper kullanıcı girişi gerekir.")

    # =========================================================================
    # SEKME 1 (FLASHER) YARDIMCI VE ÇALIŞTIRMA METOTLARI
    # =========================================================================
    def refresh_ports(self) -> None:
        """Sistemdeki aktif seri portları (arka planda) bulur ve açılır kutuya doldurur."""
        previous = self.port_combo.get().split(" ")[0].strip() if self.port_combo.get() else ""

        def work() -> list[tuple[str, str]]:
            return self._get_serial_backend().list_ports()

        def done(ports: Any, err: Optional[BaseException]) -> None:
            if err is not None:
                self._known_ports = set()
                self.port_combo["values"] = []
                self.port_combo.set("Port bulunamadı (seri port kütüphanesi yok)")
                self.log("[UYARI] " + (str(err) if isinstance(err, FactoryError) else "Seri port listesi alınamadı."))
                return
            ports = ports or []
            self._known_ports = {device for device, _ in ports}
            values = [f"{device} ({desc})" for device, desc in ports]
            self.port_combo["values"] = values
            if values:
                index = next((i for i, (device, _) in enumerate(ports) if device == previous), 0)
                self.port_combo.current(index)
            else:
                self.port_combo.set("Port bulunamadı (USB bağlayın)")

        self.run_background(work, done)

    def get_selected_port(self) -> Optional[str]:
        """Açılır kutudan doğrulanmış COM port adını döndürür (örn: 'COM4'); geçersizse None."""
        value = self.port_combo.get()
        if not value or "bulunamadı" in value:
            return None
        try:
            return validate_serial_port(value.split(" ")[0].strip(), self._known_ports or None)
        except ToolError:
            return None

    def apply_mode_selection(self) -> None:
        """Seçilen moda göre firmware dosya yolunu otomatik ayarlar."""
        mode = self.mode_var.get()
        if mode == "custom":
            rel_file = str(self.version_data.get("firmware_file", ""))
            target_path = os.path.normpath(os.path.join(RELEASES_DIR, rel_file))
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, target_path)
            self.inc_ver_btn.config(state=tk.NORMAL)
            self.browse_btn.config(state=tk.NORMAL)
        elif mode == "factory":
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, os.path.normpath(FACTORY_BIN))
            self.inc_ver_btn.config(state=tk.DISABLED)
            self.browse_btn.config(state=tk.DISABLED)

    def inc_version(self) -> None:
        """Sürüm numarasını arttırır ve yeni sürüm klasörünü oluşturur."""
        cur = str(self.version_data.get("current_version", "1.0.0"))
        next_ver = increment_version_str(cur)
        if not self.ui_confirm("Versiyon Arttır", f"Mevcut sürüm: v{cur}\nYeni sürüm: v{next_ver}\n\nOnaylıyor musunuz?"):
            return
        new_rel_dir = os.path.join(RELEASES_DIR, f"v{next_ver}")
        new_bin_name = f"firmware_v{next_ver}.bin"
        new_bin_path = os.path.join(new_rel_dir, new_bin_name)
        try:
            os.makedirs(new_rel_dir, exist_ok=True)
            cur_bin = self.file_entry.get().strip()
            if os.path.isfile(cur_bin):
                shutil.copy2(cur_bin, new_bin_path)
            self.version_data["current_version"] = next_ver
            self.version_data["firmware_file"] = f"v{next_ver}/{new_bin_name}"
            self.version_data["updated_at"] = datetime.now().isoformat()
            save_version_info(self.version_data)
        except OSError:
            self.ui_error("Versiyon Arttırılamadı", "Sürüm klasörü/dosyası yazılamadı (yol veya izin sorunu).")
            return
        self.ver_label.config(text=f"Mevcut: v{next_ver}")
        self.lbl_fw_version.config(text=f"Firmware v{next_ver}")
        self.apply_mode_selection()
        self.log(f"\n[VERSİYON] Sürüm v{next_ver} olarak güncellendi: {new_bin_path}")

    def browse_custom_file(self) -> None:
        """Kullanıcının harici bir .bin dosyası seçmesine izin verir."""
        path = filedialog.askopenfilename(
            parent=self,
            title="Firmware .bin Dosyası Seçin",
            filetypes=[("Binary Firmware", "*.bin"), ("Tüm Dosyalar", "*.*")],
            initialdir=RELEASES_DIR if os.path.isdir(RELEASES_DIR) else BASE_DIR,
        )
        if path:
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, os.path.normpath(path))

    def set_ui_state(self, enabled: bool = True) -> None:
        state = tk.NORMAL if enabled else tk.DISABLED
        for widget in (self.btn_flash, self.btn_read_info, self.btn_erase, self.btn_read_mac, self.r_custom, self.r_factory):
            widget.config(state=state)
        self.is_flashing = not enabled
        self._update_provision_buttons()

    def log(self, text: str) -> None:
        """Log alanına satır ekler (yalnızca arayüz iş parçacığı; bellekteki gizli değerler maskelenir)."""
        line = self.scrubber.scrub(str(text)) + "\n"
        tag = log_line_tag(line)  # hata rose / uyarı amber / başarı emerald / komut sky; metin değişmez
        if tag:
            self.log_text.insert(tk.END, line, tag)
        else:
            self.log_text.insert(tk.END, line)
        try:
            if int(self.log_text.index("end-1c").split(".")[0]) > 3000:
                self.log_text.delete("1.0", "500.0")
        except (ValueError, tk.TclError):
            pass
        self.log_text.see(tk.END)

    def build_esptool_cmd(self, sub_args: list[str]) -> list[str]:
        command = find_esptool_command()
        backend = self._serial_backend
        if isinstance(backend, RelayBackend) and command and command[0] == sys.executable:
            command = [backend.python] + command[1:]  # esptool pyserial ister: onun bulunduğu yorumlayıcıyla çalıştır
        return command + [str(arg) for arg in sub_args]

    @staticmethod
    def _run_process(cmd_args: list[str], timeout: float, on_line: Callable[[str], None]) -> tuple[Optional[int], bool]:
        """Alt süreci (shell=False, liste argümanlı) çalıştırır; satırları ``on_line``'a verir."""
        process = subprocess.Popen(
            cmd_args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            shell=False,
            creationflags=_NO_WINDOW,
        )
        timed_out = threading.Event()

        def kill() -> None:
            timed_out.set()
            try:
                process.kill()
            except OSError:
                pass

        timer = threading.Timer(timeout, kill)
        timer.daemon = True
        timer.start()
        try:
            for line in process.stdout or []:
                text = line.rstrip()
                if text:
                    on_line(text)
            process.wait()
        finally:
            timer.cancel()
        return process.returncode, timed_out.is_set()

    def _launch_esptool(
        self,
        cmd_args: list[str],
        *,
        timeout: float,
        on_line: Callable[[str], None],
        on_finish: Callable[[Optional[int], bool, Optional[BaseException]], None],
    ) -> bool:
        """esptool'u arka planda çalıştırır (seri port tek işleme açıktır). False = başka işlem sürüyor."""
        if self._esptool_busy:
            self.ui_info("Meşgul", "Kartla başka bir işlem sürüyor. Bitmesini bekleyin.")
            return False
        if self._prov_busy and self._prov_mode == "serial":
            self.ui_info("Meşgul", "USB (seri) provizyon sürüyor. Bitmesini bekleyin veya iptal edin.")
            return False
        self._esptool_busy = True
        self.set_ui_state(False)

        def work() -> tuple[Optional[int], bool]:
            return self._run_process(cmd_args, timeout, lambda line: self.post_ui(on_line, line))

        def done(result: Any, err: Optional[BaseException]) -> None:
            self._esptool_busy = False
            self.set_ui_state(True)
            code, timed_out = result if result else (None, False)
            on_finish(code, timed_out, err)

        self.run_background(work, done)
        return True

    def run_command(
        self,
        cmd_args: list[str],
        *,
        timeout: float = ESPTOOL_TIMEOUT_S["write_flash"],
        success_text: str = "Firmware işlemi başarıyla tamamlandı!",
        on_success: Optional[Callable[[Optional[str]], Optional[str]]] = None,
    ) -> bool:
        """Harici komutu (esptool) arka planda çalıştırır; çıktıları loglar, sonucu iletişim kutusuyla bildirir.

        ``on_success(son_görülen_MAC)`` başarıda çağrılır; döndürdüğü metin başarı kutusuna eklenir."""
        seen_macs: list[str] = []

        def on_line(line: str) -> None:
            self.log(line)
            match = _ESPTOOL_MAC_LINE.search(line)
            if match:
                normalized = normalize_mac(match.group(1))
                if normalized:
                    seen_macs.append(normalized)

        self.log("\n" + "=" * 50)
        self.log(f"[BAŞLADI] {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        self.log(f"[KOMUT] {' '.join(cmd_args)}")
        self.log("=" * 50)

        def on_finish(code: Optional[int], timed_out: bool, err: Optional[BaseException]) -> None:
            if err is not None:
                self.log("\n❌ [HATA] esptool başlatılamadı.")
                self.ui_error("Hata", "esptool çalıştırılamadı. Python/esptool kurulumunu ve dosya yollarını kontrol edin.")
            elif timed_out:
                self.log("\n❌ [HATA] İşlem zaman aşımına uğradı ve durduruldu.")
                self.ui_error("Zaman Aşımı", "İşlem zamanında bitmedi ve durduruldu. Kabloyu/portu kontrol edip tekrar deneyin.")
            elif code == 0:
                self.log("\n✅ [BAŞARILI] İşlem eksiksiz tamamlandı!")
                extra = on_success(seen_macs[-1] if seen_macs else None) if on_success else None
                self.ui_info("Başarılı", success_text + (f"\n\n{extra}" if extra else ""))
            else:
                self.log(f"\n❌ [HATA] İşlem başarısız oldu (Hata Kodu: {code})")
                self.ui_error("Hata", "İşlem sırasında hata oluştu. Log penceresini kontrol edin.")

        return self._launch_esptool(cmd_args, timeout=timeout, on_line=on_line, on_finish=on_finish)

    def start_flash(self) -> None:
        port = self._selected_port_or_warn()
        if not port:
            return
        try:
            # AHBU firmware'i için imajda USB (seri) provizyon komutu da aranır; Waveshare fabrika yazılımı için aranmaz.
            check = inspect_firmware_file(self.file_entry.get(), expect_serial_provisioning=self.mode_var.get() != "factory")
        except ToolError as exc:
            self.ui_warn("Dosya Sorunu", str(exc))
            return
        if check.warnings and not self.ui_confirm("Firmware Uyarısı", "\n\n".join(check.warnings) + "\n\nYine de yazılsın mı?"):
            return
        try:
            cmd = self.build_esptool_cmd(["--chip", DEFAULT_CHIP, "--port", port, "--baud", DEFAULT_BAUD, "write_flash", FLASH_OFFSET, check.path])
        except ToolError as exc:
            self.ui_error("esptool Bulunamadı", str(exc))
            return
        self._flash_port = port  # provizyon aynı USB/COM portundan yapılır
        if self.mode_var.get() == "factory":  # Waveshare orijinal yazılımı: AHBU kurulum ağı/provizyonu yoktur
            self.run_command(
                cmd,
                timeout=ESPTOOL_TIMEOUT_S["write_flash"],
                success_text="Waveshare fabrika yazılımı yüklendi (test/kurtarma). Bu yazılım AHBU provizyonu yapmaz; "
                "AHBU firmware'i için 'Bizim Geliştirdiğimiz Yazılım' seçeneğiyle yeniden yükleyin.",
            )
            return
        self.run_command(
            cmd,
            timeout=ESPTOOL_TIMEOUT_S["write_flash"],
            success_text="Firmware yüklendi.",
            on_success=self._after_flash_success,
        )

    def _after_flash_success(self, flashed_mac: Optional[str]) -> str:
        """Flash sonrası: açık kurulum ağı riski nedeniyle provizyon HEMEN başlatılır (CONTRACTS §3b/§3c). Tercih edilen yol
        USB (seri) FACTORYINIT'tir: aynı port, kablosuz ağ gerekmez. Yüklenen kartın MAC'i bekleyen kayıtla eşleşiyorsa (veya
        MAC görülemediyse) provizyon otomatik başlar; kart/MAC uyuşmazlığı seri STATUS ile ayrıca denetlenir."""
        rec = self._alive_record()
        ssid = rec.ap_ssid if rec else (ap_ssid_from_mac(flashed_mac) if flashed_mac else None)
        urgency = provision_urgency_notice(ssid)
        if rec is None or rec.state != "registered":
            return (
                urgency
                + "\n\nCihaz henüz sunucu envanterine kaydedilmediyse önce 2. sekmede kaydedin, sonra 3. sekmede "
                "'Seri (USB) ile Provizyonla'ya basın."
            )
        if flashed_mac and flashed_mac != rec.mac:
            return (
                f"⚠ Yüklenen kartın MAC adresi ({flashed_mac}) bekleyen kayıtla ({rec.mac}) eşleşmiyor; provizyon "
                "otomatik başlatılmadı. Doğru kartı/kaydı kullandığınızdan emin olun.\n\n" + urgency
            )
        self.notebook.select(self.tab_provision)
        self.start_serial_provision(port=self._flash_port, wait_for_port=True, auto=True)
        return (
            "Provizyon USB (seri) üzerinden OTOMATİK başlatıldı: kartı ve USB kablosunu ÇIKARMAYIN. Yerel anahtar kablosuz "
            "ağdan geçmez; bilgisayarı Wi-Fi'ye bağlamanız GEREKMEZ.\n"
            f"Kart yeniden başlarken kısa süre PAROLASIZ kurulum ağı ('{ssid}') yayınlar; USB provizyon bitince ağ parolalı olur. "
            "Sonucu 3. sekmeden izleyebilir veya iptal edebilirsiniz."
        )

    def start_read_info(self) -> None:
        port = self._selected_port_or_warn()
        if not port:
            return
        try:
            cmd = self.build_esptool_cmd(["--chip", DEFAULT_CHIP, "--port", port, "chip_id"])
        except ToolError as exc:
            self.ui_error("esptool Bulunamadı", str(exc))
            return
        self.run_command(cmd, timeout=ESPTOOL_TIMEOUT_S["chip_id"], success_text="Çip bilgisi okundu (log penceresine bakın).")

    def start_erase(self) -> None:
        port = self._selected_port_or_warn()
        if not port:
            return
        if not self.ui_confirm("Onay", "Çipteki tüm flash hafıza silinecektir. Devam etmek istiyor musunuz?"):
            return
        try:
            cmd = self.build_esptool_cmd(["--chip", DEFAULT_CHIP, "--port", port, "erase_flash"])
        except ToolError as exc:
            self.ui_error("esptool Bulunamadı", str(exc))
            return
        self.run_command(cmd, timeout=ESPTOOL_TIMEOUT_S["erase_flash"], success_text="Flash hafıza silindi.")

    # =========================================================================
    # Pencere kapanışı
    # =========================================================================
    def on_close(self) -> None:
        """Pencere kapanırken: süren işlem ve provizyonu tamamlanmamış kayıt için uyarır; sırları siler."""
        if self._esptool_busy and not self.ui_confirm("İşlem Sürüyor", "Kartla bir işlem sürüyor. Şimdi kapatmak kartı yarım bırakabilir.\n\nYine de kapatılsın mı?"):
            return
        rec = self._alive_record()
        if rec is not None and not rec.provisioned and not self.ui_confirm(
            "Provizyon Tamamlanmadı",
            f"{rec.uid} cihazının provizyonu tamamlanmadı.\nKapatırsanız yerel anahtar ve PIN bellekten silinir ve bir daha GÖSTERİLEMEZ.\n\nYine de kapatılsın mı?",
        ):
            return
        self.shutdown()

    def destroy(self) -> None:
        """Pencereyi yok etmeden önce bekleyen zamanlayıcıları iptal eder."""
        self._closing = True
        for job in (self._pump_job, self._clipboard_job):
            if job:
                try:
                    self.after_cancel(job)
                except tk.TclError:
                    pass
        self._pump_job = self._clipboard_job = None
        super().destroy()

    def shutdown(self) -> None:
        """Gizli değerleri bellekten siler, oturumu (en iyi çabayla) kapatır ve pencereyi yok eder."""
        self._closing = True
        if self._clipboard_secret:
            self._clear_clipboard_if(self._clipboard_secret)
        self._discard_record()
        remembered = self.keeper.remembered
        refresh = self.client.end_session_local()
        if refresh and not remembered:  # sunucudaki oturum ailesi en iyi çabayla iptal edilir (en çok 2 sn beklenir)
            # Hatırlanan oturum iptal EDİLMEZ: şifreli kayıt bir sonraki açılışta sessiz girişle kullanılır (özelliğin amacı).
            closer = threading.Thread(target=self.client.revoke_refresh_token, args=(refresh,), name="ev-logout", daemon=True)
            closer.start()
            closer.join(timeout=2.0)
        self.scrubber.clear()
        try:
            self.destroy()
        except tk.TclError:
            pass


def _report_missing_dependency() -> None:  # pragma: no cover - ortam sorunu
    message = (
        "Gerekli Python paketleri eksik: qrcode, pillow.\n"
        "Kurulum (sistem yöneticisi): pip install qrcode pillow\n"
        "(pyserial isteğe bağlıdır: yoksa PlatformIO'nun Python'undaki pyserial kullanılır; o da yoksa USB seri provizyon "
        "kapanır ve yalnızca güvensiz Wi-Fi yedek yolu kalır.)\n\n"
        f"Ayrıntı: {_MISSING_DEPENDENCY}"
    )
    root = tk.Tk()
    root.withdraw()
    messagebox.showerror("Eksik Paket", message, parent=root)
    root.destroy()


def main() -> int:
    if _MISSING_DEPENDENCY:  # pragma: no cover
        _report_missing_dependency()
        return 1
    app = EvOtomasyonServisApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
