# -*- coding: utf-8 -*-
"""
"Neon Glass" teması - AHBU servis/üretim aracı (Tk + ttk) için renk belirteçleri, ttk stili ve widget rolleri.

Flutter uygulamasının tasarım dili (docs/superpowers/analysis/gorsel-tasarim-v2.md) Tk/ttk sınırları içinde uyarlanır:
koyu lacivert zemin, camsı (rim ışıklı) kart yüzeyleri, anlamsal vurgu aileleri (sky/cyan/emerald/amber/rose/violet),
düz dolgulu + kalın etiketli, hover'da bir ton açılan düğmeler, koyu monospace günlük alanı.

Tek doğruluk kaynağı: ``FAMILIES`` + ``build_palette(name)`` (tüm renkler burada; arayüz dosyasında sabit renk yoktur).

* Koyu tema varsayılan; açık tema seçeneği. Tercih ``%APPDATA%/AHBU/servis_araci_ayarlar.json`` (Windows) ya da
  ``~/.config/ahbu/servis_araci_ayarlar.json`` dosyasında saklanır; ``EV_TOOL_THEME=dark|light`` ortam değişkeni dosyayı
  geçersiz kılar (QA/ekran görüntüsü için). Dosyada yalnızca görünüm tercihi bulunur; gizli bilgi YAZILMAZ.
* Kontrast: metin/zemin çiftleri WCAG 2.x oranıyla hesaplanır (``contrast_ratio``); ``python tool_theme.py --check``
  her iki tema için tabloyu yazdırır ve 4.5:1 altını işaretler.
* Widget'lar ``ThemeManager.register(widget, rol)`` ile kaydedilir; tema değişince hepsi yeniden boyanır.

Bu modül ağ/donanım/iş mantığı içermez (``factory_client.py`` ile ilişkisi yoktur).
"""

from __future__ import annotations

import json
import os
import sys
import threading
import tkinter as tk
from tkinter import font as tkfont
from tkinter import ttk
from typing import Any, Callable, Optional

THEME_DARK = "dark"
THEME_LIGHT = "light"
THEMES = (THEME_DARK, THEME_LIGHT)
ENV_THEME = "EV_TOOL_THEME"
PREFERENCE_KEY = "theme"

# ---------------------------------------------------------------------------------------------------------------
# Renk yardımcıları
# ---------------------------------------------------------------------------------------------------------------
def _hex_to_rgb(color: str) -> tuple[int, int, int]:
    value = color.lstrip("#")
    return int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)


def _rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    return "#%02X%02X%02X" % tuple(max(0, min(255, int(round(channel)))) for channel in rgb)


def blend(top: str, bottom: str, alpha: float) -> str:
    """``top`` rengini ``bottom`` üzerine ``alpha`` (0-1) saydamlıkla bindirir (cam/tint yüzeyler için)."""
    t, b = _hex_to_rgb(top), _hex_to_rgb(bottom)
    return _rgb_to_hex(tuple(b[i] + (t[i] - b[i]) * alpha for i in range(3)))


def relative_luminance(color: str) -> float:
    def channel(value: int) -> float:
        c = value / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = _hex_to_rgb(color)
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast_ratio(foreground: str, background: str) -> float:
    """WCAG 2.x kontrast oranı (1.0 - 21.0)."""
    lf, lb = relative_luminance(foreground), relative_luminance(background)
    light, dark = max(lf, lb), min(lf, lb)
    return (light + 0.05) / (dark + 0.05)


def readable_ink(background: str, light: str = "#FFFFFF", dark: str = "#0B1120") -> str:
    """Verilen zemin üzerinde daha yüksek kontrastlı mürekkebi (beyaz / koyu) seçer."""
    return light if contrast_ratio(light, background) >= contrast_ratio(dark, background) else dark


# ---------------------------------------------------------------------------------------------------------------
# Belirteçler (tek yer)
# ---------------------------------------------------------------------------------------------------------------
# Vurgu aileleri (şartname §2.1): light / base / deep. "solid": beyaz metinle >= 4.5:1 veren düğme dolgusu.
FAMILIES: dict[str, dict[str, str]] = {
    "sky":     {"light": "#93C5FD", "base": "#3B82F6", "deep": "#1D4ED8", "solid": "#2563EB"},
    "cyan":    {"light": "#A5F3FC", "base": "#22D3EE", "deep": "#0E7490", "solid": "#0E7490"},
    "emerald": {"light": "#6EE7B7", "base": "#10B981", "deep": "#047857", "solid": "#047857"},
    "amber":   {"light": "#FFD36B", "base": "#FFB020", "deep": "#E07A00", "solid": "#B45309"},
    "rose":    {"light": "#FDA4AF", "base": "#F43F5E", "deep": "#BE123C", "solid": "#BE123C"},
    "violet":  {"light": "#D8B4FE", "base": "#A855F7", "deep": "#7E22CE", "solid": "#7E22CE"},
    "slate":   {"light": "#CBD5E1", "base": "#64748B", "deep": "#334155", "solid": "#334155"},
}
# Açık temada kart üzerinde okunabilir (>= 4.5:1) vurgu metin renkleri (deep yetmeyen aileler koyulaştırıldı).
_LIGHT_READABLE = {
    "sky": "#1D4ED8", "cyan": "#155E75", "emerald": "#047857", "amber": "#9A3412",
    "rose": "#BE123C", "violet": "#6B21A8", "slate": "#334155",
}

FONT_FAMILY_CANDIDATES = ("Segoe UI", "Noto Sans", "DejaVu Sans", "Helvetica")
MONO_FAMILY_CANDIDATES = ("Cascadia Mono", "Consolas", "DejaVu Sans Mono", "Courier New")

# Terminal (günlük) alanı her iki temada da koyudur (şartname: monospace, koyu, renkli satır etiketleri).
_TERMINAL = {
    "log_bg": "#070B14",
    "log_fg": "#CBD5E1",
    "log_ok": FAMILIES["emerald"]["light"],
    "log_err": FAMILIES["rose"]["light"],
    "log_warn": FAMILIES["amber"]["light"],
    "log_info": FAMILIES["sky"]["light"],
    "log_muted": "#8293AD",
    "log_cursor": "#F8FAFC",
    "log_border": "#1E2A44",
}


def build_palette(name: str) -> dict[str, Any]:
    """Tema adına göre düz belirteç sözlüğü üretir (``dark`` / ``light``)."""
    if name not in THEMES:
        raise ValueError(f"bilinmeyen tema: {name!r}")
    dark = name == THEME_DARK
    header_bg = "#0E1830"          # marka şeridi her iki temada lacivert (devre kartı kimliği)
    if dark:
        bg = "#0B1120"
        surface = "#172238"
        tokens: dict[str, Any] = {
            "name": name,
            "bg": bg,
            "surface": surface,
            "surface_alt": blend("#FFFFFF", surface, 0.05),
            "surface_rim": blend("#FFFFFF", surface, 0.16),
            "surface_rim_light": blend("#FFFFFF", surface, 0.28),
            "input_bg": "#0D1527",
            "input_border": "#55637D",
            "text": "#F1F5F9",
            "text_muted": "#94A3B8",
            "text_subtle": "#8293AD",
            "text_on_accent": "#FFFFFF",
            "focus_ring": FAMILIES["cyan"]["base"],
            "selection_bg": FAMILIES["sky"]["solid"],
            "selection_fg": "#FFFFFF",
            "header_bg": header_bg,
            "header_line": blend(FAMILIES["cyan"]["base"], header_bg, 0.55),
            "session_bg": "#121D36",
            "tab_bg": "#121B30",
            "tab_fg": "#A3B0C5",
            "tab_hover_bg": "#1B2640",
            "tab_sel_bg": surface,
            "tab_sel_fg": "#F8FAFC",
            "tab_indicator": FAMILIES["cyan"]["base"],
            "tree_bg": "#0D1527",
            "tree_fg": "#E2E8F0",
            "tree_head_bg": "#1B2740",
            "tree_head_fg": "#CBD5E1",
            "tree_sel_bg": FAMILIES["sky"]["deep"],
            "tree_sel_fg": "#FFFFFF",
            "scroll_trough": "#0D1527",
            "scroll_thumb": "#2E3A52",
            "scroll_thumb_active": "#3E4C68",
            "scroll_arrow": "#94A3B8",
            "check_select": "#0D1527",
            "button_secondary_bg": blend("#FFFFFF", surface, 0.09),
            "button_secondary_hover": blend("#FFFFFF", surface, 0.16),
            "button_secondary_pressed": blend("#FFFFFF", surface, 0.04),
            "button_secondary_fg": "#E2E8F0",
            "button_secondary_border": blend("#FFFFFF", surface, 0.22),
            "button_disabled_fg": "#7C8AA3",
            "tint_alpha": 0.18,
            "tint_hover_alpha": 0.30,
            "tint_pressed_alpha": 0.12,
            "tint_border_alpha": 0.50,
        }
        for family, shades in FAMILIES.items():
            tokens[f"accent_{family}"] = shades["base"]
            tokens[f"accent_{family}_text"] = shades["light"]      # kart/zemin üzerinde okunabilir metin
            tokens[f"accent_{family}_solid"] = shades["solid"]
    else:
        bg = "#EEF2F7"
        surface = "#FFFFFF"
        tokens = {
            "name": name,
            "bg": bg,
            "surface": surface,
            "surface_alt": "#F5F7FB",
            "surface_rim": "#D3DAE6",
            "surface_rim_light": "#FFFFFF",
            "input_bg": "#FFFFFF",
            "input_border": "#7F8DA5",
            "text": "#0F172A",
            "text_muted": "#475569",
            "text_subtle": "#5B6B84",
            "text_on_accent": "#FFFFFF",
            "focus_ring": FAMILIES["cyan"]["deep"],
            "selection_bg": FAMILIES["sky"]["solid"],
            "selection_fg": "#FFFFFF",
            "header_bg": header_bg,
            "header_line": blend(FAMILIES["cyan"]["base"], header_bg, 0.55),
            "session_bg": "#142040",
            "tab_bg": "#DFE5EE",
            "tab_fg": "#3F4F66",
            "tab_hover_bg": "#EAEFF6",
            "tab_sel_bg": surface,
            "tab_sel_fg": "#0F172A",
            "tab_indicator": "#0891B2",
            "tree_bg": "#FFFFFF",
            "tree_fg": "#0F172A",
            "tree_head_bg": "#E6EBF3",
            "tree_head_fg": "#1E293B",
            "tree_sel_bg": FAMILIES["sky"]["solid"],
            "tree_sel_fg": "#FFFFFF",
            "scroll_trough": "#E6EBF3",
            "scroll_thumb": "#B4BFD0",
            "scroll_thumb_active": "#8E9BB1",
            "scroll_arrow": "#334155",
            "check_select": "#FFFFFF",
            "button_secondary_bg": "#FFFFFF",      # zemin (#EEF2F7) üzerinde de seçilsin: beyaz dolgu + kenar
            "button_secondary_hover": "#E8EDF5",
            "button_secondary_pressed": "#D5DCE8",
            "button_secondary_fg": "#1E293B",
            "button_secondary_border": "#AEB9CB",
            "button_disabled_fg": "#8A96AA",
            "tint_alpha": 0.13,
            "tint_hover_alpha": 0.22,
            "tint_pressed_alpha": 0.09,
            "tint_border_alpha": 0.45,
        }
        for family, shades in FAMILIES.items():
            tokens[f"accent_{family}"] = shades["base"]
            tokens[f"accent_{family}_text"] = _LIGHT_READABLE[family]
            tokens[f"accent_{family}_solid"] = shades["solid"]

    # Her iki temada ortak türetilmiş belirteçler
    tokens.update(_TERMINAL)
    tokens["header_fg"] = "#F8FAFC"
    tokens["header_sub"] = "#A3B0C5"
    tokens["header_brand"] = "#67E8F9"           # marka: camgöbeği (teknoloji vurgusu)
    tokens["badge_bg"] = blend("#FFFFFF", tokens["session_bg"], 0.10)
    tokens["badge_fg"] = "#DCE3EE"
    tokens["badge_border"] = blend("#FFFFFF", tokens["session_bg"], 0.22)
    for family in ("emerald", "amber", "rose", "sky", "cyan"):
        tokens[f"badge_{family}_bg"] = blend(FAMILIES[family]["base"], tokens["session_bg"], 0.20)
        tokens[f"badge_{family}_fg"] = FAMILIES[family]["light"]
    tokens["primary_bg"] = FAMILIES["sky"]["solid"]
    tokens["primary_hover"] = FAMILIES["sky"]["base"]
    tokens["primary_pressed"] = FAMILIES["sky"]["deep"]
    tokens["primary_fg"] = "#FFFFFF"
    tokens["danger_bg"] = FAMILIES["rose"]["deep"]
    tokens["danger_hover"] = "#E11D48"
    tokens["danger_pressed"] = "#9F1239"
    tokens["danger_fg"] = "#FFFFFF"
    tokens["switch_on_bg"] = blend(FAMILIES["cyan"]["base"], tokens["session_bg"], 0.26)
    return tokens


# ---------------------------------------------------------------------------------------------------------------
# Tercih deposu (yalnızca görünüm ayarı; gizli bilgi yazılmaz)
# ---------------------------------------------------------------------------------------------------------------
def preferences_path() -> str:
    """Tercih dosyasının yolu: Windows'ta %APPDATA%/AHBU, diğerlerinde ~/.config/ahbu."""
    if os.name == "nt":
        base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, "AHBU", "servis_araci_ayarlar.json")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "ahbu", "servis_araci_ayarlar.json")


def _read_preferences(path: str) -> dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def load_theme_preference(path: Optional[str] = None) -> str:
    """Tema tercihi: ``EV_TOOL_THEME`` ortam değişkeni > tercih dosyası > koyu tema."""
    env_value = os.environ.get(ENV_THEME, "").strip().lower()
    if env_value in THEMES:
        return env_value
    value = _read_preferences(path or preferences_path()).get(PREFERENCE_KEY)
    return value if value in THEMES else THEME_DARK


_PREFERENCES_LOCK = threading.RLock()


def read_preferences(path: Optional[str] = None) -> dict[str, Any]:
    """Tercih dosyasının tamamı (yoksa/bozuksa boş sözlük)."""
    with _PREFERENCES_LOCK:
        return _read_preferences(path or preferences_path())


def update_preferences(
    updates: Optional[dict[str, Any]] = None,
    *,
    remove: tuple[str, ...] = (),
    path: Optional[str] = None,
) -> bool:
    """Tercih dosyasını KİLİTLİ ve atomik günceller (okuma-değiştirme-yazma; diğer anahtarlar korunur).

    Tema anahtarı ve "Beni hatırla" kimliği (sunucu adresi + e-posta) aynı dosyayı kullandığından tüm yazımlar buradan
    geçer: eşzamanlı iki yazım birbirinin anahtarını ezmez. Başarısızlık sessizdir (False). Gizli bilgi (parola, token)
    bu dosyaya YAZILMAZ."""
    target = path or preferences_path()
    with _PREFERENCES_LOCK:
        data = _read_preferences(target)
        for key in remove:
            data.pop(key, None)
        if updates:
            data.update(updates)
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            tmp_path = target + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as handle:
                json.dump(data, handle, indent=2, ensure_ascii=False)
            os.replace(tmp_path, target)
            return True
        except OSError:
            return False


def save_theme_preference(name: str, path: Optional[str] = None) -> bool:
    """Tercihi JSON dosyasına atomik yazar (diğer anahtarlar korunur). Başarısızlık sessizdir (False)."""
    if name not in THEMES:
        return False
    return update_preferences({PREFERENCE_KEY: name}, path=path)


# ---------------------------------------------------------------------------------------------------------------
# Günlük satırı sınıflandırma (renkli satır etiketleri)
# ---------------------------------------------------------------------------------------------------------------
LOG_TAGS = ("err", "warn", "ok", "info", "muted")
# str.lower() Türkçe I/ı-İ/i dönüşümünü bilmez ("UYARI".lower() == "uyari"): karşılaştırma ASCII'ye indirgenerek yapılır.
_FOLD = str.maketrans("İıŞşĞğÜüÖöÇç", "IiSsGgUuOoCc")


def _fold(text: str) -> str:
    return text.translate(_FOLD).lower()


def log_line_tag(text: str) -> Optional[str]:
    """Günlük satırı için renk etiketi: hata rose, uyarı amber, başarı emerald, komut/bilgi sky, ayraç soluk."""
    stripped = text.strip()
    if not stripped:
        return None
    if set(stripped) <= {"=", "-"}:
        return "muted"
    folded = _fold(stripped)
    if "❌" in stripped or "[hata]" in folded or "basarisiz" in folded or folded.startswith("hata"):
        return "err"
    if "⚠" in stripped or "[uyari]" in folded or "iptal" in folded or "guvensiz" in folded:
        return "warn"
    if "✅" in stripped or "✔" in stripped or "[basarili]" in folded or "tamamlandi" in folded or "dogrulandi" in folded:
        return "ok"
    if stripped.startswith("[") or "kopyalandi" in folded:
        return "info"
    return None


# ---------------------------------------------------------------------------------------------------------------
# Tema yöneticisi
# ---------------------------------------------------------------------------------------------------------------
_BUTTON_SIZES = {  # yazı puntosu, yatay/dikey iç boşluk (Tk piksel)
    "sm": (9, 10, 3),
    "md": (10, 12, 5),
    "lg": (11, 16, 8),
}


class ThemeManager:
    """Belirteçleri tutar, ttk stilini ('clam' tabanlı) kurar, kayıtlı tk widget'larını rolüne göre boyar.

    ``register(widget, rol, **parametre)`` widget'ı boyar ve tema değişince yeniden boyanmak üzere kaydeder.
    Roller: root, frame.bg, frame.surface, frame.header, frame.session, card.rim, card.body, card.topline, card.accent,
    label.* (brand, header.sub, badge, badge.<aile>, title, field, body, muted, subtle, accent.<aile>, note.<aile>,
    chip.<aile>, panel.<aile>, preview, status), entry, entry.mono, text.log, radio, check, button.* (GlassButton).
    """

    def __init__(self, root: tk.Misc, name: str = THEME_DARK, *, persist: bool = False) -> None:
        self.root = root
        self.name = name if name in THEMES else THEME_DARK
        self.persist = persist
        self.tokens = build_palette(self.name)
        self.font_family = _pick_family(root, FONT_FAMILY_CANDIDATES)
        self.mono_family = _pick_family(root, MONO_FAMILY_CANDIDATES)
        self._registry: list[tuple[tk.Misc, str, dict[str, Any]]] = []
        self._listeners: list[Callable[[dict[str, Any]], None]] = []
        self.style = ttk.Style(root)
        try:
            self.style.theme_use("clam")
        except tk.TclError:  # pragma: no cover - clam her Tk 8.6'da vardır
            pass
        self._apply_option_db()
        self._apply_ttk()

    # ---- genel ------------------------------------------------------------------------------------------------
    @property
    def is_dark(self) -> bool:
        return self.name == THEME_DARK

    def font(self, size: int = 10, weight: str = "normal", slant: str = "roman", mono: bool = False) -> tuple[Any, ...]:
        family = self.mono_family if mono else self.font_family
        parts: list[Any] = [family, size]
        if weight == "bold":
            parts.append("bold")
        if slant == "italic":
            parts.append("italic")
        return tuple(parts)

    def accent_text(self, family: str) -> str:
        """Kart/zemin üzerinde okunabilir (>= 4.5:1) vurgu metin rengi."""
        return str(self.tokens[f"accent_{family}_text"])

    def tint(self, family: str, alpha_key: str = "tint_alpha", over: Optional[str] = None) -> str:
        return blend(FAMILIES[family]["base"], over or str(self.tokens["surface"]), float(self.tokens[alpha_key]))

    def on_change(self, callback: Callable[[dict[str, Any]], None]) -> None:
        """Tema değişince çağrılacak ek işlev (ör. ağaç/günlük etiket renkleri)."""
        self._listeners.append(callback)

    def set_theme(self, name: str) -> None:
        if name not in THEMES:
            raise ValueError(f"bilinmeyen tema: {name!r}")
        self.name = name
        self.tokens = build_palette(name)
        self._apply_option_db()
        self._apply_ttk()
        alive: list[tuple[tk.Misc, str, dict[str, Any]]] = []
        for widget, role, params in self._registry:
            try:
                if not widget.winfo_exists():
                    continue
                self._paint(widget, role, params)
                alive.append((widget, role, params))
            except tk.TclError:
                continue
        self._registry = alive
        for callback in list(self._listeners):
            try:
                callback(self.tokens)
            except tk.TclError:
                continue
        if self.persist:
            save_theme_preference(name)

    def toggle(self) -> str:
        self.set_theme(THEME_LIGHT if self.is_dark else THEME_DARK)
        return self.name

    # ---- widget kaydı -----------------------------------------------------------------------------------------
    def register(self, widget: Any, role: str, **params: Any) -> Any:
        self._paint(widget, role, params)
        self._registry.append((widget, role, params))
        return widget

    def restyle(self, widget: Any, role: str, **params: Any) -> Any:
        """Kayıtlı widget'ın rolünü değiştirir (ör. oturum rozeti: uyarı -> başarı)."""
        for index, (known, _old_role, _old_params) in enumerate(self._registry):
            if known is widget:
                self._registry[index] = (widget, role, params)
                break
        else:
            self._registry.append((widget, role, params))
        self._paint(widget, role, params)
        return widget

    # ---- yardımcı kurucular -----------------------------------------------------------------------------------
    def frame(self, parent: tk.Misc, role: str = "frame.surface", **kw: Any) -> tk.Frame:
        return self.register(tk.Frame(parent, **kw), role)

    def label(self, parent: tk.Misc, role: str = "label.body", **kw: Any) -> tk.Label:
        params = {key: kw.pop(key) for key in ("size", "weight", "slant", "mono") if key in kw}
        return self.register(tk.Label(parent, **kw), role, **params)

    def entry(self, parent: tk.Misc, role: str = "entry", **kw: Any) -> tk.Entry:
        params = {key: kw.pop(key) for key in ("size", "weight", "accent") if key in kw}
        return self.register(tk.Entry(parent, **kw), role, **params)

    def radio(self, parent: tk.Misc, **kw: Any) -> tk.Radiobutton:
        params = {key: kw.pop(key) for key in ("size", "weight", "accent") if key in kw}
        return self.register(tk.Radiobutton(parent, cursor="hand2", **kw), "radio", **params)

    def check(self, parent: tk.Misc, **kw: Any) -> tk.Checkbutton:
        params = {key: kw.pop(key) for key in ("size", "weight") if key in kw}
        return self.register(tk.Checkbutton(parent, cursor="hand2", **kw), "check", **params)

    def text(self, parent: tk.Misc, role: str = "text.log", **kw: Any) -> tk.Text:
        params = {key: kw.pop(key) for key in ("size",) if key in kw}
        widget = self.register(tk.Text(parent, **kw), role, **params)
        self.configure_log_tags(widget)
        self.on_change(lambda _tokens, w=widget: self.configure_log_tags(w))
        return widget

    def scrollbar(self, parent: tk.Misc, **kw: Any) -> ttk.Scrollbar:
        return ttk.Scrollbar(parent, **kw)

    def button(self, parent: tk.Misc, role: str = "secondary", size: str = "md", **kw: Any) -> "GlassButton":
        return GlassButton(parent, theme=self, role=role, size=size, **kw)

    def card(self, parent: tk.Misc, title: str, *, accent: str = "cyan", padx: int = 12, pady: int = 10) -> tuple[tk.Frame, tk.Frame]:
        """Cam kart: 1 px rim çerçeve + üst ışık çizgisi + vurgu çubuklu başlık satırı + gövde. ``(dış, gövde)`` döner;
        dış çerçeve çağıran tarafından yerleştirilir, içerik gövdeye konur."""
        outer = self.frame(parent, "card.rim")
        inner = self.frame(outer, "card.body")
        inner.pack(fill=tk.BOTH, expand=True, padx=1, pady=1)
        topline = self.frame(inner, "card.topline", height=1)
        topline.pack(fill=tk.X, side=tk.TOP)
        head = self.frame(inner, "card.body")
        head.pack(fill=tk.X, padx=padx, pady=(6, 0))
        bar = self.register(tk.Frame(head, width=4, height=16), "card.accent", accent=accent)
        bar.pack(side=tk.LEFT, padx=(0, 8))
        bar.pack_propagate(False)
        self.label(head, "label.title", text=title.strip()).pack(side=tk.LEFT)
        body = self.frame(inner, "card.body")
        body.pack(fill=tk.BOTH, expand=True, padx=padx, pady=(2, pady))
        return outer, body

    def configure_log_tags(self, widget: tk.Text) -> None:
        t = self.tokens
        widget.tag_configure("err", foreground=t["log_err"])
        widget.tag_configure("warn", foreground=t["log_warn"])
        widget.tag_configure("ok", foreground=t["log_ok"])
        widget.tag_configure("info", foreground=t["log_info"])
        widget.tag_configure("muted", foreground=t["log_muted"])

    def tree_status_colors(self) -> dict[str, str]:
        """Envanter satır durumları için okunabilir renkler (ağaç zemini üzerinde)."""
        return {
            "IN_STOCK": self.accent_text("emerald"),
            "CLAIMED": self.accent_text("sky"),
            "SUSPENDED": self.accent_text("amber"),
            "REVOKED": self.accent_text("rose"),
        }

    # ---- boyama -----------------------------------------------------------------------------------------------
    def _paint(self, widget: Any, role: str, params: dict[str, Any]) -> None:
        if isinstance(widget, GlassButton):
            widget.repaint()
            return
        options = self.role_options(role, params)
        if options:
            widget.configure(**options)

    def role_options(self, role: str, params: dict[str, Any]) -> dict[str, Any]:  # noqa: C901 - düz rol tablosu
        t = self.tokens
        size = int(params.get("size", 10))
        weight = str(params.get("weight", "normal"))
        slant = str(params.get("slant", "roman"))
        accent = str(params.get("accent", "cyan"))
        if role == "root":
            return {"bg": t["bg"]}
        if role == "frame.bg":
            return {"bg": t["bg"]}
        if role in ("frame.surface", "card.body"):
            return {"bg": t["surface"]}
        if role == "frame.header":
            return {"bg": t["header_bg"]}
        if role == "frame.header.line":
            return {"bg": t["header_line"]}
        if role == "frame.session":
            return {"bg": t["session_bg"]}
        if role == "card.rim":
            return {"bg": t["surface_rim"]}
        if role == "card.topline":
            return {"bg": t["surface_rim_light"]}
        if role == "card.accent":
            return {"bg": FAMILIES[accent]["base"]}
        if role == "frame.surface_alt":
            return {"bg": t["surface_alt"]}
        if role.startswith("label."):
            return self._label_options(role, size, weight, slant, accent, params)
        if role in ("entry", "entry.mono"):
            mono = role == "entry.mono"
            fg = t["text"] if "accent" not in params else self.accent_text(accent)
            return {
                "bg": t["input_bg"], "fg": fg, "insertbackground": t["text"],
                "selectbackground": t["selection_bg"], "selectforeground": t["selection_fg"],
                "readonlybackground": t["input_bg"], "disabledbackground": t["surface_alt"],
                "disabledforeground": t["text_subtle"], "relief": "flat", "bd": 4,
                "highlightthickness": 1, "highlightbackground": t["input_border"], "highlightcolor": t["focus_ring"],
                "font": self.font(size, weight, mono=mono),
            }
        if role == "text.log":
            return {
                "bg": t["log_bg"], "fg": t["log_fg"], "insertbackground": t["log_cursor"],
                "selectbackground": t["selection_bg"], "selectforeground": t["selection_fg"],
                "relief": "flat", "bd": 0, "padx": 10, "pady": 8,
                "highlightthickness": 1, "highlightbackground": t["log_border"], "highlightcolor": t["focus_ring"],
                "font": self.font(size if "size" in params else 10, mono=True),
            }
        if role in ("radio", "check"):
            fg = self.accent_text(accent) if "accent" in params else t["text"]
            return {
                "bg": t["surface"], "fg": fg, "activebackground": t["surface"], "activeforeground": fg,
                "selectcolor": t["check_select"], "disabledforeground": t["text_subtle"],
                "highlightthickness": 1, "highlightbackground": t["surface"], "highlightcolor": t["focus_ring"],
                "font": self.font(size, weight),
            }
        return {}

    def _label_options(self, role: str, size: int, weight: str, slant: str, accent: str, params: dict[str, Any]) -> dict[str, Any]:
        t = self.tokens
        mono = bool(params.get("mono"))
        kind = role[len("label."):]
        font = self.font(size, weight, slant, mono=mono)
        base = {"font": font, "highlightthickness": 0}
        if kind == "brand":
            return {**base, "bg": t["header_bg"], "fg": t["header_brand"], "font": self.font(size if "size" in params else 15, "bold")}
        if kind == "header.sub":
            return {**base, "bg": t["header_bg"], "fg": t["header_sub"]}
        if kind == "header.text":
            return {**base, "bg": t["header_bg"], "fg": t["header_fg"]}
        if kind == "session.text":
            return {**base, "bg": t["session_bg"], "fg": t["badge_fg"]}
        if kind.startswith("session.accent."):  # lacivert oturum şeridinde vurgu metni (açık ton her temada okunur)
            return {**base, "bg": t["session_bg"], "fg": FAMILIES[kind.split(".", 2)[2]]["light"]}
        if kind == "badge":
            return {**base, "bg": t["badge_bg"], "fg": t["badge_fg"], "padx": 10, "pady": 3,
                    "highlightthickness": 1, "highlightbackground": t["badge_border"], "highlightcolor": t["badge_border"]}
        if kind.startswith("badge."):
            family = kind.split(".", 1)[1]
            return {**base, "bg": t[f"badge_{family}_bg"], "fg": t[f"badge_{family}_fg"], "padx": 10, "pady": 3,
                    "highlightthickness": 1, "highlightbackground": blend(FAMILIES[family]["base"], t["session_bg"], 0.45),
                    "highlightcolor": blend(FAMILIES[family]["base"], t["session_bg"], 0.45)}
        if kind == "title":
            return {**base, "bg": t["surface"], "fg": t["text"], "font": self.font(size if "size" in params else 11, "bold")}
        if kind == "field":
            return {**base, "bg": t["surface"], "fg": t["text"], "font": self.font(size if "size" in params else 10, "bold")}
        if kind == "body":
            return {**base, "bg": t["surface"], "fg": t["text"]}
        if kind == "muted":
            return {**base, "bg": t["surface"], "fg": t["text_muted"]}
        if kind == "subtle":
            return {**base, "bg": t["surface"], "fg": t["text_subtle"]}
        if kind == "status":
            return {**base, "bg": t["surface"], "fg": t["text_muted"], "font": self.font(size if "size" in params else 9)}
        if kind == "body.bg":
            return {**base, "bg": t["bg"], "fg": t["text"]}
        if kind.startswith("accent."):
            return {**base, "bg": t["surface"], "fg": self.accent_text(kind.split(".", 1)[1])}
        if kind.startswith("accent_bg."):  # zemin (bg) üzerinde vurgu metni
            return {**base, "bg": t["bg"], "fg": self.accent_text(kind.split(".", 1)[1])}
        if kind.startswith("note."):
            family = kind.split(".", 1)[1]
            return {**base, "bg": t["surface"], "fg": self.accent_text(family),
                    "font": self.font(size if "size" in params else 9, weight, slant)}
        if kind.startswith("chip."):  # cam rozet (tint zemin + okunabilir vurgu metni + ince kenar)
            family = kind.split(".", 1)[1]
            border = self.tint(family, "tint_border_alpha")
            return {**base, "bg": self.tint(family), "fg": self.accent_text(family), "padx": 10, "pady": 3,
                    "highlightthickness": 1, "highlightbackground": border, "highlightcolor": border}
        if kind.startswith("panel."):  # uyarı paneli (tint zemin, çok satırlı)
            family = kind.split(".", 1)[1]
            border = self.tint(family, "tint_border_alpha")
            return {**base, "bg": self.tint(family), "fg": self.accent_text(family), "padx": 10, "pady": 6,
                    "highlightthickness": 1, "highlightbackground": border, "highlightcolor": border}
        if kind == "preview":
            return {**base, "bg": t["input_bg"], "fg": t["text_muted"], "relief": "flat", "bd": 0,
                    "highlightthickness": 1, "highlightbackground": t["surface_rim"], "highlightcolor": t["surface_rim"]}
        return {**base, "bg": t["surface"], "fg": t["text"]}

    def button_colors(self, role: str) -> dict[str, str]:
        """Düğme rolü için renk takımı: bg / hover / pressed / fg / border / disabled_bg / disabled_fg."""
        t = self.tokens
        surface = str(t["surface"])
        if role == "primary":
            colors = {"bg": t["primary_bg"], "hover": t["primary_hover"], "pressed": t["primary_pressed"],
                      "fg": t["primary_fg"], "border": t["primary_bg"]}
        elif role == "danger":
            colors = {"bg": t["danger_bg"], "hover": t["danger_hover"], "pressed": t["danger_pressed"],
                      "fg": t["danger_fg"], "border": t["danger_bg"]}
        elif role.startswith("tint."):
            family = role.split(".", 1)[1]
            colors = {"bg": self.tint(family), "hover": self.tint(family, "tint_hover_alpha"),
                      "pressed": self.tint(family, "tint_pressed_alpha"), "fg": self.accent_text(family),
                      "border": self.tint(family, "tint_border_alpha")}
        elif role == "ghost":  # simge düğmesi: hafif cam dolgu + ince kenar (keşfedilebilir kalsın)
            colors = {"bg": t["surface_alt"], "hover": t["button_secondary_hover"], "pressed": t["button_secondary_pressed"],
                      "fg": t["text_muted"], "border": t["surface_rim"]}
        elif role == "header":  # lacivert şerit üzerindeki cam düğme
            colors = {"bg": t["badge_bg"], "hover": blend("#FFFFFF", str(t["session_bg"]), 0.18),
                      "pressed": blend("#FFFFFF", str(t["session_bg"]), 0.05), "fg": t["badge_fg"], "border": t["badge_border"]}
        elif role == "header.primary":
            colors = {"bg": t["primary_bg"], "hover": t["primary_hover"], "pressed": t["primary_pressed"],
                      "fg": t["primary_fg"], "border": t["primary_bg"]}
        else:  # secondary
            colors = {"bg": t["button_secondary_bg"], "hover": t["button_secondary_hover"], "pressed": t["button_secondary_pressed"],
                      "fg": t["button_secondary_fg"], "border": t["button_secondary_border"]}
        over = str(t["session_bg"]) if role.startswith("header") else surface
        colors["disabled_bg"] = blend(str(colors["bg"]), over, 0.45)
        colors["disabled_fg"] = blend(str(colors["fg"]), str(colors["disabled_bg"]), 0.55)
        colors["focus"] = t["focus_ring"]
        return {key: str(value) for key, value in colors.items()}

    # ---- ttk ve option DB -------------------------------------------------------------------------------------
    def _apply_option_db(self) -> None:
        """Kayıt dışı tk widget'ları (ör. simpledialog) için tema varsayılanları (widgetDefault önceliği)."""
        t = self.tokens
        add = self.root.option_add
        body = self.font(10)
        for pattern, value in (
            ("*Toplevel.background", t["surface"]),
            ("*Frame.background", t["surface"]),
            ("*Label.background", t["surface"]),
            ("*Label.foreground", t["text"]),
            ("*Label.font", body),
            ("*Message.background", t["surface"]),
            ("*Message.foreground", t["text"]),
            ("*Entry.background", t["input_bg"]),
            ("*Entry.foreground", t["text"]),
            ("*Entry.insertBackground", t["text"]),
            ("*Entry.font", body),
            ("*Button.background", t["button_secondary_bg"]),
            ("*Button.foreground", t["button_secondary_fg"]),
            ("*Button.activeBackground", t["button_secondary_hover"]),
            ("*Button.activeForeground", t["button_secondary_fg"]),
            ("*Button.font", self.font(10, "bold")),
            ("*Checkbutton.background", t["surface"]),
            ("*Checkbutton.foreground", t["text"]),
            ("*Radiobutton.background", t["surface"]),
            ("*Radiobutton.foreground", t["text"]),
            ("*Listbox.background", t["input_bg"]),
            ("*Listbox.foreground", t["text"]),
            ("*Listbox.selectBackground", t["selection_bg"]),
            ("*Listbox.selectForeground", t["selection_fg"]),
            ("*TCombobox*Listbox.background", t["input_bg"]),
            ("*TCombobox*Listbox.foreground", t["text"]),
            ("*TCombobox*Listbox.selectBackground", t["selection_bg"]),
            ("*TCombobox*Listbox.selectForeground", t["selection_fg"]),
            ("*TCombobox*Listbox.font", body),
        ):
            add(pattern, value, "widgetDefault")

    def _apply_ttk(self) -> None:  # noqa: C901 - düz stil tablosu
        t = self.tokens
        s = self.style
        body = self.font(10)
        bold = self.font(10, "bold")
        s.configure(".", background=t["bg"], foreground=t["text"], fieldbackground=t["input_bg"], font=body,
                    bordercolor=t["surface_rim"], lightcolor=t["surface"], darkcolor=t["surface"],
                    troughcolor=t["scroll_trough"], focuscolor=t["focus_ring"], selectbackground=t["selection_bg"],
                    selectforeground=t["selection_fg"], insertcolor=t["text"])
        s.configure("TFrame", background=t["bg"])
        s.configure("TLabel", background=t["surface"], foreground=t["text"])

        # Sekmeler: cam şerit; seçili sekme kart yüzeyiyle birleşir, üstünde camgöbeği ışık çizgisi
        s.configure("TNotebook", background=t["bg"], bordercolor=t["surface_rim"], lightcolor=t["bg"], darkcolor=t["bg"],
                    tabmargins=[6, 6, 6, 0], borderwidth=1)
        s.configure("TNotebook.Tab", background=t["tab_bg"], foreground=t["tab_fg"], padding=[16, 9], font=bold,
                    bordercolor=t["surface_rim"], lightcolor=t["tab_bg"], darkcolor=t["tab_bg"], focuscolor=t["focus_ring"])
        s.map("TNotebook.Tab",
              background=[("selected", t["tab_sel_bg"]), ("active", t["tab_hover_bg"])],
              foreground=[("selected", t["tab_sel_fg"]), ("active", t["tab_sel_fg"])],
              lightcolor=[("selected", t["tab_indicator"])],
              bordercolor=[("selected", t["surface_rim"])],
              expand=[("selected", [1, 1, 1, 0])])

        # Açılır kutu
        s.configure("TCombobox", fieldbackground=t["input_bg"], background=t["button_secondary_bg"], foreground=t["text"],
                    arrowcolor=t["text_muted"], bordercolor=t["input_border"], lightcolor=t["input_bg"], darkcolor=t["input_bg"],
                    insertcolor=t["text"], padding=[8, 5], arrowsize=16, font=body)
        s.map("TCombobox",
              fieldbackground=[("readonly", t["input_bg"]), ("disabled", t["surface_alt"])],
              foreground=[("readonly", t["text"]), ("disabled", t["text_subtle"])],
              selectbackground=[("readonly", t["input_bg"]), ("!readonly", t["selection_bg"])],
              selectforeground=[("readonly", t["text"]), ("!readonly", t["selection_fg"])],
              background=[("active", t["button_secondary_hover"]), ("pressed", t["button_secondary_pressed"])],
              arrowcolor=[("active", t["text"]), ("disabled", t["text_subtle"])],
              bordercolor=[("focus", t["focus_ring"]), ("active", t["focus_ring"])],
              lightcolor=[("focus", t["focus_ring"])], darkcolor=[("focus", t["focus_ring"])])

        # Tablo
        s.configure("Treeview", background=t["tree_bg"], fieldbackground=t["tree_bg"], foreground=t["tree_fg"],
                    bordercolor=t["surface_rim"], lightcolor=t["tree_bg"], darkcolor=t["tree_bg"], rowheight=26, font=body)
        s.map("Treeview", background=[("selected", t["tree_sel_bg"])], foreground=[("selected", t["tree_sel_fg"])])
        s.configure("Treeview.Heading", background=t["tree_head_bg"], foreground=t["tree_head_fg"], relief="flat",
                    bordercolor=t["surface_rim"], lightcolor=t["tree_head_bg"], darkcolor=t["tree_head_bg"],
                    padding=[8, 6], font=self.font(9, "bold"))
        s.map("Treeview.Heading", background=[("active", t["tab_hover_bg"]), ("pressed", t["tab_hover_bg"])],
              relief=[("active", "flat"), ("pressed", "flat")])

        # Kaydırma çubukları (clam renkleri alır; Windows tk.Scrollbar yerel çizimde renk almaz)
        for orient in ("Vertical", "Horizontal"):
            s.configure(f"{orient}.TScrollbar", background=t["scroll_thumb"], troughcolor=t["scroll_trough"],
                        bordercolor=t["scroll_trough"], lightcolor=t["scroll_thumb"], darkcolor=t["scroll_thumb"],
                        arrowcolor=t["scroll_arrow"], arrowsize=14, gripcount=0, relief="flat")
            s.map(f"{orient}.TScrollbar", background=[("active", t["scroll_thumb_active"]), ("pressed", t["scroll_thumb_active"])],
                  lightcolor=[("active", t["scroll_thumb_active"])], darkcolor=[("active", t["scroll_thumb_active"])],
                  arrowcolor=[("active", t["text"])])

        # Tema anahtarı: lacivert şeritte cam "switch" (Toolbutton yerleşimi; gösterge yok)
        try:
            s.layout("Switch.TCheckbutton", s.layout("Toolbutton"))
        except tk.TclError:  # pragma: no cover
            pass
        s.configure("Switch.TCheckbutton", background=t["badge_bg"], foreground=t["badge_fg"], bordercolor=t["badge_border"],
                    lightcolor=t["badge_bg"], darkcolor=t["badge_bg"], padding=[12, 5], font=self.font(9, "bold"),
                    relief="flat", focuscolor=t["focus_ring"], anchor="center")
        s.map("Switch.TCheckbutton",
              background=[("selected", t["switch_on_bg"]), ("active", blend("#FFFFFF", str(t["session_bg"]), 0.18))],
              foreground=[("selected", FAMILIES["cyan"]["light"]), ("active", t["header_fg"])],
              bordercolor=[("selected", blend(FAMILIES["cyan"]["base"], str(t["session_bg"]), 0.6)), ("focus", t["focus_ring"])],
              lightcolor=[("selected", t["switch_on_bg"])], darkcolor=[("selected", t["switch_on_bg"])],
              relief=[("pressed", "flat"), ("!pressed", "flat")])

    def retint_combobox_popdown(self, combo: ttk.Combobox) -> None:
        """Daha önce açılmış açılır listeyi (option DB sonradan etkilemez) yeni temaya boyar."""
        t = self.tokens
        try:
            popdown = combo.tk.call("ttk::combobox::PopdownWindow", str(combo))
            combo.tk.call(f"{popdown}.f.l", "configure", "-background", t["input_bg"], "-foreground", t["text"],
                          "-selectbackground", t["selection_bg"], "-selectforeground", t["selection_fg"])
        except tk.TclError:
            pass


class GlassButton(tk.Button):
    """Düz dolgulu, kalın etiketli tk.Button: hover'da bir ton açılır, basınca koyulaşır, pasifken solar; klavye odağında
    camgöbeği odak halkası. Tk sınıfı 'Button' olarak kalır (testler/erişilebilirlik için)."""

    def __init__(self, master: tk.Misc, *, theme: ThemeManager, role: str = "secondary", size: str = "md", **kw: Any) -> None:
        kw.setdefault("cursor", "hand2")
        kw.setdefault("relief", "flat")
        kw.setdefault("bd", 0)
        super().__init__(master, **kw)
        self._theme = theme
        self._role = role
        self._size = size
        self._hover = False
        self._colors: dict[str, str] = {}
        theme.register(self, "button")
        self.bind("<Enter>", self._on_enter, add=True)
        self.bind("<Leave>", self._on_leave, add=True)

    # tk.Button.configure/config: durum değişince renkleri yeniden uygula (state=disabled -> soluk)
    def configure(self, cnf: Any = None, **kw: Any) -> Any:  # type: ignore[override]
        result = super().configure(cnf, **kw)
        if (isinstance(cnf, dict) and "state" in cnf) or "state" in kw:
            self._apply_colors()
        return result

    config = configure

    @property
    def role(self) -> str:
        return self._role

    def set_role(self, role: str) -> None:
        self._role = role
        self.repaint()

    def repaint(self) -> None:
        theme = self._theme
        self._colors = theme.button_colors(self._role)
        font_size, padx, pady = _BUTTON_SIZES.get(self._size, _BUTTON_SIZES["md"])
        bold = self._role not in ("ghost",)
        super().configure(
            font=theme.font(font_size, "bold" if bold else "normal"),
            padx=padx,
            pady=pady,
            relief="flat",
            bd=0,
            highlightthickness=1,
            highlightcolor=self._colors["focus"],
            activeforeground=self._colors["fg"],
            disabledforeground=self._colors["disabled_fg"],
        )
        self._apply_colors()

    def _apply_colors(self) -> None:
        colors = self._colors
        if not colors:
            return
        try:
            disabled = str(self.cget("state")) == "disabled"
        except tk.TclError:
            return
        if disabled:
            bg, fg = colors["disabled_bg"], colors["disabled_fg"]
        else:
            bg, fg = (colors["hover"] if self._hover else colors["bg"]), colors["fg"]
        super().configure(bg=bg, fg=fg, activebackground=colors["pressed"], highlightbackground=colors["border"] if not disabled else bg)

    def _on_enter(self, _event: Any = None) -> None:
        self._hover = True
        self._apply_colors()

    def _on_leave(self, _event: Any = None) -> None:
        self._hover = False
        self._apply_colors()


def theme_of(widget: tk.Misc) -> ThemeManager:
    """Pencerenin (ya da üst penceresinin) tema yöneticisini bulur; yoksa köke bağlı yeni bir yönetici kurar."""
    node: Any = widget
    while node is not None:
        manager = getattr(node, "theme", None)
        if isinstance(manager, ThemeManager):
            return manager
        node = getattr(node, "master", None)
    root = widget.winfo_toplevel()
    manager = ThemeManager(root, load_theme_preference())
    try:
        setattr(root, "theme", manager)
    except AttributeError:  # pragma: no cover
        pass
    return manager


def _pick_family(root: tk.Misc, candidates: tuple[str, ...]) -> str:
    try:
        available = set(tkfont.families(root))
    except tk.TclError:  # pragma: no cover
        return candidates[0]
    for name in candidates:
        if name in available:
            return name
    return "TkDefaultFont"


# ---------------------------------------------------------------------------------------------------------------
# Kontrast denetimi: python tool_theme.py --check
# ---------------------------------------------------------------------------------------------------------------
def contrast_report(name: str) -> list[tuple[str, str, str, float, float]]:
    """(açıklama, ön, arka, oran, eşik) listesi: metin çiftleri 4.5, odak halkası/kenar 3.0."""
    t = build_palette(name)
    pairs: list[tuple[str, str, str, float]] = [
        ("metin / kart", t["text"], t["surface"], 4.5),
        ("metin / zemin", t["text"], t["bg"], 4.5),
        ("soluk metin / kart", t["text_muted"], t["surface"], 4.5),
        ("ince metin / kart", t["text_subtle"], t["surface"], 4.5),
        ("giriş metni / giriş zemini", t["text"], t["input_bg"], 4.5),
        ("marka / başlık şeridi", t["header_brand"], t["header_bg"], 4.5),
        ("alt başlık / başlık şeridi", t["header_sub"], t["header_bg"], 4.5),
        ("rozet / oturum şeridi", t["badge_fg"], t["badge_bg"], 4.5),
        ("sekme / sekme zemini", t["tab_fg"], t["tab_bg"], 4.5),
        ("seçili sekme", t["tab_sel_fg"], t["tab_sel_bg"], 4.5),
        ("tablo metni", t["tree_fg"], t["tree_bg"], 4.5),
        ("tablo başlığı", t["tree_head_fg"], t["tree_head_bg"], 4.5),
        ("tablo seçim", t["tree_sel_fg"], t["tree_sel_bg"], 4.5),
        ("günlük metni", t["log_fg"], t["log_bg"], 4.5),
        ("günlük hata", t["log_err"], t["log_bg"], 4.5),
        ("günlük uyarı", t["log_warn"], t["log_bg"], 4.5),
        ("günlük başarı", t["log_ok"], t["log_bg"], 4.5),
        ("günlük bilgi", t["log_info"], t["log_bg"], 4.5),
        ("günlük soluk", t["log_muted"], t["log_bg"], 4.5),
        ("birincil düğme", t["primary_fg"], t["primary_bg"], 4.5),
        ("birincil düğme (hover)", t["primary_fg"], t["primary_hover"], 3.0),
        ("tehlikeli düğme", t["danger_fg"], t["danger_bg"], 4.5),
        ("ikincil düğme", t["button_secondary_fg"], t["button_secondary_bg"], 4.5),
        ("odak halkası / kart", t["focus_ring"], t["surface"], 3.0),
        ("odak halkası / zemin", t["focus_ring"], t["bg"], 3.0),
        ("giriş kenarı / giriş zemini", t["input_border"], t["input_bg"], 3.0),
        ("tema anahtarı (açık)", FAMILIES["cyan"]["light"], t["switch_on_bg"], 4.5),
    ]
    for family in FAMILIES:
        tint_bg = blend(FAMILIES[family]["base"], t["surface"], float(t["tint_alpha"]))
        pairs.append((f"{family} metni / kart", t[f"accent_{family}_text"], t["surface"], 4.5))
        pairs.append((f"{family} tint düğme", t[f"accent_{family}_text"], tint_bg, 4.5))
        pairs.append((f"{family} metni / tablo", t[f"accent_{family}_text"], t["tree_bg"], 4.5))
    for family in ("emerald", "amber", "rose", "sky", "cyan"):
        pairs.append((f"{family} rozet / oturum şeridi", t[f"badge_{family}_fg"], t[f"badge_{family}_bg"], 4.5))
    return [(label, fg, bg, round(contrast_ratio(fg, bg), 2), minimum) for label, fg, bg, minimum in pairs]


def _print_contrast_report() -> int:
    failures = 0
    for name in THEMES:
        print(f"== {name} ==")
        for label, fg, bg, ratio, minimum in contrast_report(name):
            flag = "OK " if ratio >= minimum else "!! "
            failures += ratio < minimum
            print(f"  {flag}{ratio:5.2f} (>= {minimum}) {label:32s} {fg} / {bg}")
    print("HATA" if failures else "Tüm çiftler eşiğin üzerinde.", failures)
    return 1 if failures else 0


if __name__ == "__main__":  # pragma: no cover - elle denetim
    if "--check" in sys.argv:
        sys.exit(_print_contrast_report())
    print(__doc__)
