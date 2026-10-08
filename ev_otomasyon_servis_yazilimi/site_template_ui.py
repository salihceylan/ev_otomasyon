# pyright: reportUnknownParameterType=false, reportUnknownArgumentType=false, reportUnknownVariableType=false, reportUnknownMemberType=false
"""
Site + kurulum şablonu sekmeleri (İP-3.2 .. İP-3.5) - servis aracının Tk arayüz parçası.

* ``🏢 4. Siteler``: site ekle/düzenle/sil, daire listesi, toplu daire üretimi, daireye şablon atama, kartı daireye bağlama,
  ilerleme (planlandı / yazıldı / kuruldu / teslim edildi), daireye "Karta Yaz" ve kablolama şeması.
* ``📐 5. Şablonlar``: site (ya da Genel) seç, şablon ekle/düzenle/çoğalt/sil, sürüm geçmişi; düzenleyici (röleler, girişler,
  güvenlik, dimmer sorusu); kaydetmeden önce yerel + sunucu doğrulaması; her kayıt yeni sürüm.
* Karta yazım (İP-3.4): USB (seri ``TPL``) ya da Ethernet (kart kablolu Ethernet'ten gelen isteği anahtarsız kabul eder;
  kullanıcı kararı 2026-10-08) -> geri okuma -> ``POST /template-writes`` kaydı. Kablolama şeması PDF'i (``wiring_pdf``).

İş mantığı ``template_model`` (saf), ağ/seri ``factory_client``'tadır; bu modül yalnız arayüzdür. Ana pencere sınıfı
(``EvOtomasyonServisApp``) bu karışımı (mixin) miras alır ve altyapıyı (tema, istemci, arka plan işi, iletişim kutuları) sağlar.
"""

from __future__ import annotations

import copy
import re
import threading
import tkinter as tk
from dataclasses import dataclass
from tkinter import filedialog, messagebox, simpledialog, ttk
from typing import Any, Callable, Optional

import template_model as tm
import wiring_pdf
from factory_client import (
    UID_PATTERN,
    ApiError,
    FactoryError,
    ProvisionError,
    SerialUnavailableError,
    SessionExpiredError,
    ETH_NO_KEY,
    TemplateLanWriter,
    TemplateSerialWriter,
    TemplateWriteError,
    normalize_device_host,
)

FLAT_STATUS_TEXT = {"planned": "Planlandı", "written": "Yazıldı", "installed": "Kuruldu", "handed_over": "Teslim edildi"}
# atolye-11: sunucunun yazım kaydını (POST /template-writes) KALICI olarak reddettiği durumlar (kart envanterde yok, şablon
# sürümü/daire yok, şablon/site silinmiş, daireye başka kart bağlı, şablon başka siteye ait, geçersiz alan): yeniden göndermek
# sonucu değiştirmez -> kayıt kuyruktan çıkarılır, bir kez bildirilir. Ağ / 5xx / 429 / oturum (401) / yetki (403) geçicidir.
_REJECTED_RECORD_STATUSES = frozenset({400, 404, 409, 422})
RECORD_REJECTED_STATUS = "sunucu reddetti (kayıt kuyruktan çıkarıldı)"
RECORD_PENDING_STATUS = "işlenemedi, bekliyor ('📤 Bekleyen Kayıtları Gönder')"


def write_record_rejected(exc: BaseException) -> bool:
    """Yazım kaydı kalıcı olarak mı reddedildi (kuyruktan çıkarılır)? 400/404/409/422 ve aracın yerel doğrulama hatası: evet."""
    if isinstance(exc, SessionExpiredError):
        return False
    if isinstance(exc, ApiError):
        return exc.status in _REJECTED_RECORD_STATUSES
    return type(exc) is FactoryError  # record_template_write'ın yerel doğrulaması (geçersiz UID / yol / sonuç)
GENERAL_SCOPE = "Genel (standart şablonlar)"
SITE_FIELDS = (
    ("name", "Site adı *"),
    ("address", "Adres"),
    ("city", "İl"),
    ("district", "İlçe"),
    ("contact_name", "Sorumlu adı"),
    ("contact_phone", "Sorumlu telefonu"),
    ("contact_email", "E-posta"),
    ("block_count", "Blok sayısı"),
    ("flat_count", "Daire sayısı"),
    ("notes", "Not"),
)
_PHONE = re.compile(r"^[0-9 +()\-]{7,20}$")
_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")


def validate_site_form(values: dict[str, str]) -> tuple[Optional[dict[str, Any]], str]:
    """Site formu -> (gövde, hata metni). Boş isteğe bağlı alanlar gönderilmez; sayılar tamsayı olur."""
    body: dict[str, Any] = {}
    name = (values.get("name") or "").strip()
    if not name or len(name) > 120:
        return None, "Site adı zorunludur (en çok 120 karakter)."
    body["name"] = name
    for key in ("address", "city", "district", "contact_name", "notes"):
        text = " ".join((values.get(key) or "").split()) if key != "notes" else (values.get(key) or "").strip()
        if len(text) > 500:
            return None, "Metin alanları en çok 500 karakter olabilir."
        body[key] = text
    phone = (values.get("contact_phone") or "").strip()
    if phone and not _PHONE.match(phone):
        return None, "Telefon numarası geçersiz (yalnız rakam, boşluk, +, -, parantez)."
    body["contact_phone"] = phone
    email = (values.get("contact_email") or "").strip()
    if email and not _EMAIL.match(email):
        return None, "E-posta adresi geçersiz."
    body["contact_email"] = email
    for key, label in (("block_count", "Blok sayısı"), ("flat_count", "Daire sayısı")):
        text = (values.get(key) or "").strip()
        if not text:
            body[key] = 0
            continue
        if not text.isdigit() or int(text) > 10000:
            return None, f"{label} 0-10000 arasında bir tamsayı olmalı."
        body[key] = int(text)
    return body, ""


def flat_progress_text(stats: Any) -> str:
    if not isinstance(stats, dict):
        return "-"
    return " · ".join(f"{FLAT_STATUS_TEXT[key]} {int(stats.get(key) or 0)}" for key in FLAT_STATUS_TEXT)


def flat_display_name(flat: dict[str, Any]) -> str:
    return tm.flat_info_line(flat.get("block", ""), flat.get("number", "")) or "-"


def _short_time(value: Any) -> str:
    return str(value or "")[:16].replace("T", " ")


def flat_last_write_text(flat: dict[str, Any], template: Optional[dict[str, Any]] = None) -> str:
    """Daire listesindeki 'Son yazım' sütunu (atolye-7; sözleşme 18 ``last_write`` + ``last_ok_write``): başarısız yazım
    ``⚠ vN (kod)``, şablonun güncel sürümünden eski son başarılı yazım 'eski sürüm', dairenin kartından başka bir karta yapılan
    yazım 'başka kart' olarak ayrı gösterilir. Eski sunucu (``result`` alanı yok) başarılı sayılır."""
    last = flat.get("last_write") if isinstance(flat.get("last_write"), dict) else None
    ok = flat.get("last_ok_write") if isinstance(flat.get("last_ok_write"), dict) else None
    shown = last or ok
    if shown is None:
        return ""
    where = f"{str(shown.get('via', '')).upper()} · {_short_time(shown.get('at'))}"
    if last is not None and last.get("result") == "error":
        parts = [f"⚠ v{last.get('version')} ({last.get('error_code') or 'hata'}) · {where}"]
        if ok is None:
            parts.append("başarılı yazım yok")
    else:
        parts = [f"v{shown.get('version')} · {where}"]
    current = (template or {}).get("current_version")
    ok_version = (ok or {}).get("version")
    if isinstance(ok_version, int) and isinstance(current, int) and ok_version < current:
        parts.append(f"eski sürüm (son başarılı v{ok_version}, güncel v{current})")
    flat_uid = str(flat.get("device_uuid") or "").upper()
    written_uid = str((ok or {}).get("device_uuid") or (last or {}).get("device_uuid") or "").upper()
    if flat_uid and written_uid and written_uid != flat_uid:
        parts.append(f"başka kart ({written_uid})")
    return " · ".join(parts)


@dataclass
class TemplateWriteRequest:
    via: str                       # "usb" | "eth"
    label: str = ""
    port: str = ""
    host: str = ""
    device_uid: str = ""           # Ethernet: zorunlu (yalnız yazım kaydı için; IP<->UID denetlenmez); USB: daireye bağlıysa denetim


# ===========================================================================
# İletişim pencereleri
# ===========================================================================
class _Modal(tk.Toplevel):
    """Ortak modal pencere iskeleti (login diyaloğu deseni)."""

    def __init__(self, parent: tk.Misc, theme: Any, title: str) -> None:
        super().__init__(parent)
        self.theme = theme
        self._parent = parent
        self.title(title)
        self.transient(parent)
        theme.register(self, "root")
        self.configure(padx=14, pady=12)
        self.result: Any = None
        self.bind("<Escape>", lambda _event: self._cancel())

    def show_modal(self) -> None:
        self.update_idletasks()
        try:
            px, py = self._parent.winfo_rootx(), self._parent.winfo_rooty()
            self.geometry(f"+{px + 40}+{py + 40}")
            self.wait_visibility()
            self.grab_set()
        except tk.TclError:
            pass
        self._parent.wait_window(self)

    def warn(self, text: str) -> None:
        messagebox.showwarning(self.title(), text, parent=self)

    def _cancel(self) -> None:
        self.result = None
        self.destroy()


class SiteDialog(_Modal):
    """Site ekle / düzenle formu."""

    def __init__(self, parent: tk.Misc, theme: Any, site: Optional[dict[str, Any]] = None) -> None:
        super().__init__(parent, theme, "🏢 Site Bilgileri")
        card, body = theme.card(self, "🏢 Site Ekle" if site is None else "🏢 Siteyi Düzenle", accent="sky")
        card.pack(fill=tk.BOTH, expand=True)
        self.entries: dict[str, Any] = {}
        for row, (key, caption) in enumerate(SITE_FIELDS):
            theme.label(body, "label.field", text=caption + ":").grid(row=row, column=0, sticky="w", pady=3)
            entry = theme.entry(body, width=44)
            value = (site or {}).get(key)
            if value not in (None, ""):
                entry.insert(0, str(value))
            entry.grid(row=row, column=1, sticky="ew", pady=3, padx=(10, 0))
            self.entries[key] = entry
        buttons = theme.frame(body, "frame.surface")
        buttons.grid(row=len(SITE_FIELDS), column=0, columnspan=2, sticky="ew", pady=(12, 0))
        theme.button(buttons, role="secondary", size="md", text="İptal", command=self._cancel).pack(side=tk.RIGHT, padx=(8, 0))
        theme.button(buttons, role="primary", size="md", text="✓ Kaydet", command=self._ok).pack(side=tk.RIGHT)

    def values(self) -> dict[str, str]:
        return {key: entry.get() for key, entry in self.entries.items()}

    def _ok(self) -> None:
        body, error = validate_site_form(self.values())
        if body is None:
            self.warn(error)
            return
        self.result = body
        self.destroy()

    @classmethod
    def ask(cls, parent: tk.Misc, theme: Any, site: Optional[dict[str, Any]] = None) -> Optional[dict[str, Any]]:
        dialog = cls(parent, theme, site)
        dialog.show_modal()
        return dialog.result


class BulkFlatsDialog(_Modal):
    """Toplu daire üretimi: blok, başlangıç-bitiş numarası, daire tipi, şablon."""

    def __init__(self, parent: tk.Misc, theme: Any, templates: list[dict[str, Any]]) -> None:
        super().__init__(parent, theme, "🧱 Toplu Daire Üret")
        card, body = theme.card(self, "🧱 Toplu Daire Üret (ör. A blok 1-24)", accent="emerald")
        card.pack(fill=tk.BOTH, expand=True)
        self.templates = templates
        self.e_block = self._row(body, 0, "Blok:", "A")
        self.e_from = self._row(body, 1, "İlk daire no:", "1")
        self.e_to = self._row(body, 2, "Son daire no:", "")
        self.e_type = self._row(body, 3, "Daire tipi (isteğe bağlı):", "")
        theme.label(body, "label.field", text="Şablon (isteğe bağlı):").grid(row=4, column=0, sticky="w", pady=3)
        self.combo = ttk.Combobox(body, state="readonly", width=40,
                                  values=["(şablon atanmasın)"] + [_template_choice(t) for t in templates])
        self.combo.current(0)
        self.combo.grid(row=4, column=1, sticky="w", pady=3, padx=(10, 0))
        buttons = theme.frame(body, "frame.surface")
        buttons.grid(row=5, column=0, columnspan=2, sticky="ew", pady=(12, 0))
        theme.button(buttons, role="secondary", size="md", text="İptal", command=self._cancel).pack(side=tk.RIGHT, padx=(8, 0))
        theme.button(buttons, role="primary", size="md", text="✓ Daireleri Üret", command=self._ok).pack(side=tk.RIGHT)

    def _row(self, body: Any, row: int, caption: str, value: str) -> Any:
        self.theme.label(body, "label.field", text=caption).grid(row=row, column=0, sticky="w", pady=3)
        entry = self.theme.entry(body, width=20)
        entry.insert(0, value)
        entry.grid(row=row, column=1, sticky="w", pady=3, padx=(10, 0))
        return entry

    def _ok(self) -> None:
        block = self.e_block.get().strip()
        start, end = self.e_from.get().strip(), self.e_to.get().strip()
        if not block or len(block) > 16:
            self.warn("Blok adı zorunludur (en çok 16 karakter).")
            return
        if not (start.isdigit() and end.isdigit()) or not 1 <= int(start) <= int(end) <= 9999 or int(end) - int(start) >= 500:
            self.warn("Daire numaraları 1-9999 arasında olmalı; bir seferde en çok 500 daire üretilir.")
            return
        flat_type = self.e_type.get().strip()
        if len(flat_type.encode("utf-8")) > tm.FLAT_TYPE_BYTES:
            self.warn("Daire tipi en çok 16 bayt olabilir.")
            return
        index = self.combo.current()
        template_id = self.templates[index - 1]["id"] if index > 0 else None
        self.result = {"block": block, "start": int(start), "end": int(end), "flat_type": flat_type or None, "template_id": template_id}
        self.destroy()

    @classmethod
    def ask(cls, parent: tk.Misc, theme: Any, templates: list[dict[str, Any]]) -> Optional[dict[str, Any]]:
        dialog = cls(parent, theme, templates)
        dialog.show_modal()
        return dialog.result


class ChoiceDialog(_Modal):
    """Listeden tek seçim (şablon atama vb.)."""

    def __init__(self, parent: tk.Misc, theme: Any, title: str, prompt: str, choices: list[str]) -> None:
        super().__init__(parent, theme, title)
        card, body = theme.card(self, title, accent="violet")
        card.pack(fill=tk.BOTH, expand=True)
        theme.label(body, "label.body", text=prompt, wraplength=420, justify="left").pack(anchor="w", pady=(0, 8))
        self.combo = ttk.Combobox(body, state="readonly", width=48, values=choices)
        if choices:
            self.combo.current(0)
        self.combo.pack(fill=tk.X)
        buttons = theme.frame(body, "frame.surface")
        buttons.pack(fill=tk.X, pady=(12, 0))
        theme.button(buttons, role="secondary", size="md", text="İptal", command=self._cancel).pack(side=tk.RIGHT, padx=(8, 0))
        theme.button(buttons, role="primary", size="md", text="✓ Seç", command=self._ok).pack(side=tk.RIGHT)

    def _ok(self) -> None:
        self.result = self.combo.current()
        self.destroy()

    @classmethod
    def ask(cls, parent: tk.Misc, theme: Any, title: str, prompt: str, choices: list[str]) -> Optional[int]:
        dialog = cls(parent, theme, title, prompt, choices)
        dialog.show_modal()
        return dialog.result


class TemplateWriteDialog(_Modal):
    """Karta yazım yolu: USB (seri port) ya da Ethernet (IP). Yerel anahtar burada SORULMAZ/GÖSTERİLMEZ."""

    def __init__(
        self,
        parent: tk.Misc,
        theme: Any,
        *,
        target: str,
        ports: list[str],
        port: str = "",
        label: str = "",
        device_uid: str = "",
        via: str = "usb",
    ) -> None:
        super().__init__(parent, theme, "💾 Karta Yaz")
        card, body = theme.card(self, "💾 Şablonu Karta Yaz", accent="emerald")
        card.pack(fill=tk.BOTH, expand=True)
        theme.label(body, "label.body", text=target, wraplength=520, justify="left").grid(row=0, column=0, columnspan=2, sticky="w")
        self.via = tk.StringVar(value=via)
        theme.radio(body, text="🔌 USB (seri) - önerilen; güvenlik ayarlarını tamamen yazabilir", variable=self.via,
                    value="usb").grid(row=1, column=0, columnspan=2, sticky="w", pady=(8, 0))
        theme.label(body, "label.field", text="USB portu:").grid(row=2, column=0, sticky="w", padx=(24, 0))
        self.port_combo = ttk.Combobox(body, state="readonly", width=24, values=ports)
        if port in ports:
            self.port_combo.current(ports.index(port))
        elif ports:
            self.port_combo.current(0)
        self.port_combo.grid(row=2, column=1, sticky="w", pady=2)
        theme.radio(body, text="🌐 Ethernet (LAN) - kartın Ethernet IP'si; anahtar gerekmez",
                    variable=self.via, value="eth").grid(row=3, column=0, columnspan=2, sticky="w", pady=(8, 0))
        theme.label(body, "label.field", text="Kartın IP adresi:").grid(row=4, column=0, sticky="w", padx=(24, 0))
        self.e_host = theme.entry(body, width=24)
        self.e_host.grid(row=4, column=1, sticky="w", pady=2)
        theme.label(body, "label.field", text="Kart UID'si:").grid(row=5, column=0, sticky="w", padx=(24, 0))
        self.e_uid = theme.entry(body, "entry.mono", width=24)
        self.e_uid.insert(0, device_uid)
        self.e_uid.grid(row=5, column=1, sticky="w", pady=2)
        theme.label(body, "label.field", text="Kart adı (etiket):").grid(row=6, column=0, sticky="w", pady=(10, 0))
        self.e_label = theme.entry(body, width=34)
        self.e_label.insert(0, label)
        self.e_label.grid(row=6, column=1, sticky="w", pady=(10, 0))
        theme.label(
            body, "label.note.amber",
            text="Ethernet: IP'nin doğru karta ait olduğu DENETLENMEZ, yanlış IP başka karta yazar; UID yalnız yazım kaydı içindir "
                 "(kart kablolu Ethernet'ten gelen isteği anahtarsız kabul eder; kullanıcı kararı 2026-10-08).",
            wraplength=520, justify="left",
        ).grid(row=7, column=0, columnspan=2, sticky="w", pady=(8, 0))
        buttons = theme.frame(body, "frame.surface")
        buttons.grid(row=8, column=0, columnspan=2, sticky="ew", pady=(12, 0))
        theme.button(buttons, role="secondary", size="md", text="İptal", command=self._cancel).pack(side=tk.RIGHT, padx=(8, 0))
        theme.button(buttons, role="primary", size="md", text="💾 Yaz", command=self._ok).pack(side=tk.RIGHT)

    def _ok(self) -> None:
        label = " ".join(self.e_label.get().split())
        if len(label.encode("utf-8")) > tm.LABEL_BYTES:
            self.warn("Kart adı en çok 31 bayt olabilir.")
            return
        uid = self.e_uid.get().strip().upper()
        if self.via.get() == "usb":
            port = self.port_combo.get().split(" ")[0].strip()
            if not port:
                self.warn("USB portu seçin (1. sekmede 'Portları Yenile').")
                return
            if uid and not UID_PATTERN.match(uid):
                self.warn("Kart UID'si geçersiz (AHBU-S3-XXXXXX).")
                return
            self.result = TemplateWriteRequest("usb", label=label, port=port, device_uid=uid)
        else:
            try:
                host = normalize_device_host(self.e_host.get())
            except ValueError as exc:
                self.warn(str(exc))
                return
            if not self.e_host.get().strip():
                self.warn("Kartın IP adresini girin.")
                return
            if not UID_PATTERN.match(uid):
                self.warn("Yazım kaydı için kart UID'si gerekir (AHBU-S3-XXXXXX).")
                return
            self.result = TemplateWriteRequest("eth", label=label, host=host, device_uid=uid)
        self.destroy()

    @classmethod
    def ask(cls, parent: tk.Misc, theme: Any, **kwargs: Any) -> Optional[TemplateWriteRequest]:
        dialog = cls(parent, theme, **kwargs)
        dialog.show_modal()
        return dialog.result


class DimmerDialog(_Modal):
    """K4: 'Parlaklık ayarı yapılacak mı?' -> dimmer kaynağı / adres / kanal + yerleşim yönergesi."""

    def __init__(self, parent: tk.Misc, theme: Any, relay_name: str, light: Optional[dict[str, Any]]) -> None:
        super().__init__(parent, theme, "💡 Parlaklık (Dimmer)")
        card, body = theme.card(self, f"💡 {relay_name}: Parlaklık ayarı yapılacak mı?", accent="amber")
        card.pack(fill=tk.BOTH, expand=True)
        self.relay_name = relay_name
        self.var_on = tk.BooleanVar(value=bool(light and light.get("dimmable")))
        theme.check(body, text="Evet, parlaklık ayarlanacak (dimmer gerekli)", variable=self.var_on,
                    command=self._refresh).grid(row=0, column=0, columnspan=2, sticky="w")
        theme.label(body, "label.field", text="Dimmer kaynağı:").grid(row=1, column=0, sticky="w", pady=3)
        self.combo = ttk.Combobox(body, state="readonly", width=34, values=[tm.DIMMER_SRC_TEXT[1], tm.DIMMER_SRC_TEXT[2]])
        self.combo.current(1 if light and light.get("src") == 2 else 0)
        self.combo.bind("<<ComboboxSelected>>", lambda _e: self._refresh())
        self.combo.grid(row=1, column=1, sticky="w", pady=3)
        self.e_addr = self._num(body, 2, "Adres (0-247):", (light or {}).get("addr", 1))
        self.e_ch = self._num(body, 3, "Kanal (0-255):", (light or {}).get("ch", 1))
        self.guide = theme.label(body, "label.note.sky", text="", wraplength=460, justify="left")
        self.guide.grid(row=4, column=0, columnspan=2, sticky="w", pady=(8, 0))
        buttons = theme.frame(body, "frame.surface")
        buttons.grid(row=5, column=0, columnspan=2, sticky="ew", pady=(12, 0))
        theme.button(buttons, role="secondary", size="md", text="İptal", command=self._cancel).pack(side=tk.RIGHT, padx=(8, 0))
        theme.button(buttons, role="primary", size="md", text="✓ Tamam", command=self._ok).pack(side=tk.RIGHT)
        self._refresh()

    def _num(self, body: Any, row: int, caption: str, value: Any) -> Any:
        self.theme.label(body, "label.field", text=caption).grid(row=row, column=0, sticky="w", pady=3)
        entry = self.theme.entry(body, width=8)
        entry.insert(0, str(value))
        entry.grid(row=row, column=1, sticky="w", pady=3)
        return entry

    def current(self) -> Optional[dict[str, Any]]:
        if not self.var_on.get():
            return None
        addr, ch = self.e_addr.get().strip(), self.e_ch.get().strip()
        if not (addr.isdigit() and ch.isdigit()) or int(addr) > 247 or int(ch) > 255:
            raise ValueError("Adres 0-247, kanal 0-255 olmalı.")
        return {"dimmable": 1, "src": self.combo.current() + 1, "addr": int(addr), "ch": int(ch)}

    def _refresh(self) -> None:
        try:
            light = self.current()
        except ValueError:
            light = {"dimmable": 1, "src": self.combo.current() + 1, "addr": 0, "ch": 0}
        self.guide.config(text=tm.dimmer_guidance(light, self.relay_name))

    def _ok(self) -> None:
        try:
            self.result = ("set", self.current())
        except ValueError as exc:
            self.warn(str(exc))
            return
        self.destroy()

    @classmethod
    def ask(cls, parent: tk.Misc, theme: Any, relay_name: str, light: Optional[dict[str, Any]]) -> Any:
        dialog = cls(parent, theme, relay_name, light)
        dialog.show_modal()
        return dialog.result


def _template_choice(template: dict[str, Any]) -> str:
    return f"{template.get('name', '?')} ({template.get('flat_type', '-')}, v{template.get('current_version', '?')})"


# ===========================================================================
# Şablon düzenleyici
# ===========================================================================
KIND_CHOICES = [tm.RELAY_KIND_LABELS[k] for k in ("light", "shutter", "impulse")]
KIND_BY_LABEL = {label: kind for kind, label in tm.RELAY_KIND_LABELS.items()}
MODE_CHOICES = [tm.DI_MODE_TEXT[m] for m in tm.DI_MODES]
MODE_BY_LABEL = {label: mode for mode, label in tm.DI_MODE_TEXT.items()}
ROLE_CHOICES = ["Yok"] + [tm.SENSOR_KIND_TEXT[k] for k in tm.SENSOR_KINDS]
ROLE_BY_LABEL = {label: kind for kind, label in tm.SENSOR_KIND_TEXT.items()}
ACT_CHOICES = [tm.ACT_KIND_TEXT[k] for k in tm.ACT_KINDS]
ACT_BY_LABEL = {label: kind for kind, label in tm.ACT_KIND_TEXT.items()}
CLOSE_CHOICES = [tm.CLOSE_MODE_TEXT[k] for k in tm.CLOSE_MODES]
CLOSE_BY_LABEL = {label: kind for kind, label in tm.CLOSE_MODE_TEXT.items()}
MEDIUM_CHOICES = [tm.MEDIUM_TEXT[k] for k in tm.MEDIUMS]
MEDIUM_BY_LABEL = {label: kind for kind, label in tm.MEDIUM_TEXT.items()}


class TemplateEditorDialog(_Modal):
    """Şablon düzenleyici. ``result`` = yerel doğrulamadan geçmiş şablon gövdesi (kaydet) ya da None (iptal).

    Model ``self.t`` (dict) tek doğru kaynaktır: satır widget'ları her yapısal değişiklikte (tip, ek modül, güvenlik rolü)
    önce modele okunur (``collect``), model ``template_model`` yardımcılarıyla değiştirilir, sonra tablolar yeniden çizilir."""

    def __init__(self, parent: tk.Misc, theme: Any, template: dict[str, Any], scope_text: str = "") -> None:
        super().__init__(parent, theme, "📐 Şablon Düzenleyici")
        self.t = copy.deepcopy(template)
        self._initial_safety = self._safety_counts(self.t)  # atolye-5: kaydetmede son savunma (silinen cihaz sayısı)
        self.geometry("1180x760")
        head_card, head = theme.card(self, f"📐 Şablon - {scope_text or 'Genel'}", accent="violet")
        head_card.pack(fill=tk.X)
        theme.label(head, "label.field", text="Şablon adı:").grid(row=0, column=0, sticky="w")
        self.e_name = theme.entry(head, width=30)
        self.e_name.insert(0, self.t["meta"]["name"])
        self.e_name.grid(row=0, column=1, sticky="w", padx=(6, 16))
        theme.label(head, "label.field", text="Daire tipi:").grid(row=0, column=2, sticky="w")
        self.e_flat = theme.entry(head, width=10)
        self.e_flat.insert(0, self.t["meta"]["flat_type"])
        self.e_flat.grid(row=0, column=3, sticky="w", padx=(6, 16))
        ext = self.t["ext_module"]
        self.var_ext = tk.BooleanVar(value=bool(ext["enabled"]))
        theme.check(head, text="Ek modül (RS485) var", variable=self.var_ext).grid(row=0, column=4, sticky="w")
        self.c_ext = ttk.Combobox(head, state="readonly", width=4, values=[str(c) for c in tm.EXT_CHANNELS if c])
        self.c_ext.set(str(ext["channels"] or 8))
        self.c_ext.grid(row=0, column=5, padx=4)
        theme.label(head, "label.field", text="adres:").grid(row=0, column=6, sticky="w")
        self.e_addr = theme.entry(head, width=5)
        self.e_addr.insert(0, str(ext["address"]))
        self.e_addr.grid(row=0, column=7, padx=4)
        theme.button(head, role="secondary", size="sm", text="↔ Kanalları Uygula", command=self.apply_ext).grid(row=0, column=8, padx=6)

        self.tabs = ttk.Notebook(self)
        self.tabs.pack(fill=tk.BOTH, expand=True, pady=8)
        self.relay_frame = self._scroll_tab("⚡ Röle Çıkışları")
        self.di_frame = self._scroll_tab("🔘 Girişler (DI)")
        self.safety_frame = self._scroll_tab("🛡️ Güvenlik")

        self.status = theme.label(self, "label.status", text="", anchor="w", justify="left", wraplength=1100)
        self.status.pack(fill=tk.X)
        buttons = theme.frame(self, "frame.bg")
        buttons.pack(fill=tk.X, pady=(6, 0))
        theme.button(buttons, role="secondary", size="md", text="İptal", command=self._cancel).pack(side=tk.RIGHT, padx=(8, 0))
        theme.button(buttons, role="primary", size="md", text="💾 Doğrula ve Kaydet (yeni sürüm)", command=self._save).pack(side=tk.RIGHT)
        theme.button(buttons, role="secondary", size="md", text="✓ Doğrula", command=self.validate_now).pack(side=tk.RIGHT, padx=8)
        self.relay_rows: list[dict[str, Any]] = []
        self.di_rows: list[dict[str, Any]] = []
        self.act_rows: list[dict[str, Any]] = []
        self.rebuild()

    # ---- iskelet ----
    def _scroll_tab(self, title: str) -> Any:
        outer = self.theme.frame(self.tabs, "frame.surface")
        self.tabs.add(outer, text=title)
        canvas = tk.Canvas(outer, highlightthickness=0, bd=0)
        self.theme.register(canvas, "frame.surface")
        bar = self.theme.scrollbar(outer, orient="vertical", command=canvas.yview)
        inner = self.theme.frame(canvas, "frame.surface")
        inner.bind("<Configure>", lambda _e, c=canvas: c.configure(scrollregion=c.bbox("all")))
        canvas.create_window((0, 0), window=inner, anchor="nw")
        canvas.configure(yscrollcommand=bar.set)
        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        bar.pack(side=tk.RIGHT, fill=tk.Y)
        return inner

    @staticmethod
    def _clear(frame: Any) -> None:
        for child in frame.winfo_children():
            child.destroy()

    def _combo(self, parent: Any, values: list[str], value: str, width: int, on_change: Optional[Callable[[], None]] = None) -> Any:
        combo = ttk.Combobox(parent, state="readonly", width=width, values=values)
        combo.set(value)
        if on_change is not None:
            combo.bind("<<ComboboxSelected>>", lambda _e: on_change())
        return combo

    def _entry(self, parent: Any, value: Any, width: int) -> Any:
        entry = self.theme.entry(parent, width=width)
        entry.insert(0, "" if value is None else str(value))
        return entry

    def rebuild(self) -> None:
        self._build_relays()
        self._build_dis()
        self._build_safety()

    # ---- röleler ----
    def _build_relays(self) -> None:
        frame = self.relay_frame
        self._clear(frame)
        self.relay_rows = []
        for col, text in enumerate(("Kanal", "Ad", "Oda", "Tip", "Yön", "Süre", "Bağlanacak yük (PDF)", "Parlaklık")):
            self.theme.label(frame, "label.field", text=text).grid(row=0, column=col, sticky="w", padx=3)
        for index, relay in enumerate(self.t["relays"]):
            ch = index + 1
            kind = relay["type"]
            row: dict[str, Any] = {"ch": ch}
            self.theme.label(frame, "label.body", text=f"R{ch}").grid(row=ch, column=0, padx=3)
            row["name"] = self._entry(frame, relay["name"], 22)
            row["name"].grid(row=ch, column=1, padx=3, pady=1)
            row["room"] = self._entry(frame, relay.get("room", ""), 14)
            row["room"].grid(row=ch, column=2, padx=3)
            label = tm.RELAY_KIND_LABELS["shutter" if kind.startswith("shutter") else kind]
            row["kind"] = self._combo(frame, KIND_CHOICES, label, 13, lambda c=ch: self.on_kind(c))
            row["kind"].grid(row=ch, column=3, padx=3)
            direction = {"shutter_up": "⬆ Yukarı", "shutter_down": "⬇ Aşağı"}.get(kind, "")
            self.theme.label(frame, "label.body", text=direction).grid(row=ch, column=4, padx=3)
            if kind.startswith("shutter"):
                value, unit = relay.get("runtime_s", 25), "sn"
            elif kind == "impulse":
                value, unit = relay.get("pulse_ms", 1000), "ms"
            else:
                value, unit = "", ""
            row["time"] = self._entry(frame, value, 7)
            row["time"].grid(row=ch, column=5, padx=3)
            if kind == "shutter_down":
                unit = ""  # çiftin süresi yukarı satırından gelir (iki röle aynı süre)
            if not unit:
                row["time"].config(state=tk.DISABLED)
            row["load"] = self._entry(frame, relay.get("load", ""), 30)
            row["load"].grid(row=ch, column=6, padx=3)
            if kind == "light":
                light = tm.light_option(self.t, ch)
                text = "💡 Var" if light and light.get("dimmable") else "💡 Yok"
                row["dim"] = self.theme.button(frame, role="secondary", size="sm", text=text,
                                               command=lambda c=ch: self.ask_dimmer(c))
                row["dim"].grid(row=ch, column=7, padx=3)
            row["unit"] = unit
            self.relay_rows.append(row)

    def on_kind(self, ch: int) -> None:
        """Röle tipi değişimi. Değişim bir güvenlik cihazını (vana/siren/fan) ya da dimmeri silecekse önce sorulur (atolye-5);
        'Hayır' -> model değişmez, açılır kutu eski değere döner."""
        self.collect(strict=False)
        kind = KIND_BY_LABEL.get(self.relay_rows[ch - 1]["kind"].get(), "light")
        try:
            effects = tm.relay_kind_side_effects(self.t, ch, kind)
            if effects and not messagebox.askyesno(
                "Güvenlik Öğesi Silinecek",
                "Bu değişiklik şu güvenlik öğelerini silecek: " + ", ".join(effects) + ". Devam?",
                parent=self,
            ):
                self.status.config(text="Değişiklik yapılmadı (güvenlik öğeleri korundu).")
                self.rebuild()
                return
            removed = tm.set_relay_kind(self.t, ch, kind)
            self.status.config(text=("Silindi: " + ", ".join(removed)) if removed else "")
        except ValueError as exc:
            self.status.config(text="⚠ " + str(exc))
        self.rebuild()

    def ask_dimmer(self, ch: int) -> None:
        self.collect(strict=False)
        answer = DimmerDialog.ask(self, self.theme, self.t["relays"][ch - 1]["name"], tm.light_option(self.t, ch))
        if answer is not None:
            self.apply_dimmer(ch, answer[1])

    def apply_dimmer(self, ch: int, light: Optional[dict[str, Any]]) -> None:
        self.collect(strict=False)
        if light is None:
            tm.set_light_dimmer(self.t, ch, False)
        else:
            tm.set_light_dimmer(self.t, ch, True, src=light["src"], addr=light["addr"], dim_ch=light["ch"])
        self.rebuild()

    # ---- girişler ----
    def _relay_choices(self) -> list[str]:
        return ["0 - Boşta"] + [f"{i + 1} - {r['name']}" for i, r in enumerate(self.t["relays"])]

    def _build_dis(self) -> None:
        frame = self.di_frame
        self._clear(frame)
        self.di_rows = []
        for col, text in enumerate(("Giriş", "Ad", "Hedef röle", "Kip", "Kablolama notu (PDF)", "Güvenlik rolü", "Kontak", "Bölge")):
            self.theme.label(frame, "label.field", text=text).grid(row=0, column=col, sticky="w", padx=3)
        choices = self._relay_choices()
        zones = [str(z["id"]) for z in self.t["safety"]["zones"]]
        for index, item in enumerate(self.t["dis"]):
            ch = index + 1
            sensor = tm.di_sensor(self.t, ch)
            row: dict[str, Any] = {"ch": ch}
            self.theme.label(frame, "label.body", text=f"D{ch}").grid(row=ch, column=0, padx=3)
            row["name"] = self._entry(frame, item["name"], 22)
            row["name"].grid(row=ch, column=1, padx=3, pady=1)
            target = item["target_relay"]
            row["target"] = self._combo(frame, choices, choices[target] if target < len(choices) else choices[0], 24)
            row["target"].grid(row=ch, column=2, padx=3)
            row["mode"] = self._combo(frame, MODE_CHOICES, tm.DI_MODE_TEXT.get(item["mode"], MODE_CHOICES[0]), 44)
            row["mode"].grid(row=ch, column=3, padx=3)
            row["wiring"] = self._entry(frame, item.get("wiring", ""), 24)
            row["wiring"].grid(row=ch, column=4, padx=3)
            role = tm.SENSOR_KIND_TEXT.get(sensor["kind"], "Yok") if sensor else "Yok"
            row["role"] = self._combo(frame, ROLE_CHOICES, role, 22, lambda c=ch: self.on_role(c))
            row["role"].grid(row=ch, column=5, padx=3)
            row["contact"] = self._combo(frame, ["NO", "NC"], "NC" if sensor and sensor.get("active_open") else "NO", 4)
            row["contact"].grid(row=ch, column=6, padx=3)
            zone_values = (["0 (tümü)"] if sensor and sensor["kind"] in tm.CONTROL_KINDS else []) + zones
            zone_now = "0 (tümü)" if sensor and sensor.get("zone") == 0 else str(sensor.get("zone", 1)) if sensor else "1"
            row["zone"] = self._combo(frame, zone_values, zone_now, 8)
            row["zone"].grid(row=ch, column=7, padx=3)
            if sensor is not None:
                row["target"].config(state=tk.DISABLED)
                row["mode"].config(state=tk.DISABLED)
                if sensor["kind"] in ("gas", "smoke", "arm_key"):
                    row["contact"].config(state=tk.DISABLED)  # README: daima NC
            else:
                row["contact"].config(state=tk.DISABLED)
                row["zone"].config(state=tk.DISABLED)
            self.di_rows.append(row)

    def on_role(self, ch: int) -> None:
        self.collect(strict=False)
        label = self.di_rows[ch - 1]["role"].get()
        kind = ROLE_BY_LABEL.get(label)
        existing = tm.di_sensor(self.t, ch)
        zone = existing.get("zone", 1) if existing else 1
        if kind in tm.CONTROL_KINDS:
            zone = 0 if existing is None else zone
        elif not zone:
            zone = 1
        tm.set_di_sensor(self.t, ch, kind, zone=zone, normally_closed=bool(existing and existing.get("active_open")))
        self.rebuild()

    # ---- güvenlik ----
    def _build_safety(self) -> None:
        frame = self.safety_frame
        self._clear(frame)
        safety = self.t["safety"]
        policy = safety["policy"]
        self.var_policy = tk.BooleanVar(value=bool(policy["on"]))
        self.theme.check(frame, text="Güvenlik tepkileri açık (önerilen)", variable=self.var_policy).grid(row=0, column=0, columnspan=3, sticky="w")
        self.theme.label(frame, "label.field", text="Kuruluk bekleme (sn):").grid(row=0, column=3, sticky="e")
        self.e_dry = self._entry(frame, policy["dry_hold_ms"] // 1000, 6)
        self.e_dry.grid(row=0, column=4, sticky="w", padx=4)
        self.theme.label(frame, "label.field", text="Bölgeler (Bölge 1 zorunlu; boş = yok):").grid(row=1, column=0, columnspan=3, sticky="w", pady=(10, 2))
        names = {z["id"]: z["name"] for z in safety["zones"]}
        self.zone_entries = []
        for zone_id in range(1, tm.MAX_ZONES + 1):
            self.theme.label(frame, "label.body", text=f"Bölge {zone_id}:").grid(row=2, column=(zone_id - 1) * 2, sticky="e")
            entry = self._entry(frame, names.get(zone_id, ""), 14)
            entry.grid(row=2, column=(zone_id - 1) * 2 + 1, sticky="w", padx=4)
            self.zone_entries.append(entry)
        self.theme.label(frame, "label.field", text="Güvenlik cihazları (vana / siren / fan):").grid(row=3, column=0, columnspan=4, sticky="w", pady=(12, 2))
        headers = ("Röle", "Tür", "Kapanma kipi", "Akışkan", "2. röle (AÇ)", "Bölgeler (1,2)", "Ad", "Siren süresi (sn)")
        for col, text in enumerate(headers):
            self.theme.label(frame, "label.field", text=text).grid(row=4, column=col, sticky="w", padx=3)
        relay_values = [str(i) for i in range(1, tm.total_channels(self.t) + 1)]
        self.act_rows = []
        for index, act in enumerate(safety.get("actuators", [])):
            r = 5 + index
            row = {
                "relay": self._combo(frame, relay_values, str(act.get("relay", 1)), 4),
                "kind": self._combo(frame, ACT_CHOICES, tm.ACT_KIND_TEXT.get(act.get("kind", "valve"), ACT_CHOICES[0]), 8),
                "close": self._combo(frame, CLOSE_CHOICES, tm.CLOSE_MODE_TEXT.get(act.get("close_mode", "energize")), 22),
                "medium": self._combo(frame, MEDIUM_CHOICES, tm.MEDIUM_TEXT.get(act.get("medium", "none")), 5),
                "relay2": self._entry(frame, act.get("relay2", "") or "", 4),
                "zones": self._entry(frame, ",".join(str(z) for z in act.get("zones", [])), 8),
                "name": self._entry(frame, act.get("name", ""), 18),
                "run": self._entry(frame, act.get("run_limit_s", "") or "", 6),
                "extra": {k: v for k, v in act.items() if k in ("fb_di", "fb_closed_active", "fb_timeout_s", "exproof")},
            }
            for col, key in enumerate(("relay", "kind", "close", "medium", "relay2", "zones", "name", "run")):
                row[key].grid(row=r, column=col, padx=3, pady=1, sticky="w")
            self.act_rows.append(row)
        r = 5 + len(self.act_rows)
        buttons = self.theme.frame(frame, "frame.surface")
        buttons.grid(row=r, column=0, columnspan=6, sticky="w", pady=(6, 0))
        self.theme.button(buttons, role="tint.emerald", size="sm", text="➕ Cihaz Ekle", command=self.add_actuator).pack(side=tk.LEFT)
        self.theme.button(buttons, role="tint.rose", size="sm", text="➖ Son Cihazı Sil", command=self.remove_actuator).pack(side=tk.LEFT, padx=6)
        bridge = [s for s in safety.get("sensors", []) if str(s.get("id", "")).startswith("b")]
        if bridge:
            self.theme.label(frame, "label.muted", text=f"Köprü sensörleri (değiştirilmeden korunur): {', '.join(s['id'] for s in bridge)}").grid(
                row=r + 1, column=0, columnspan=8, sticky="w", pady=(6, 0))
        self.theme.label(frame, "label.note.rose", text=wiring_pdf.GAS_WARNING, wraplength=1000, justify="left").grid(
            row=r + 2, column=0, columnspan=8, sticky="w", pady=(10, 0))

    def add_actuator(self) -> None:
        self.collect(strict=False)
        used = {a.get("relay") for a in self.t["safety"]["actuators"]}
        free = next((ch for ch in range(tm.total_channels(self.t), 0, -1)
                     if ch not in used and self.t["relays"][ch - 1]["type"] == "light"), None)
        if free is None or len(self.t["safety"]["actuators"]) >= tm.MAX_ACTUATORS:
            self.status.config(text="⚠ Boş 'Lamba/Priz' rölesi yok (güvenlik cihazı panjur/darbe rölesine bağlanamaz).")
            return
        self.t["safety"]["actuators"].append({"relay": free, "kind": "valve", "close_mode": "energize", "medium": "water",
                                              "zones": [1], "name": "Su Vanası"})
        self.rebuild()

    def remove_actuator(self) -> None:
        self.collect(strict=False)
        if self.t["safety"]["actuators"]:
            self.t["safety"]["actuators"].pop()
            self.rebuild()

    # ---- ek modül ----
    def apply_ext(self) -> None:
        self.collect(strict=False)
        try:
            address = int(self.e_addr.get().strip())
        except ValueError:
            self.status.config(text="⚠ Ek modül adresi 1-247 arasında bir sayı olmalı.")
            return
        enabled = bool(self.var_ext.get())
        channels = int(self.c_ext.get() or 8) if enabled else 0
        old_n = tm.total_channels(self.t)
        tm.set_ext_module(self.t, enabled, channels, address)
        new_n = tm.total_channels(self.t)
        self.status.config(text=f"Kanal sayısı {old_n} -> {new_n}." + (" Dışarıda kalan kanalların ayarları silindi." if new_n < old_n else ""))
        self.rebuild()

    # ---- modele okuma ----
    def _collect_ext(self, strict: bool) -> Optional[str]:
        """atolye-9: ek modül alanları modelle karşılaştırılır. Yalnız adres değiştiyse doğrudan modele yazılır; etkinlik ya da
        kanal sayısı değiştiyse (tabloları yeniden boyutlar) ``strict`` modda 'Kanalları Uygula' onayla çalıştırılır, onay
        verilmezse kayıt durdurulur (değişiklik sessizce kaybolmaz)."""
        ext = self.t["ext_module"]
        address_text = self.e_addr.get().strip()
        error: Optional[str] = None
        if address_text.isdigit() and 1 <= int(address_text) <= 247:
            ext["address"] = int(address_text)
        elif strict:
            error = "Ek modül adresi 1-247 arasında bir sayı olmalı."
        enabled = bool(self.var_ext.get())
        channels = int(self.c_ext.get()) if (self.c_ext.get() or "").isdigit() else 8
        structural = enabled != bool(ext["enabled"]) or (enabled and channels != ext["channels"])
        if structural and strict:
            old_n = tm.total_channels(self.t)
            new_n = tm.BASE_CHANNELS + (channels if enabled else 0)
            if error is None and messagebox.askyesno(
                "Ek Modül Değişikliği",
                f"Ek modül değişikliği henüz uygulanmadı ('Kanalları Uygula'ya basılmadı): kanal sayısı {old_n} -> {new_n}.\n\n"
                "Şimdi uygulansın mı?" + (" Dışarıda kalan kanalların ayarları silinir." if new_n < old_n else ""),
                parent=self,
            ):
                self.apply_ext()
            else:
                error = error or "Ek modül değişikliği uygulanmadı: Kanalları Uygula düğmesine basın"
        return error

    def collect(self, strict: bool = True) -> Optional[str]:
        """Widget'ları modele (``self.t``) yazar. ``strict``: sayı alanları hatalıysa Türkçe hata metni döner."""
        ext_error = self._collect_ext(strict)
        meta = self.t["meta"]
        meta["name"] = " ".join(self.e_name.get().split())
        meta["flat_type"] = self.e_flat.get().strip()
        error: Optional[str] = ext_error
        for row in self.relay_rows:
            relay = self.t["relays"][row["ch"] - 1]
            relay["name"] = row["name"].get().strip()
            relay["room"] = row["room"].get().strip()
            relay["load"] = row["load"].get().strip()
            if row["unit"]:
                text = row["time"].get().strip()
                if not text.isdigit():
                    error = error or f"R{row['ch']}: süre bir tamsayı olmalı ({row['unit']})."
                    continue
                if relay["type"] == "shutter_up":
                    tm.set_shutter_runtime(self.t, row["ch"], int(text))
                else:
                    relay["pulse_ms"] = int(text)
        for row in self.di_rows:
            item = self.t["dis"][row["ch"] - 1]
            item["name"] = row["name"].get().strip()
            item["wiring"] = row["wiring"].get().strip()
            sensor = tm.di_sensor(self.t, row["ch"])
            if sensor is None:
                item["target_relay"] = int(row["target"].get().split(" ")[0] or 0)
                item["mode"] = MODE_BY_LABEL.get(row["mode"].get(), "toggle")
            else:
                zone_text = row["zone"].get().split(" ")[0]
                sensor["zone"] = int(zone_text) if zone_text.isdigit() else 1
                if sensor["kind"] not in ("gas", "smoke", "arm_key"):
                    sensor["active_open"] = 1 if row["contact"].get() == "NC" else 0
        if hasattr(self, "var_policy"):
            safety = self.t["safety"]
            safety["policy"]["on"] = bool(self.var_policy.get())
            dry = self.e_dry.get().strip()
            if dry.isdigit():
                safety["policy"]["dry_hold_ms"] = int(dry) * 1000
            else:
                error = error or "Kuruluk bekleme süresi saniye cinsinden tamsayı olmalı."
            safety["zones"] = [{"id": i + 1, "name": e.get().strip()} for i, e in enumerate(self.zone_entries) if e.get().strip()]
            actuators = []
            for index, row in enumerate(self.act_rows):
                act: dict[str, Any] = {"relay": int(row["relay"].get() or 1), "kind": ACT_BY_LABEL.get(row["kind"].get(), "valve")}
                if act["kind"] == "valve":
                    act["close_mode"] = CLOSE_BY_LABEL.get(row["close"].get(), "energize")
                    act["medium"] = MEDIUM_BY_LABEL.get(row["medium"].get(), "water")
                    relay2 = row["relay2"].get().strip()
                    if act["close_mode"] == "pulse":
                        if not relay2.isdigit():
                            error = error or f"Cihaz {index + 1}: iki röleli vanada 2. (AÇ) rölesi gerekli."
                        else:
                            act["relay2"] = int(relay2)
                zones_text = row["zones"].get().replace(" ", "")
                try:
                    act["zones"] = [int(z) for z in zones_text.split(",") if z]
                except ValueError:
                    error = error or f"Cihaz {index + 1}: bölgeler '1,2' biçiminde yazılmalı."
                    act["zones"] = []
                name = row["name"].get().strip()
                if name:
                    act["name"] = name
                run = row["run"].get().strip()
                if run:
                    if run.isdigit():
                        act["run_limit_s"] = int(run)
                    else:
                        error = error or f"Cihaz {index + 1}: süre tamsayı olmalı."
                act.update(row["extra"])
                actuators.append(act)
            safety["actuators"] = actuators
        return error if strict else None

    def validate_now(self) -> Optional[tm.TemplateIssue]:
        error = self.collect()
        if error:
            self.status.config(text="⚠ " + error)
            return tm.TemplateIssue("bad_value")
        issue = tm.validate_template(self.t)
        self.status.config(text=("⚠ " + str(issue)) if issue else "✅ Şablon geçerli (yerel doğrulama). Kaydederken sunucu da doğrular.")
        return issue

    @staticmethod
    def _safety_counts(template: dict[str, Any]) -> tuple[int, int]:
        safety = template.get("safety") or {}
        return (len(safety.get("actuators") or []),
                len([light for light in safety.get("lights") or [] if light.get("dimmable")]))

    def _lost_safety_count(self) -> int:
        actuators, dimmers = self._safety_counts(self.t)
        return max(0, self._initial_safety[0] - actuators) + max(0, self._initial_safety[1] - dimmers)

    def _save(self) -> None:
        if self.validate_now() is not None:
            return
        lost = self._lost_safety_count()
        if lost and not messagebox.askyesno(
            "Güvenlik Cihazı Silindi", f"{lost} güvenlik cihazı silindi, yine de kaydedilsin mi?", parent=self
        ):
            self.status.config(text=f"⚠ Kaydedilmedi: düzenleyici açıldığından beri {lost} güvenlik cihazı/dimmer silindi.")
            return
        self.result = copy.deepcopy(self.t)
        self.destroy()

    @classmethod
    def ask(cls, parent: tk.Misc, theme: Any, template: dict[str, Any], scope_text: str = "") -> Optional[dict[str, Any]]:
        dialog = cls(parent, theme, template, scope_text)
        dialog.show_modal()
        return dialog.result


# ===========================================================================
# Ana pencereye eklenen sekmeler (karışım)
# ===========================================================================
class SiteTemplateTabsMixin:
    """``EvOtomasyonServisApp`` için 4. ve 5. sekmeler ile karta yazım akışı."""

    # Ana pencerenin sağladıkları (tip ipucu)
    theme: Any
    client: Any
    notebook: Any

    def _init_site_template_state(self) -> None:
        self._sites: list[dict[str, Any]] = []
        self._flats: list[dict[str, Any]] = []
        self._templates: list[dict[str, Any]] = []
        self._tpl_busy = False
        self._tpl_preset_port: Optional[str] = None
        self._tpl_cancel = threading.Event()
        self._pdf_font_loader: Callable[..., Any] = wiring_pdf.default_font_loader
        # atolye-11: sunucuya işlenemeyen yazım kayıtları (oturum yokluğu dahil) bellekte bekler; '📤 Bekleyen Kayıtları Gönder'.
        self._pending_writes: list[dict[str, Any]] = []
        self._write_seq = 0
        self._flushing_writes = False  # gönderim sürüyor: aynı kayıt iki kez gönderilmesin
        # atolye-6: son USB yazımında kilitlenen güvenlik bölgeleri {"port", "zones"} ('🔕 Alarmı Onayla (USB)').
        self._last_latched: Optional[dict[str, Any]] = None

    # ---- sekme 4: siteler -------------------------------------------------------------------------------------
    def _build_sites_tab(self) -> None:
        theme = self.theme
        outer = theme.frame(self.tab_sites, "frame.bg", padx=12, pady=10)
        outer.pack(fill=tk.BOTH, expand=True)
        card, body = theme.card(outer, "🏢 Siteler (servis sorumlusu + süper kullanıcı)", accent="sky", padx=10, pady=8)
        card.pack(fill=tk.BOTH, expand=True, pady=(0, 8))
        actions = theme.frame(body, "frame.surface")
        actions.pack(fill=tk.X, pady=(0, 6))
        theme.button(actions, role="secondary", size="sm", text="🔄 Siteleri Yenile", command=self.refresh_sites).pack(side=tk.LEFT)
        theme.button(actions, role="tint.emerald", size="sm", text="➕ Site Ekle", command=self.add_site).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="tint.sky", size="sm", text="✏️ Siteyi Düzenle", command=self.edit_site).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="danger", size="sm", text="🗑️ Siteyi Sil", command=self.delete_site).pack(side=tk.LEFT, padx=4)
        self.sites_status = tk.StringVar(value="Siteleri görmek için giriş yapıp '🔄 Siteleri Yenile'ye basın.")
        theme.label(body, "label.status", textvariable=self.sites_status, anchor="w").pack(fill=tk.X)
        columns = ("name", "place", "contact", "phone", "blocks", "flats", "progress")
        self.sites_tree = ttk.Treeview(body, columns=columns, show="headings", height=6, selectmode="browse")
        for key, (text, width) in {
            "name": ("Site", 180), "place": ("İl / İlçe", 130), "contact": ("Sorumlu", 130), "phone": ("Telefon", 110),
            "blocks": ("Blok", 50), "flats": ("Daire", 55), "progress": ("İlerleme", 330),
        }.items():
            self.sites_tree.heading(key, text=text)
            self.sites_tree.column(key, width=width, anchor="w")
        self.sites_tree.pack(fill=tk.BOTH, expand=True)
        self.sites_tree.bind("<<TreeviewSelect>>", lambda _e: self.refresh_flats())

        card, body = theme.card(outer, "🏠 Daireler (seçili site)", accent="emerald", padx=10, pady=8)
        card.pack(fill=tk.BOTH, expand=True)
        actions = theme.frame(body, "frame.surface")
        actions.pack(fill=tk.X, pady=(0, 6))
        theme.button(actions, role="tint.emerald", size="sm", text="🧱 Toplu Daire Üret", command=self.bulk_flats).pack(side=tk.LEFT)
        theme.button(actions, role="tint.violet", size="sm", text="📐 Şablon Ata", command=self.assign_flat_template).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="tint.sky", size="sm", text="🔗 Kart Bağla", command=self.link_flat_device).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="primary", size="sm", text="💾 Karta Yaz", command=self.write_flat_template).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="secondary", size="sm", text="📄 Kablolama Şeması (PDF)", command=self.flat_wiring_pdf).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="tint.emerald", size="sm", text="✅ Teslim Edildi", command=self.mark_flat_handed_over).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="danger", size="sm", text="🗑️ Daireyi Sil", command=self.delete_flat).pack(side=tk.LEFT, padx=4)
        self.flats_status = tk.StringVar(value="")
        theme.label(body, "label.status", textvariable=self.flats_status, anchor="w").pack(fill=tk.X)
        columns = ("block", "number", "type", "template", "device", "status", "last")
        self.flats_tree = ttk.Treeview(body, columns=columns, show="headings", height=8, selectmode="browse")
        for key, (text, width) in {
            "block": ("Blok", 60), "number": ("Daire", 60), "type": ("Tip", 70), "template": ("Şablon", 200),
            "device": ("Kart (UID)", 140), "status": ("Durum", 100), "last": ("Son yazım", 250),
        }.items():
            self.flats_tree.heading(key, text=text)
            self.flats_tree.column(key, width=width, anchor="w")
        self.flats_tree.pack(fill=tk.BOTH, expand=True)

    # ---- sekme 5: şablonlar -----------------------------------------------------------------------------------
    def _build_templates_tab(self) -> None:
        theme = self.theme
        outer = theme.frame(self.tab_templates, "frame.bg", padx=12, pady=10)
        outer.pack(fill=tk.BOTH, expand=True)
        card, body = theme.card(outer, "📐 Kurulum Şablonları (her kayıt yeni sürüm)", accent="violet", padx=10, pady=8)
        card.pack(fill=tk.BOTH, expand=True, pady=(0, 8))
        row = theme.frame(body, "frame.surface")
        row.pack(fill=tk.X, pady=(0, 6))
        theme.label(row, "label.field", text="Site:").pack(side=tk.LEFT)
        self.tpl_scope = ttk.Combobox(row, state="readonly", width=40, values=[GENERAL_SCOPE])
        self.tpl_scope.current(0)
        self.tpl_scope.pack(side=tk.LEFT, padx=6)
        self.tpl_scope.bind("<<ComboboxSelected>>", lambda _e: self.refresh_templates())
        theme.button(row, role="secondary", size="sm", text="🔄 Şablonları Yenile", command=self.refresh_templates).pack(side=tk.LEFT)
        actions = theme.frame(body, "frame.surface")
        actions.pack(fill=tk.X, pady=(0, 6))
        theme.button(actions, role="tint.emerald", size="sm", text="➕ Yeni Şablon", command=self.new_template).pack(side=tk.LEFT)
        theme.button(actions, role="tint.sky", size="sm", text="✏️ Şablonu Düzenle", command=self.edit_template).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="secondary", size="sm", text="📑 Çoğalt", command=self.duplicate_template).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="secondary", size="sm", text="🕘 Sürüm Geçmişi", command=self.show_template_versions).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="danger", size="sm", text="🗑️ Şablonu Sil", command=self.delete_template).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="primary", size="sm", text="💾 Karta Yaz", command=self.write_selected_template).pack(side=tk.LEFT, padx=4)
        theme.button(actions, role="secondary", size="sm", text="📄 Kablolama Şeması (PDF)", command=self.template_wiring_pdf).pack(side=tk.LEFT, padx=4)
        self.tpl_status = tk.StringVar(value="Şablonları görmek için giriş yapıp '🔄 Şablonları Yenile'ye basın.")
        theme.label(body, "label.status", textvariable=self.tpl_status, anchor="w").pack(fill=tk.X)
        columns = ("name", "flat_type", "version", "scope", "updated")
        self.tpl_tree = ttk.Treeview(body, columns=columns, show="headings", height=8, selectmode="browse")
        for key, (text, width) in {
            "name": ("Şablon", 240), "flat_type": ("Daire tipi", 90), "version": ("Sürüm", 70),
            "scope": ("Kapsam", 200), "updated": ("Güncellenme", 150),
        }.items():
            self.tpl_tree.heading(key, text=text)
            self.tpl_tree.column(key, width=width, anchor="w")
        self.tpl_tree.pack(fill=tk.BOTH, expand=True)

        card, body = theme.card(outer, "📋 Karta Yazım Sonucu", accent="emerald", padx=10, pady=8)
        card.pack(fill=tk.BOTH, expand=True)
        result_actions = theme.frame(body, "frame.surface")
        result_actions.pack(fill=tk.X, pady=(0, 6))
        self.btn_send_pending = theme.button(result_actions, role="secondary", size="sm", text="📤 Bekleyen Kayıtları Gönder",
                                             command=self.send_pending_writes)
        self.btn_send_pending.pack(side=tk.LEFT)
        self.btn_ack_alarm = theme.button(result_actions, role="tint.amber", size="sm", text="🔕 Alarmı Onayla (USB)",
                                          command=self.acknowledge_safety_alarm)
        self.btn_ack_alarm.pack(side=tk.LEFT, padx=4)
        self.tpl_log = theme.text(body, "text.log", wrap=tk.WORD, height=7, state=tk.DISABLED)
        self.tpl_log.pack(fill=tk.BOTH, expand=True)

    def _tpl_say(self, text: str) -> None:
        line = self.scrubber.scrub(str(text)) + "\n"
        self.tpl_log.config(state=tk.NORMAL)
        self.tpl_log.insert(tk.END, line)
        self.tpl_log.see(tk.END)
        self.tpl_log.config(state=tk.DISABLED)

    # ---- ortak ----------------------------------------------------------------------------------------------
    def _call_server(self, title: str, work: Callable[[], Any], on_ok: Callable[[Any], None], note: str = "") -> None:
        """Giriş gerektiren sunucu çağrısı: arka planda çalışır, sonuç/hata arayüz iş parçacığında işlenir."""

        def run() -> None:
            def done(result: Any, err: Optional[BaseException]) -> None:
                if err is not None:
                    self._site_error(title, err)
                    return
                on_ok(result)

            self.run_background(work, done)

        self.ensure_login(run, note=note or "Site ve şablon işlemleri için giriş yapın (süper kullanıcı veya servis sorumlusu).")

    def _site_error(self, title: str, err: BaseException) -> None:
        if isinstance(err, ApiError) and err.status == 422 and err.detail:
            self.ui_error(title, "Sunucu şablonu reddetti: " + tm.describe_error(err.detail, err.path or ""))
            return
        if isinstance(err, ApiError) and err.code == "SITE_HAS_DEVICES":
            self.ui_error(title, "Bu sitenin dairelerine bağlı kartlar var; site silinemez. Önce kart bağlantılarını kaldırın.")
            return
        if isinstance(err, ApiError) and err.code in ("DEVICE_NOT_IN_STOCK", "DEVICE_LINKED_TO_FLAT"):
            self.ui_error(title, str(err))
            return
        if isinstance(err, ApiError) and err.code == "INVALID_STATUS_TRANSITION":
            self.ui_error(title, f"{err}\n\nDaire durumu yalnız ileri gider: Planlandı → Yazıldı → Kuruldu → Teslim edildi. 'Kuruldu' "
                          "ve 'Teslim edildi' için daireye kart bağlı olmalı; geri alma yalnız süper kullanıcıya açıktır.")
            return
        if isinstance(err, ApiError) and err.code == "DEVICE_ALREADY_LINKED":
            self.ui_error(title, "Bu kart başka bir daireye bağlı. Önce o dairedeki bağlantıyı kaldırın.")
            return
        self._handle_error(title, err)

    def _selected(self, tree: Any, items: list[dict[str, Any]], what: str) -> Optional[dict[str, Any]]:
        selection = tree.selection()
        if not selection:
            self.ui_info("Seçim Yapın", f"Lütfen önce listeden bir {what} seçin.")
            return None
        try:
            return items[int(selection[0])]
        except (ValueError, IndexError):
            return None

    def _selected_site(self, quiet: bool = False) -> Optional[dict[str, Any]]:
        if quiet and not self.sites_tree.selection():
            return None
        return self._selected(self.sites_tree, self._sites, "site")

    def _site_name(self, site_id: Optional[str]) -> str:
        if not site_id:
            return "Genel"
        site = next((s for s in self._sites if s.get("id") == site_id), None)
        return str(site.get("name")) if site else f"Site {str(site_id)[:8]}"  # site listesi yüklenmemişse kısa kimlik

    # ---- siteler ----
    def refresh_sites(self) -> None:
        self.sites_status.set("⏳ Siteler yükleniyor...")
        self._call_server("Siteler Yüklenemedi", self.client.list_sites, self._on_sites_loaded)

    def _on_sites_loaded(self, sites: Any) -> None:
        selected = self._selected_site(quiet=True)
        self._sites = list(sites or [])
        for row in self.sites_tree.get_children():
            self.sites_tree.delete(row)
        for index, site in enumerate(self._sites):
            place = " / ".join(p for p in (site.get("city"), site.get("district")) if p)
            self.sites_tree.insert("", tk.END, iid=str(index), values=(
                site.get("name", ""), place, site.get("contact_name", ""), site.get("contact_phone", ""),
                site.get("block_count", ""), site.get("flat_count", ""), flat_progress_text(site.get("flat_stats")),
            ))
        self.sites_status.set(f"Toplam {len(self._sites)} site.")
        self.tpl_scope.config(values=[GENERAL_SCOPE] + [str(s.get("name", "")) for s in self._sites])
        if selected is not None:
            index = next((i for i, s in enumerate(self._sites) if s.get("id") == selected.get("id")), None)
            if index is not None:
                self.sites_tree.selection_set(str(index))

    def add_site(self) -> None:
        def run() -> None:
            body = SiteDialog.ask(self, self.theme)
            if body is not None:
                self._call_server("Site Eklenemedi", lambda: self.client.create_site(body),
                                  lambda _r: (self.ui_info("Site Eklendi", f"'{body['name']}' sitesi eklendi."), self.refresh_sites()))

        self.ensure_login(run, note="Site eklemek için giriş yapın.")

    def edit_site(self) -> None:
        site = self._selected_site()
        if site is None:
            return
        body = SiteDialog.ask(self, self.theme, site)
        if body is not None:
            self._call_server("Site Güncellenemedi", lambda: self.client.update_site(site["id"], body),
                              lambda _r: self.refresh_sites())

    def delete_site(self) -> None:
        site = self._selected_site()
        if site is None:
            return
        if not self.ui_confirm("Siteyi Sil", f"'{site.get('name')}' sitesi silinsin mi?\nŞablon sürümleri ve yazım kayıtları korunur; "
                               "dairesine kart bağlı site silinemez."):
            return
        self._call_server("Site Silinemedi", lambda: self.client.delete_site(site["id"]),
                          lambda _r: (self._clear_flats(), self.refresh_sites()))

    # ---- daireler ----
    def _clear_flats(self) -> None:
        self._flats = []
        for row in self.flats_tree.get_children():
            self.flats_tree.delete(row)

    def refresh_flats(self) -> None:
        site = self._selected_site(quiet=True)
        if site is None:
            return
        self.flats_status.set(f"⏳ '{site.get('name')}' daireleri yükleniyor...")
        self._call_server("Daireler Yüklenemedi", lambda: (self.client.list_flats(site["id"]), self.client.list_templates(site["id"])),
                          lambda result: self._on_flats_loaded(site, *result))

    def _on_flats_loaded(self, site: dict[str, Any], flats: list[dict[str, Any]], templates: list[dict[str, Any]]) -> None:
        self._clear_flats()
        self._flats = list(flats or [])
        names = {t.get("id"): t for t in templates or []}
        self._site_templates = list(templates or [])
        for index, flat in enumerate(self._flats):
            tpl = names.get(flat.get("template_id"))
            tpl_text = f"{tpl.get('name')} (v{tpl.get('current_version')})" if tpl else ("-" if not flat.get("template_id") else "(silinmiş şablon)")
            last_text = flat_last_write_text(flat, tpl)
            self.flats_tree.insert("", tk.END, iid=str(index), values=(
                flat.get("block", ""), flat.get("number", ""), flat.get("flat_type", "") or "-", tpl_text,
                flat.get("device_uuid") or "-", FLAT_STATUS_TEXT.get(flat.get("status", ""), flat.get("status", "")), last_text,
            ))
        self.flats_status.set(f"'{site.get('name')}': {len(self._flats)} daire.")

    def bulk_flats(self) -> None:
        site = self._selected_site()
        if site is None:
            return
        templates = getattr(self, "_site_templates", [])
        request = BulkFlatsDialog.ask(self, self.theme, templates)
        if request is None:
            return
        self._call_server(
            "Daireler Üretilemedi",
            lambda: self.client.bulk_create_flats(site["id"], block=request["block"], start=request["start"], end=request["end"],
                                                  flat_type=request["flat_type"], template_id=request["template_id"]),
            lambda created: (self.ui_info("Daireler Üretildi", f"{len(created)} daire eklendi (var olan blok+no atlandı)."),
                             self.refresh_flats()),
        )

    def _selected_flat(self) -> Optional[dict[str, Any]]:
        return self._selected(self.flats_tree, self._flats, "daire")

    def assign_flat_template(self) -> None:
        site, flat = self._selected_site(), None
        if site is None or (flat := self._selected_flat()) is None:
            return
        templates = getattr(self, "_site_templates", [])
        if not templates:
            self.ui_info("Şablon Yok", "Bu site (ya da genel) için şablon yok. '📐 5. Şablonlar' sekmesinden ekleyin.")
            return
        index = ChoiceDialog.ask(self, self.theme, "📐 Şablon Ata", f"{flat_display_name(flat)} için şablon seçin:",
                                 [_template_choice(t) for t in templates])
        if index is None or index < 0:
            return
        template = templates[index]
        fields: dict[str, Any] = {"template_id": template["id"]}
        if not flat.get("flat_type") and template.get("flat_type"):
            fields["flat_type"] = template["flat_type"]
        self._call_server("Şablon Atanamadı", lambda: self.client.update_flat(site["id"], flat["id"], fields),
                          lambda _r: self.refresh_flats())

    def link_flat_device(self) -> None:
        site, flat = self._selected_site(), None
        if site is None or (flat := self._selected_flat()) is None:
            return
        current = flat.get("device_uuid") or ""
        typed = simpledialog.askstring(
            "Kart Bağla", f"{flat_display_name(flat)} dairesine bağlanacak kartın UID'si (AHBU-S3-XXXXXX).\n"
            "Boş bırakırsanız mevcut bağlantı kaldırılır.", initialvalue=current, parent=self)
        if typed is None:
            return
        uid = typed.strip().upper() or None
        if uid and not UID_PATTERN.match(uid):
            self.ui_warn("Geçersiz UID", "Kart UID'si AHBU-S3-XXXXXX biçiminde olmalı.")
            return
        # atolye-7: şablon eski karta yazılmışken kart değişiyorsa yeni karta yeniden yazılmalıdır.
        ok_write = flat.get("last_ok_write") if isinstance(flat.get("last_ok_write"), dict) else {}
        written_uid = str(ok_write.get("device_uuid") or "").upper()
        was_written = bool(ok_write) or flat.get("status") in ("written", "installed", "handed_over")
        needs_rewrite = bool(uid) and was_written and (
            (bool(current) and current.upper() != uid) or (bool(written_uid) and written_uid != uid))

        def linked(_result: Any) -> None:
            self.refresh_flats()
            if needs_rewrite:
                self.ui_warn("Şablon Yeniden Yazılmalı",
                             f"Daireye bağlanan kart ({uid}) şablonun yazıldığı karttan farklı. Şablon yeni karta yeniden "
                             "yazılmalı ('💾 Karta Yaz').")

        self._call_server("Kart Bağlanamadı", lambda: self.client.link_flat_device(site["id"], flat["id"], uid), linked)

    def mark_flat_handed_over(self) -> None:
        """servis_kurulum-10: daireyi 'Teslim edildi' yapar (``PATCH .../flats/:id {status:'handed_over'}``). Araç önce dairenin
        kartı bağlı ve şablonu yazılmış mı ('Yazıldı' ya da 'Kuruldu') diye bakar; değilse hiçbir şey göndermez. Sunucu ayrıca
        yalnız ileri geçişe izin verir ve teslim için kart ister (aksi 409 ``INVALID_STATUS_TRANSITION``, mesaj gösterilir)."""
        site, flat = self._selected_site(), None
        if site is None or (flat := self._selected_flat()) is None:
            return
        status = flat.get("status")
        if status == "handed_over":
            self.ui_info("Teslim Edildi", f"{flat_display_name(flat)} zaten 'Teslim edildi' durumunda.")
            return
        if not flat.get("device_uuid"):
            self.ui_warn("Teslim Edilemez", f"{flat_display_name(flat)} dairesine kart bağlı değil; teslim edilemez. Önce '🔗 Kart "
                         "Bağla' ile kartı bağlayın ve şablonu karta yazın ('💾 Karta Yaz').")
            return
        if status not in ("written", "installed"):
            self.ui_warn("Teslim Edilemez", f"{flat_display_name(flat)} '{FLAT_STATUS_TEXT.get(str(status), str(status))}' "
                         "durumunda: şablon bu dairenin kartına henüz yazılmadı. Önce '💾 Karta Yaz' ile yazın (daire 'Yazıldı' "
                         "olur), sonra teslim edin.")
            return
        if not self.ui_confirm("Teslim Edildi", f"{flat_display_name(flat)} 'Teslim edildi' olarak işaretlensin mi?\n"
                               "(Durum geri alınamaz; geri alma yalnız süper kullanıcıya açıktır.)"):
            return
        self._call_server("Durum Değiştirilemedi", lambda: self.client.update_flat(site["id"], flat["id"], {"status": "handed_over"}),
                          lambda _r: (self.refresh_flats(), self.refresh_sites()))

    def delete_flat(self) -> None:
        site, flat = self._selected_site(), None
        if site is None or (flat := self._selected_flat()) is None:
            return
        if not self.ui_confirm("Daireyi Sil", f"{flat_display_name(flat)} silinsin mi?"):
            return
        self._call_server("Daire Silinemedi", lambda: self.client.delete_flat(site["id"], flat["id"]),
                          lambda _r: self.refresh_flats())

    def write_flat_template(self) -> None:
        site, flat = self._selected_site(), None
        if site is None or (flat := self._selected_flat()) is None:
            return
        if not flat.get("template_id"):
            self.ui_info("Şablon Atanmamış", "Önce '📐 Şablon Ata' ile daireye bir şablon atayın.")
            return
        self._call_server("Şablon Alınamadı", lambda: self.client.get_template(flat["template_id"]),
                          lambda tpl: self.open_template_write(tpl, site=site, flat=flat))

    def flat_wiring_pdf(self) -> None:
        site, flat = self._selected_site(), None
        if site is None or (flat := self._selected_flat()) is None:
            return
        if not flat.get("template_id"):
            self.ui_info("Şablon Atanmamış", "Önce '📐 Şablon Ata' ile daireye bir şablon atayın.")
            return
        self._call_server("Şablon Alınamadı", lambda: self.client.get_template(flat["template_id"]),
                          lambda tpl: self.save_wiring_pdf(_body_of(tpl), site=site, flat=flat))

    # ---- şablonlar ----
    def _scope_site(self) -> Optional[dict[str, Any]]:
        index = self.tpl_scope.current()
        return self._sites[index - 1] if index > 0 and index - 1 < len(self._sites) else None

    def refresh_templates(self) -> None:
        site = self._scope_site()
        self.tpl_status.set("⏳ Şablonlar yükleniyor...")
        self._call_server("Şablonlar Yüklenemedi", lambda: self.client.list_templates(site["id"] if site else None),
                          lambda result: self._on_templates_loaded(result, general_only=site is None))

    def _on_templates_loaded(self, templates: Any, general_only: Optional[bool] = None) -> None:
        """atolye-14: 'Genel' kapsamında yalnız genel (``site_id`` boş) şablonlar listelenir (sunucu da yalnız geneli döndürür)."""
        if general_only is None:
            general_only = self._scope_site() is None
        items = [t for t in (templates or []) if isinstance(t, dict)]
        if general_only:
            items = [t for t in items if not t.get("site_id")]
        self._templates = items
        for row in self.tpl_tree.get_children():
            self.tpl_tree.delete(row)
        for index, tpl in enumerate(self._templates):
            self.tpl_tree.insert("", tk.END, iid=str(index), values=(
                tpl.get("name", ""), tpl.get("flat_type", ""), f"v{tpl.get('current_version', '?')}",
                self._site_name(tpl.get("site_id")), str(tpl.get("updated_at", ""))[:16].replace("T", " "),
            ))
        self.tpl_status.set(f"Toplam {len(self._templates)} şablon.")

    def _selected_template(self) -> Optional[dict[str, Any]]:
        return self._selected(self.tpl_tree, self._templates, "şablon")

    def new_template(self) -> None:
        site = self._scope_site()
        body = tm.new_template("Yeni Şablon", "2+1", site["id"] if site else None)
        self._edit_and_save(body, None, site)

    def edit_template(self) -> None:
        tpl = self._selected_template()
        if tpl is None:
            return
        self._call_server("Şablon Alınamadı", lambda: self.client.get_template(tpl["id"]),
                          lambda full: self._edit_and_save(_body_of(full), tpl["id"], self._scope_site()))

    def duplicate_template(self) -> None:
        tpl = self._selected_template()
        if tpl is None:
            return
        name = simpledialog.askstring("Çoğalt", "Yeni şablonun adı:", initialvalue=f"{tpl.get('name', '')} (kopya)", parent=self)
        if not name or not name.strip():
            return

        def got(full: Any) -> None:
            body = tm.duplicate_template(_body_of(full), name.strip())
            self._save_template(body, None, tpl.get("site_id"))

        self._call_server("Şablon Alınamadı", lambda: self.client.get_template(tpl["id"]), got)

    def delete_template(self) -> None:
        tpl = self._selected_template()
        if tpl is None:
            return
        if not self.ui_confirm("Şablonu Sil", f"'{tpl.get('name')}' şablonu listeden kaldırılsın mı?\nSürümleri ve hangi karta "
                               "yazıldığı kaydı sunucuda KALIR (yumuşak silme)."):
            return
        self._call_server("Şablon Silinemedi", lambda: self.client.delete_template(tpl["id"]), lambda _r: self.refresh_templates())

    def show_template_versions(self) -> None:
        tpl = self._selected_template()
        if tpl is None:
            return

        def show(versions: Any) -> None:
            lines = [f"v{v.get('version')} · {str(v.get('created_at', ''))[:16].replace('T', ' ')} · {v.get('created_by', '')} · "
                     f"SHA-256 {str(v.get('sha256', ''))[:12]}..." for v in versions or []]
            self.ui_info("Sürüm Geçmişi", f"'{tpl.get('name')}' sürümleri (eski sürümler değişmez):\n\n" + ("\n".join(lines) or "Sürüm yok."))

        self._call_server("Sürümler Alınamadı", lambda: self.client.list_template_versions(tpl["id"]), show)

    def _edit_and_save(self, body: dict[str, Any], template_id: Optional[str], site: Optional[dict[str, Any]]) -> None:
        scope = site.get("name") if site else "Genel"
        # atolye-13: açılan gövdenin sürümü base_version olarak gider (başkası bu arada kaydettiyse sunucu 409 TEMPLATE_CHANGED).
        opened = (body.get("meta") or {}).get("version") if isinstance(body, dict) else None
        base_version = opened if template_id and isinstance(opened, int) and not isinstance(opened, bool) else None
        edited = TemplateEditorDialog.ask(self, self.theme, body, scope)
        if edited is not None:
            self._save_template(edited, template_id, edited["meta"].get("site_id"), base_version=base_version)

    def _save_template(self, body: dict[str, Any], template_id: Optional[str], site_id: Optional[str],
                       base_version: Optional[int] = None) -> None:
        """Yerel doğrulama -> ``POST /templates/validate`` -> kaydet (yeni şablon ya da yeni sürüm). ``base_version`` verilirse
        eşzamanlı düzenleme sunucuda yakalanır (409 ``TEMPLATE_CHANGED``): yeni sürümü aç / yine de üstüne yaz seçimi."""
        issue = tm.validate_template(body)
        if issue is not None:
            self.ui_error("Şablon Geçersiz", str(issue))
            return

        def work() -> Any:
            self.client.validate_template_remote(body)
            if template_id:
                return self.client.update_template(template_id, body, base_version=base_version)
            return self.client.create_template(site_id, body)

        def ok(saved: Any) -> None:
            version = saved.get("current_version") if isinstance(saved, dict) else None
            self.ui_info("Şablon Kaydedildi", f"'{body['meta']['name']}' kaydedildi" + (f" (sürüm v{version})." if version else "."))
            self.refresh_templates()

        def run() -> None:
            def done(result: Any, err: Optional[BaseException]) -> None:
                if err is None:
                    ok(result)
                    return
                if isinstance(err, ApiError) and err.status == 409 and err.code == "TEMPLATE_CHANGED" and template_id:
                    self._on_template_changed(body, template_id, site_id, err)
                    return
                self._site_error("Şablon Kaydedilemedi", err)
                if isinstance(err, ApiError) and err.status == 422 and self.ui_confirm(
                        "Düzenlemeye Dön", "Şablonu düzeltmek için düzenleyiciye dönülsün mü? (Değişiklikleriniz korunur.)"):
                    self._save_template_after_edit(body, template_id, site_id, base_version)

            self.run_background(work, done)

        self.ensure_login(run, note="Şablon kaydetmek için giriş yapın.")

    def _save_template_after_edit(self, body: dict[str, Any], template_id: Optional[str], site_id: Optional[str],
                                  base_version: Optional[int]) -> None:
        site = next((s for s in self._sites if s.get("id") == site_id), None)
        edited = TemplateEditorDialog.ask(self, self.theme, body, site.get("name") if site else "Genel")
        if edited is not None:
            self._save_template(edited, template_id, edited["meta"].get("site_id"), base_version=base_version)

    def _on_template_changed(self, body: dict[str, Any], template_id: str, site_id: Optional[str], err: ApiError) -> None:
        """atolye-13: şablon siz düzenlerken başkası kaydetti. Seçim: yeni sürümü aç (sizin değişiklikleriniz kaydedilmez) ya da
        bilerek üstüne yaz (``base_version`` gönderilmez)."""
        current = err.data.get("current_version")
        label = f"v{current}" if isinstance(current, int) else "yeni bir sürüm"
        if self.ui_confirm(
            "Şablon Değişti",
            f"Şablon siz düzenlerken {label} oldu (başka biri kaydetti); sizin değişiklikleriniz KAYDEDİLMEDİ.\n\n"
            f"Yeni sürüm ({label}) düzenleyicide açılsın mı?\n'Hayır' derseniz yine de üstüne yazma seçeneği sorulur.",
        ):
            site = next((s for s in self._sites if s.get("id") == site_id), None)
            self._call_server("Şablon Alınamadı", lambda: self.client.get_template(template_id),
                              lambda full: self._edit_and_save(_body_of(full), template_id, site))
            return
        if self.ui_confirm(
            "Yine de Üstüne Yaz",
            f"Sizin değişiklikleriniz {label} üstüne yeni sürüm olarak yazılsın mı?\n"
            f"UYARI: {label} içindeki (başkasının yaptığı) değişiklikler bu sürümde OLMAZ.",
        ):
            self._save_template(body, template_id, site_id, base_version=None)
            return
        self.ui_info("Kaydedilmedi", "Şablon kaydedilmedi; değişiklikleriniz uygulanmadı.")

    def write_selected_template(self) -> None:
        tpl = self._selected_template()
        if tpl is None:
            return
        self._call_server("Şablon Alınamadı", lambda: self.client.get_template(tpl["id"]),
                          lambda full: self.open_template_write(full, site=self._scope_site(), flat=None))

    def template_wiring_pdf(self) -> None:
        tpl = self._selected_template()
        if tpl is None:
            return
        site = next((s for s in self._sites if s.get("id") == tpl.get("site_id")), None)
        self._call_server("Şablon Alınamadı", lambda: self.client.get_template(tpl["id"]),
                          lambda full: self.save_wiring_pdf(_body_of(full), site=site, flat=None))

    # ---- PDF ----
    def save_wiring_pdf(self, body: dict[str, Any], *, site: Optional[dict[str, Any]], flat: Optional[dict[str, Any]],
                        path: Optional[str] = None, device_uid: Optional[str] = None) -> Optional[str]:
        """Kablolama şeması PDF'i. Başlıkta 'Kart UID' (atolye-15): yazımın yapıldığı kart ya da dairenin bağlı kartı."""
        meta = body.get("meta", {})
        device_uid = device_uid or (flat or {}).get("device_uuid") or None
        base = f"kablolama_{meta.get('name', 'sablon')}_v{meta.get('version', 0)}"
        if flat:
            base += f"_{flat.get('block', '')}-{flat.get('number', '')}"
        safe = re.sub(r"[^A-Za-z0-9._-]+", "_", base.translate(str.maketrans("İıŞşĞğÜüÖöÇç", "IiSsGgUuOoCc")))[:80]
        if path is None:
            path = filedialog.asksaveasfilename(parent=self, title="Kablolama Şemasını Kaydet", defaultextension=".pdf",
                                                filetypes=[("PDF", "*.pdf")], initialfile=safe + ".pdf")
        if not path:
            return None
        try:
            wiring_pdf.save_wiring_pdf(path, body, site_name=(site or {}).get("name", ""),
                                       block=(flat or {}).get("block", ""), number=(flat or {}).get("number", ""),
                                       font_loader=self._pdf_font_loader, device_uid=device_uid)
        except ValueError as exc:
            self.ui_error("Şema Üretilemedi", str(exc))
            return None
        except OSError:
            self.ui_error("Şema Kaydedilemedi", "PDF dosyası yazılamadı (yol/izin sorunu). Başka bir konum seçin.")
            return None
        self.ui_info("Kablolama Şeması Kaydedildi", f"Şema kaydedildi:\n{path}\n\nKartla birlikte sahaya gönderin.")
        return path

    def save_flat_label(self, body: dict[str, Any], *, site: Optional[dict[str, Any]], flat: dict[str, Any],
                        device_uid: str) -> Optional[str]:
        """atolye-15: 'Daire etiketi' (kart UID + site/blok/daire + şablon adı/sürümü; GİZLİ DEĞER İÇERMEZ) PNG olarak kaydedilir.
        Bellekteki cihaz kaydına (aynı oturum) bağlı değildir."""
        meta = body.get("meta", {})
        label = wiring_pdf.build_flat_label(
            device_uid=device_uid, site_name=(site or {}).get("name", ""), block=flat.get("block", ""),
            number=flat.get("number", ""), template_name=str(meta.get("name") or ""), version=meta.get("version"),
            flat_type=str(meta.get("flat_type") or ""), font_loader=self._pdf_font_loader)
        base = f"daire_etiketi_{flat.get('block', '')}-{flat.get('number', '')}_{device_uid}"
        safe = re.sub(r"[^A-Za-z0-9._-]+", "_", base.translate(str.maketrans("İıŞşĞğÜüÖöÇç", "IiSsGgUuOoCc")))[:80]
        path = filedialog.asksaveasfilename(parent=self, title="Daire Etiketini Kaydet", defaultextension=".png",
                                            filetypes=[("PNG Görseli", "*.png")], initialfile=safe + ".png")
        if not path:
            return None
        try:
            label.image.save(path, "PNG", dpi=wiring_pdf.FLAT_LABEL_DPI)
        except (OSError, ValueError):
            self.ui_error("Etiket Kaydedilemedi", "Daire etiketi yazılamadı (yol/izin sorunu). Başka bir konum seçin.")
            return None
        self.ui_info("Daire Etiketi Kaydedildi", f"Daire etiketi kaydedildi (100 x 50 mm; PIN ve parola içermez):\n{path}\n\n"
                     "Dosyayı açıp yazdırın ve dairenin panosuna yapıştırın.")
        return path

    # ---- karta yazım (İP-3.4) ----
    def _port_choices(self) -> list[str]:
        values = list(self.port_combo["values"] or [])
        return [str(v).split(" ")[0] for v in values if "bulunamadı" not in str(v)]

    def open_template_write(self, template: dict[str, Any], *, site: Optional[dict[str, Any]], flat: Optional[dict[str, Any]],
                            request: Optional[TemplateWriteRequest] = None) -> None:
        body = _body_of(template)
        meta = body.get("meta", {})
        target = f"Şablon: {meta.get('name')} v{meta.get('version')} ({meta.get('flat_type')})"
        if flat:
            target += f"\nDaire: {(site or {}).get('name', '')} {flat_display_name(flat)}"
            if flat.get("device_uuid"):
                target += f" · bağlı kart {flat['device_uuid']}"
        label = tm.default_label((site or {}).get("name", "") if flat else "", (flat or {}).get("block", ""),
                                 (flat or {}).get("number", ""), body)
        if request is None:
            ports = self._port_choices()
            preset = self._tpl_preset_port or (self.get_selected_port() or "")
            request = TemplateWriteDialog.ask(self, self.theme, target=target, ports=ports, port=preset, label=label,
                                              device_uid=(flat or {}).get("device_uuid") or "")
        if request is None:
            return
        self.start_template_write(body, request, site=site, flat=flat)

    def _make_template_serial_writer(self) -> TemplateSerialWriter:
        backend = self._get_serial_backend()
        clock = self._serial_clock
        if clock is not None:
            return TemplateSerialWriter(backend, clock=clock.now, sleep=clock.sleep)
        return TemplateSerialWriter(backend)

    def start_template_write(self, body: dict[str, Any], request: TemplateWriteRequest, *,
                             site: Optional[dict[str, Any]] = None, flat: Optional[dict[str, Any]] = None) -> None:
        if self._tpl_busy:
            return
        if request.via == "usb" and (self._esptool_busy or (self._prov_busy and self._prov_mode == "serial")):
            self.ui_info("Meşgul", "Kartla (flash/provizyon) başka bir işlem sürüyor. Bitmesini bekleyin.")
            return
        issue = tm.validate_template(body)
        if issue is not None:
            self.ui_error("Şablon Geçersiz", str(issue))
            return
        try:
            envelope = tm.envelope_bytes(body, request.label)
        except ValueError as exc:
            self.ui_error("Karta Yazılamadı", str(exc))
            return
        meta = body["meta"]
        template_id, version = meta["template_id"], int(meta["version"])
        if template_id == tm.PLACEHOLDER_ID:
            self.ui_warn("Kaydedilmemiş Şablon", "Şablon önce sunucuya kaydedilmeli (sürüm kaydı tutulur).")
            return
        # atolye-6: NC tehlike girişi (gaz/duman/NC su) atölyede boşsa kart yazımdan hemen sonra alarma kilitlenir (fail-safe).
        hazards = tm.nc_hazard_inputs(body)
        if hazards and not self.ui_confirm("NC Tehlike Girişi", tm.nc_hazard_warning(hazards) + "\n\nYazıma devam edilsin mi?"):
            self._tpl_say("Yazım yapılmadı (NC tehlike girişi uyarısı).")
            return
        self._tpl_busy = True
        self._tpl_cancel = cancel = threading.Event()
        if request.via == "usb":
            self.set_ui_state(False)
        self.notebook.select(self.tab_templates)
        self._tpl_say(f"Karta yazım başlıyor: '{meta['name']}' v{version} -> " +
                      (f"USB {request.port}" if request.via == "usb" else f"Ethernet {request.host}"))
        expected_uid = (flat or {}).get("device_uuid") or request.device_uid or None
        say = lambda message: self.post_ui(self._tpl_say, message)  # noqa: E731
        # atolye-10: kartsız daireye USB yazımında kart, STATUS ile tanınınca ve karta hiçbir şey yazılmadan ÖNCE daireye
        # bağlanır; sunucu reddederse (başka daireye bağlı / stokta değil) yazım iptal edilir.
        link_target = (site, flat) if (request.via == "usb" and site and flat and flat.get("id") and not flat.get("device_uuid")) else None
        linked: dict[str, Optional[str]] = {"uid": None}

        def link_to_flat(found_uid: str) -> None:  # arka plan iş parçacığında çalışır
            assert link_target is not None
            target_site, target_flat = link_target
            say(f"Kart {found_uid} tanındı; yazmadan önce {flat_display_name(target_flat)} dairesine bağlanıyor...")
            try:
                self.client.link_flat_device(target_site["id"], target_flat["id"], found_uid)
            except ApiError as exc:
                if exc.code in ("DEVICE_ALREADY_LINKED", "DEVICE_LINKED_TO_FLAT"):
                    raise TemplateWriteError("flat_link_failed", message=(
                        f"Kart {found_uid} başka bir daireye bağlı; şablon yazılmadı. Doğru daireyi seçin ya da kartı önce "
                        "o daireden ayırın.")) from None
                raise TemplateWriteError("flat_link_failed", message=(
                    f"Kart {found_uid} bu daireye bağlanamadı: {exc} Şablon yazılmadı.")) from None
            except FactoryError as exc:  # oturum yok / ağ hatası
                raise TemplateWriteError("flat_link_failed", message=(
                    f"Kart {found_uid} daireye bağlanamadı ({exc}); şablon yazılmadı. Giriş yapıp yeniden deneyin.")) from None
            linked["uid"] = found_uid

        def work() -> Any:
            if request.via == "usb":
                return self._make_template_serial_writer().write(
                    request.port, envelope, template_id=template_id, version=version, label=request.label,
                    expected_uid=expected_uid, progress=say, cancel=cancel,
                    on_identified=link_to_flat if link_target is not None else None,
                    read_safety=bool(hazards), safety_settle_s=tm.nc_hazard_settle_seconds(body))
            writer = TemplateLanWriter(request.host, transport=self._device_transport)
            # Kullanıcı kararı (2026-10-08): kart kablolu Ethernet'ten gelen isteği anahtarsız ve provizyonsuz kabul eder
            # (firmware v1.3.0, netlink::requestViaEth) -> sunucudan anahtar ALINMAZ; başlık yalnız biçim gereği gönderilir.
            return writer.write(ETH_NO_KEY, envelope, template_id=template_id, version=version, label=request.label,
                                device_uid=request.device_uid, progress=say)

        self.run_background(work, lambda outcome, err: self._on_template_written(body, request, site, flat, outcome, err,
                                                                                 linked_uid=linked["uid"]))

    def _on_template_written(self, body: dict[str, Any], request: TemplateWriteRequest, site: Optional[dict[str, Any]],
                             flat: Optional[dict[str, Any]], outcome: Any, err: Optional[BaseException], *,
                             linked_uid: Optional[str] = None) -> None:
        self._tpl_busy = False
        if request.via == "usb":
            self.set_ui_state(True)
        meta = body["meta"]
        uid = ((outcome.device_uid if outcome is not None else None) or getattr(err, "device_uid", None) or request.device_uid
               or (flat or {}).get("device_uuid"))
        if err is not None:
            if isinstance(err, SerialUnavailableError):
                err = TemplateWriteError("unexpected", message="USB (seri) bu bilgisayarda kullanılamıyor: " + str(err))
            elif isinstance(err, ProvisionError):  # bağlantı/port sorunu (seri altyapının ortak hataları)
                err = TemplateWriteError(err.code or "no_response", message=err.message + (f"\n{err.hint}" if err.hint else ""))
            text = self._error_text(err)
            self._tpl_say("❌ " + text)
            if isinstance(err, TemplateWriteError) and uid and err.code not in ("cancelled", "unreachable", "mac_mismatch",
                                                                                 "flat_link_failed"):
                self._record_write(uid, meta, request.via, "error", flat, err.code)
            self.ui_error("Karta Yazılamadı", text)
            return
        self._tpl_say(f"✅ Şablon karta yazıldı ve geri okundu: {outcome.template_id} v{outcome.version} "
                      f"(kart {outcome.device_uid or '-'}, yol {outcome.via.upper()}).")
        if linked_uid:
            self._tpl_say(f"Kart {linked_uid} {flat_display_name(flat or {})} dairesine bağlandı (yazımdan önce).")
        if request.via == "usb" and tm.nc_hazard_inputs(body):  # atolye-6: yazımdan sonra SAFETY okundu (read_safety)
            latched = [int(zone) for zone in (getattr(outcome, "latched_zones", None) or [])]
            faults = [int(zone) for zone in (getattr(outcome, "fault_zones", None) or [])]
            if not getattr(outcome, "safety_checked", False):
                self._report_unread_safety(request.port)
            elif latched or faults:
                self._report_latched_alarm(request.port, latched, faults)
        info = tm.flat_info_line((flat or {}).get("block", ""), (flat or {}).get("number", ""), meta.get("flat_type", ""),
                                 meta.get("version")) if flat else ""
        if info and outcome.device_uid:
            self._apply_flat_info_to_label(outcome.device_uid, info)

        def after_record(record_status: str) -> None:
            if (flat and not flat.get("device_uuid") and not linked_uid and outcome.device_uid and site and self.ui_confirm(
                    "Kartı Daireye Bağla", f"Kart {outcome.device_uid}, {flat_display_name(flat)} dairesine bağlansın mı?")):
                self._call_server("Kart Bağlanamadı",
                                  lambda: self.client.link_flat_device(site["id"], flat["id"], outcome.device_uid),
                                  lambda _r: self.refresh_flats())
            if self.ui_confirm("Şablon Karta Yazıldı",
                               f"'{meta['name']}' v{meta['version']} karta yazıldı ve doğrulandı.\nYazım kaydı: {record_status}\n\n"
                               "Kablolama şeması (PDF) şimdi kaydedilsin mi? Şemayı kartla birlikte sahaya gönderin."):
                self.save_wiring_pdf(body, site=site, flat=flat, device_uid=outcome.device_uid)
            if flat and outcome.device_uid and self.ui_confirm(
                    "Daire Etiketi", f"{flat_display_name(flat)} için daire etiketi (kart {outcome.device_uid}, site/blok/daire, "
                    f"şablon v{meta['version']}; PIN ve parola İÇERMEZ) kaydedilsin mi?"):
                self.save_flat_label(body, site=site, flat=flat, device_uid=outcome.device_uid)

        if outcome.device_uid:
            self._record_write(outcome.device_uid, meta, outcome.via, "ok", flat, None, on_done=after_record)
        else:
            after_record("kart UID'si bilinmediği için kaydedilmedi")

    # ---- atolye-6: atölyede kilitlenen güvenlik bölgesi --------------------------------------------------------------
    @staticmethod
    def _fault_zone_text(faults: list[int]) -> str:
        """FAULT bölgesi (firmware: ack() onaylar ama canClear() yalnız LATCHED bölgeyi temizler)."""
        return (f"Bölge {', '.join(str(z) for z in faults)} vana ARIZASINDA (FAULT: geri bildirimli vana 'kapalı' görülmedi): "
                "alarm onayı (SAFETY ACK) bu bölgeyi temizlemez. Vanayı ve kapalı-konum geri bildirim kablosunu bağlayın; vana "
                "KAPALI görülünce bölge 'kilitli' olur, sonra '🔕 Alarmı Onayla (USB)'ya yeniden basın.")

    def _report_unread_safety(self, port: str) -> None:
        """NC tehlike girişli şablon yazıldı ama SAFETY okunamadı: bölgelerin durumu BİLİNMİYOR (normal sayılmaz)."""
        self._last_latched = {"port": port, "zones": [0]}
        text = ("Şablon karta yazıldı ama kartın güvenlik durumu (SAFETY) okunamadı: NC tehlike girişli bölge alarma geçip "
                "kilitlenmiş olabilir (vana kapanmış, siren çalıyor olabilir). Girişi DI-GND köprüleyin ya da dedektörü bağlayın, "
                "sonra '🔕 Alarmı Onayla (USB)' ile kontrol edin.")
        self._tpl_say("⚠ " + text)
        self.ui_warn("Güvenlik Durumu Okunamadı", text)

    def _report_latched_alarm(self, port: str, zones: list[int], faults: Optional[list[int]] = None) -> None:
        faults = list(faults or [])
        pending = sorted(set(zones) | set(faults))
        self._last_latched = {"port": port, "zones": pending}
        acks = " ve ".join(f"SAFETY ACK {zone}" for zone in pending)
        parts = []
        if zones:
            latched_acks = " ve ".join(f"SAFETY ACK {zone}" for zone in zones)
            parts.append(f"Kart şablonu uyguladı ama Bölge {', '.join(str(z) for z in zones)} alarma geçip KİLİTLENDİ: atölyede NC "
                         "tehlike girişi boş (vana kapandı, siren çalıyor olabilir). Firmware bunu bilerek yapar (fail-safe).\n"
                         f"Köprüleyin ve {latched_acks} gönderin: girişi DI-GND köprüleyin ya da dedektörü bağlayın, sonra "
                         "'🔕 Alarmı Onayla (USB)'ya basın (kuruluk bekleme süresi dolunca bölge normale döner).")
        if faults:
            parts.append(self._fault_zone_text(faults))
        text = "\n".join(parts)
        self._tpl_say("⚠ " + text)
        self.ui_warn("Alarm Kilitlendi (Atölye)", text)
        if self.ui_confirm("Alarmı Onayla", f"Girişleri köprülediyseniz alarm şimdi onaylansın mı ({acks})?\n"
                           "'Hayır' derseniz köprüledikten sonra '🔕 Alarmı Onayla (USB)' düğmesini kullanın."):
            self.acknowledge_safety_alarm()

    def acknowledge_safety_alarm(self) -> None:
        """'🔕 Alarmı Onayla (USB)': son yazımda kilitlenen bölgelere (yoksa 0 = bütün bölgeler) seri ``SAFETY ACK`` gönderir ve
        ``SAFETY`` ile sonucu okur. Firmware'in fail-safe davranışı değişmez (giriş kuru olmadan bölge temizlenmez)."""
        last = self._last_latched or {}
        port = last.get("port") or self._tpl_preset_port or self.get_selected_port()
        zones = [int(zone) for zone in (last.get("zones") or [0])]
        if not port:
            self.ui_warn("Port Seçilmedi", "USB portu seçin (1. sekmede 'Portları Yenile').")
            return
        if self._tpl_busy or self._esptool_busy or (self._prov_busy and self._prov_mode == "serial"):
            self.ui_info("Meşgul", "Kartla (flash/provizyon/yazım) başka bir işlem sürüyor. Bitmesini bekleyin.")
            return
        self._tpl_busy = True
        self.set_ui_state(False)
        acks = ", ".join(f"SAFETY ACK {zone}" for zone in zones)
        self._tpl_say(f"Alarm onayı gönderiliyor ({port}: {acks})...")
        say = lambda message: self.post_ui(self._tpl_say, message)  # noqa: E731

        def work() -> Any:
            return self._make_template_serial_writer().acknowledge_alarm(port, zones, progress=say)

        def done(summary: Any, err: Optional[BaseException]) -> None:
            self._tpl_busy = False
            self.set_ui_state(True)
            if err is not None:
                text = (f"{err.message}\n{err.hint}" if isinstance(err, ProvisionError) and err.hint else self._error_text(err))
                self._tpl_say("❌ Alarm onayı gönderilemedi: " + text)
                self.ui_error("Alarm Onaylanamadı", text)
                return
            if not getattr(summary, "seen", False):  # SAFETY başlığı gelmedi: durum BİLİNMİYOR, "normal" denmez
                text = ("Alarm onayı gönderildi ama kartın güvenlik durumu (SAFETY) okunamadı: bölgelerin normale döndüğü "
                        "DOĞRULANAMADI. USB bağlantısını kontrol edip '🔕 Alarmı Onayla (USB)'ya yeniden basın.")
                self._tpl_say("⚠ " + text)
                self.ui_warn("Güvenlik Durumu Okunamadı", text)
                return
            latched, faults = list(summary.latched), list(summary.faults)
            if latched or faults:
                self._last_latched = {"port": port, "zones": sorted(set(latched) | set(faults))}
                parts = []
                if latched:
                    parts.append(f"Onay gönderildi ama Bölge {', '.join(str(z) for z in latched)} hâlâ kilitli. Giriş köprülü mü / "
                                 "dedektör bağlı mı? Kuruluk bekleme süresi dolunca bölge normale döner; sonra '🔕 Alarmı Onayla "
                                 "(USB)'ya yeniden basın.")
                if faults:
                    parts.append(self._fault_zone_text(faults))
                text = "\n".join(parts)
                self._tpl_say("⚠ " + text)
                self.ui_warn("Alarm Sürüyor", text)
                return
            self._last_latched = None
            self._tpl_say("✅ Alarm onaylandı; güvenlik bölgeleri normal (SAFETY).")
            self.ui_info("Alarm Onaylandı", "Güvenlik bölgeleri normal (SAFETY: kilitli ya da arızalı bölge yok).")

        self.run_background(work, done)

    # ---- atolye-11: yazım kayıtları kaybolmaz (bekleyen kuyruk) ----------------------------------------------------
    def _record_write(self, uid: str, meta: dict[str, Any], via: str, result: str, flat: Optional[dict[str, Any]],
                      code: Optional[str], on_done: Optional[Callable[[str], None]] = None) -> None:
        """Yazım kaydı önce bellekteki bekleyen kuyruğa girer, sonra gönderilir; gönderilemezse (oturum yok / ağ / sunucu)
        kuyrukta kalır ve '📤 Bekleyen Kayıtları Gönder' ile yeniden gönderilir. ``on_done(durum metni)`` sonuçla çağrılır."""
        self._write_seq += 1
        self._pending_writes.append({
            "seq": self._write_seq, "uid": uid, "template_id": meta["template_id"], "version": int(meta["version"]), "via": via,
            "result": result, "flat_id": (flat or {}).get("id"), "error_code": code,
        })
        self._flush_pending_writes(on_done=on_done, focus_seq=self._write_seq)

    def send_pending_writes(self) -> None:
        """'📤 Bekleyen Kayıtları Gönder' düğmesi."""
        if not self._pending_writes:
            self.ui_info("Bekleyen Kayıt Yok", "Sunucuya gönderilmeyi bekleyen yazım kaydı yok.")
            return
        count = len(self._pending_writes)
        self._flush_pending_writes(on_done=lambda status: self._tpl_say(f"Bekleyen {count} yazım kaydı: {status}."))

    def _flush_pending_writes(self, on_done: Optional[Callable[[str], None]] = None, focus_seq: Optional[int] = None) -> None:
        """Bekleyen yazım kayıtlarını gönderir. Kalıcı ret (``write_record_rejected``) kuyruktan çıkarılır ve bir kez bildirilir;
        geçici hata kuyrukta kalır. ``on_done(durum)``: ``focus_seq`` verilirse o kaydın, yoksa bütün gönderimin durumu."""
        if not self._pending_writes:
            if on_done is not None:
                on_done("sunucuya işlendi")
            return
        if not self.client.is_authenticated:
            self.ensure_login(lambda: self._flush_pending_writes(on_done=on_done, focus_seq=focus_seq),
                              note="Yazım kaydını sunucuya işlemek için giriş yapın (süper kullanıcı ya da servis sorumlusu).")
            if not self.client.is_authenticated and not getattr(self, "_login_busy", False) and not getattr(self, "_restoring", False):
                text = (f"Yazım kaydı işlenemedi: sunucu oturumu yok ({len(self._pending_writes)} kayıt bekliyor). Giriş yapıp "
                        "'📤 Bekleyen Kayıtları Gönder'e basın.")
                self._tpl_say("⚠ " + text)
                self.ui_warn("Yazım Kaydı Bekliyor", text)
                if on_done is not None:
                    on_done("işlenemedi (oturum yok), bekliyor")
            return
        if self._flushing_writes:
            if on_done is not None:
                on_done("gönderiliyor (önceki gönderim sürüyor)")
            return
        self._flushing_writes = True
        batch = list(self._pending_writes)

        def work() -> Any:
            results: list[tuple[dict[str, Any], Any, Optional[BaseException]]] = []
            for entry in batch:
                try:
                    reply = self.client.record_template_write(
                        device_uuid=entry["uid"], template_id=entry["template_id"], version=entry["version"], via=entry["via"],
                        result=entry["result"], flat_id=entry["flat_id"], error_code=entry["error_code"])
                except FactoryError as exc:
                    results.append((entry, None, exc))
                    if isinstance(exc, SessionExpiredError):
                        break  # oturum kapandı: kalanlar kuyrukta bekler
                else:
                    results.append((entry, reply, None))
            return results

        def done(results: Any, err: Optional[BaseException]) -> None:
            self._flushing_writes = False
            if err is not None:
                results = [(entry, None, err) for entry in batch]
            failure: Optional[BaseException] = None
            rejected: list[tuple[dict[str, Any], BaseException]] = []
            state_of: dict[int, str] = {}
            refresh = False
            for entry, reply, exc in results or []:
                if exc is not None:
                    if write_record_rejected(exc):  # kalıcı ret: yeniden göndermek sonucu değiştirmez
                        self._pending_writes = [item for item in self._pending_writes if item["seq"] != entry["seq"]]
                        rejected.append((entry, exc))
                        state_of[entry["seq"]] = RECORD_REJECTED_STATUS
                    else:
                        failure = failure or exc
                    continue
                state_of[entry["seq"]] = "sunucuya işlendi"
                self._pending_writes = [item for item in self._pending_writes if item["seq"] != entry["seq"]]
                self._tpl_say(f"Yazım kaydı sunucuya işlendi (template-writes; kart {entry['uid']}, v{entry['version']}).")
                refresh = refresh or bool(entry["flat_id"] and entry["result"] == "ok")
                if isinstance(reply, dict) and reply.get("warning") == "DEVICE_LINKED_ELSEWHERE":
                    other = str(reply.get("linked_flat_id") or "?")[:8]
                    self.ui_error("Kart Başka Daireye Bağlı",
                                  f"Yazım kaydı işlendi ama kart {entry['uid']} başka bir daireye bağlı (daire {other}…); seçili "
                                  "dairenin durumu DEĞİŞMEDİ. Doğru daireye yazdığınızdan emin olun; gerekirse kartı o daireden "
                                  "ayırıp bu daireye bağlayın.")
            if refresh:
                self.refresh_flats()
            status = "sunucuya işlendi"
            if rejected:
                lines = []
                for entry, exc in rejected:
                    code = getattr(exc, "code", None) or "-"
                    http = f"HTTP {exc.status} " if isinstance(exc, ApiError) and exc.status else ""
                    lines.append(f"• kart {entry['uid']}, şablon v{entry['version']} ({str(entry['via']).upper()}, "
                                 f"{'başarılı' if entry['result'] == 'ok' else 'hatalı'} yazım): {http}{code} - {self._error_text(exc)}")
                text = ("Sunucu yazım kaydını kalıcı olarak reddetti; kayıt bekleyen kuyruktan çıkarıldı (yeniden gönderilmez):\n"
                        + "\n".join(lines))
                self._tpl_say("❌ " + text)
                self.ui_error("Yazım Kaydı Reddedildi", text)
                status = RECORD_REJECTED_STATUS
            if failure is not None:
                if isinstance(failure, SessionExpiredError):
                    self.update_session_bar()
                text = (f"Yazım kaydı işlenemedi: {self._error_text(failure)}\n{len(self._pending_writes)} kayıt bekliyor; "
                        "'📤 Bekleyen Kayıtları Gönder' ile yeniden gönderin.")
                self._tpl_say("⚠ " + text)
                self.ui_warn("Yazım Kaydı İşlenemedi", text)
                status = RECORD_PENDING_STATUS
            if focus_seq is not None:  # bu yazımın kendi kaydı (kuyruktaki eski kayıtların sonucu karıştırılmaz)
                status = state_of.get(focus_seq, RECORD_PENDING_STATUS)
            if on_done is not None:
                on_done(status)

        self.run_background(work, done)

    def template_after_provision(self) -> None:
        """Provizyon sonrası (aynı USB portu): Şablonlar sekmesine geçer; '💾 Karta Yaz' penceresinde port hazır gelir."""
        self._tpl_preset_port = self._flash_port or self.get_selected_port()
        self.notebook.select(self.tab_templates)
        self.ui_info("Şablon Yaz", "Şablonu (ya da 4. sekmede daireyi) seçip '💾 Karta Yaz'a basın; USB portu "
                     f"{self._tpl_preset_port or '(seçili port)'} hazır gelir.")
        if self.client.is_authenticated:
            self.refresh_templates()


def _body_of(template: Any) -> dict[str, Any]:
    """``GET /templates/:id`` yanıtından şablon gövdesi (``{..., body}`` ya da doğrudan gövde)."""
    if isinstance(template, dict) and isinstance(template.get("body"), dict):
        return template["body"]
    return template if isinstance(template, dict) else {}


__all__ = [
    "BulkFlatsDialog",
    "ChoiceDialog",
    "DimmerDialog",
    "SiteDialog",
    "SiteTemplateTabsMixin",
    "TemplateEditorDialog",
    "TemplateWriteDialog",
    "TemplateWriteRequest",
    "flat_progress_text",
    "validate_site_form",
]
