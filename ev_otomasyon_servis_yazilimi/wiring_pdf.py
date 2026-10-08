# -*- coding: utf-8 -*-
"""
Kablolama şeması PDF'i (İP-3.5, K-Ş9) - yalnızca Pillow + qrcode; yeni bağımlılık YOK, Tk'siz.

Şablondan (``ahbu-template/1``) saha ekibi için A4 / 300 DPI şema üretir: başlık (site, blok/daire, şablon adı, daire tipi,
sürüm, tarih), karta bakan klemens düzeni (8 röle + 8 giriş; ek modül etkinse ayrı blok), her röle çıkışı -> yük/oda/tip
(panjur çiftlerinde yön notu ve kilitleme uyarısı), her giriş -> kablolama notu / kip / hedef (sensörlerde tür + NO/NC +
bölge), dimmer yerleşimi (K4), güvenlik cihazları ve uyarılar (gaz: sertifikalı bağımsız dedektör; vana kapanma kipi),
şablon kimliği + sürümü taşıyan karekod ve "Bu şema şablon sürümü vN içindir" alt bilgisi. Çok sayfalı olabilir.

Türkçe karakterler: TrueType yazı tipi aracın ``_load_font`` yükleyicisiyle (``font_loader`` parametresi) alınır; bulunamazsa
metin ASCII'ye indirgenir (kutucuk çıkmasın). Üretilen her metin ``WiringDocument.texts`` listesinde de tutulur (test).
"""

from __future__ import annotations

import textwrap
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Optional

import qrcode
from PIL import Image, ImageDraw, ImageFont

import template_model as tm

PAGE_SIZE = (2480, 3508)          # A4 @ 300 DPI
DPI = 300
MARGIN = 140
HEADER_H = 430
FOOTER_H = 120
_TR_TO_ASCII = str.maketrans("İıŞşĞğÜüÖöÇç·", "IiSsGgUuOoCc-")
REGULAR_FONTS = ("segoeui.ttf", "arial.ttf", "tahoma.ttf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf")
BOLD_FONTS = ("segoeuib.ttf", "arialbd.ttf", "tahomabd.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf")

GAS_WARNING = (
    "GAZ: Pano gaz dedektörünün YERİNE GEÇMEZ. Gaz algılama için sertifikalı (EN 50194-1) bağımsız bir gaz dedektörü "
    "kullanın; dedektörün NC alarm kontağını şemadaki girişe bağlayın. Gaz vanası uzaktan AÇILAMAZ; yalnız panodaki "
    "'gaz sıfırlama' girişiyle yerinde açılır."
)
SHUTTER_WARNING = (
    "PANJUR: Yukarı ve aşağı röleleri aynı motorun iki yön ucuna bağlanır; ikisi asla aynı anda enerjilenmez (yazılım "
    "kilitlemesi). Yönleri ters bağlamayın; motorun ortak (nötr) ucu panodan değil dağıtımdan gelir. Motor uç "
    "anahtarları (limit) yerinde ayarlı olmalı."
)
GENERAL_NOTES = (
    "Röle kontakları kuru kontaktır: faz hattını COM'a, yükü NO'ya bağlayın; yük akımı rölenin anma değerini aşmamalı "
    "(motor/ısıtıcı için kontaktör kullanın).",
    "Girişler (DI) kuru kontak içindir: anahtar/buton/sensör kontağını DI ile GND (COM) arasına bağlayın; girişe şebeke "
    "gerilimi VERMEYİN.",
    "Bu şema karta yazılan şablon sürümüne göredir. Sahada değişiklik yapılırsa pano esastır; yeni sürüm yazılıp şema "
    "yeniden basılmalıdır.",
)

FontLoader = Callable[[tuple[str, ...], int], tuple[Any, bool]]


def default_font_loader(candidates: tuple[str, ...], size: int) -> tuple[Any, bool]:
    """Aracın ``_load_font`` yükleyicisinin Tk'siz eşi (aynı yazı tipi sırası)."""
    for name in candidates:
        try:
            return ImageFont.truetype(name, size), True
        except OSError:
            continue
    try:
        return ImageFont.load_default(size), False
    except (TypeError, OSError):
        return ImageFont.load_default(), False


def qr_payload(template: dict[str, Any]) -> str:
    """Karekod içeriği: şablon kimliği + sürüm (ör. ``AHBU-TPL:3f2a...:v4``). Gizli değer İÇERMEZ."""
    meta = template.get("meta", {})
    return f"AHBU-TPL:{meta.get('template_id', '-')}:v{meta.get('version', 0)}"


def footer_text(template: dict[str, Any]) -> str:
    return f"Bu şema şablon sürümü v{template.get('meta', {}).get('version', 0)} içindir"


@dataclass
class WiringDocument:
    pages: list[Any] = field(default_factory=list)
    texts: list[str] = field(default_factory=list)
    qr_box: tuple[int, int, int, int] = (0, 0, 0, 0)   # 1. sayfadaki karekodun kutusu (test için)

    def save(self, path: str) -> None:
        if not self.pages:
            raise ValueError("Boş belge kaydedilemez.")
        first, rest = self.pages[0], self.pages[1:]
        first.save(path, "PDF", resolution=float(DPI), save_all=True, append_images=rest)


class _Renderer:
    def __init__(self, template: dict[str, Any], header_lines: list[tuple[str, str]], font_loader: FontLoader) -> None:
        self.t = template
        self.header_lines = header_lines
        load = font_loader
        self.f_title, ok1 = load(BOLD_FONTS, 66)
        self.f_head, ok2 = load(BOLD_FONTS, 44)
        self.f_body, ok3 = load(REGULAR_FONTS, 34)
        self.f_bold, ok4 = load(BOLD_FONTS, 34)
        self.f_small, ok5 = load(REGULAR_FONTS, 28)
        self.f_term, ok6 = load(BOLD_FONTS, 30)
        self.truetype = all((ok1, ok2, ok3, ok4, ok5, ok6))
        self.doc = WiringDocument()
        self.page: Any = None
        self.draw: Any = None
        self.y = 0

    # ---- metin yardımcıları ----
    def tr(self, text: str) -> str:
        return text if self.truetype else text.translate(_TR_TO_ASCII)

    def text(self, xy: tuple[float, float], text: str, font: Any, fill: str = "#0f172a") -> None:
        self.doc.texts.append(text)
        self.draw.text(xy, self.tr(text), font=font, fill=fill)

    def width_of(self, text: str, font: Any) -> float:
        return self.draw.textlength(self.tr(text), font=font)

    def wrap(self, text: str, font: Any, width: float) -> list[str]:
        words = (text or "").split()
        if not words:
            return [""]
        lines, current = [], ""
        for word in words:
            candidate = f"{current} {word}".strip()
            if self.width_of(candidate, font) <= width or not current:
                if self.width_of(candidate, font) > width and not current:  # tek sözcük taşıyor: kaba bölme
                    pieces = textwrap.wrap(word, max(4, int(len(word) * width / max(self.width_of(word, font), 1))))
                    lines.extend(pieces[:-1])
                    current = pieces[-1]
                    continue
                current = candidate
            else:
                lines.append(current)
                current = word
        lines.append(current)
        return lines

    # ---- sayfa düzeni ----
    @property
    def content_w(self) -> int:
        return PAGE_SIZE[0] - 2 * MARGIN

    @property
    def bottom(self) -> int:
        return PAGE_SIZE[1] - MARGIN - FOOTER_H

    def new_page(self) -> None:
        self.page = Image.new("RGB", PAGE_SIZE, "#ffffff")
        self.draw = ImageDraw.Draw(self.page)
        self.doc.pages.append(self.page)
        self._header()
        self.y = MARGIN + HEADER_H + 20

    def ensure(self, height: int) -> None:
        if self.page is None or self.y + height > self.bottom:
            self.new_page()

    def _header(self) -> None:
        d = self.draw
        d.rectangle([(MARGIN, MARGIN), (PAGE_SIZE[0] - MARGIN, MARGIN + 110)], fill="#0f172a")
        self.text((MARGIN + 30, MARGIN + 20), "AHBU KABLOLAMA ŞEMASI (giriş / çıkış bağlantıları)", self.f_title, "#38bdf8")
        y = MARGIN + 135
        col_w = (self.content_w - 330) // 2
        for index, (caption, value) in enumerate(self.header_lines):
            x = MARGIN + (index % 2) * col_w
            row_y = y + (index // 2) * 62
            self.text((x, row_y), caption + ":", self.f_small, "#64748b")
            self.text((x + 250, row_y - 6), value, self.f_bold)
        qr = _qr_image(qr_payload(self.t), 300)
        qx, qy = PAGE_SIZE[0] - MARGIN - qr.size[0], MARGIN + 118
        self.page.paste(qr, (qx, qy))
        if len(self.doc.pages) == 1:
            self.doc.qr_box = (qx, qy, qx + qr.size[0], qy + qr.size[1])
        d.line([(MARGIN, MARGIN + HEADER_H), (PAGE_SIZE[0] - MARGIN, MARGIN + HEADER_H)], fill="#cbd5e1", width=3)

    def finish(self) -> WiringDocument:
        total = len(self.doc.pages)
        for number, page in enumerate(self.doc.pages, 1):
            self.page, self.draw = page, ImageDraw.Draw(page)
            y = PAGE_SIZE[1] - MARGIN - 70
            self.draw.line([(MARGIN, y - 20), (PAGE_SIZE[0] - MARGIN, y - 20)], fill="#cbd5e1", width=3)
            self.text((MARGIN, y), footer_text(self.t), self.f_bold, "#991b1b")
            label = f"Sayfa {number}/{total}"
            self.text((PAGE_SIZE[0] - MARGIN - self.width_of(label, self.f_small), y + 4), label, self.f_small, "#64748b")
        return self.doc

    def heading(self, text: str) -> None:
        self.ensure(140)
        self.y += 20
        self.text((MARGIN, self.y), text, self.f_head, "#0f172a")
        self.y += 70

    def paragraph(self, text: str, font: Any = None, fill: str = "#0f172a", box: Optional[str] = None) -> None:
        font = font or self.f_body
        pad = 24 if box else 0
        lines = self.wrap(text, font, self.content_w - 2 * pad)
        height = len(lines) * 46 + 2 * pad
        self.ensure(height + 16)
        if box:
            self.draw.rectangle([(MARGIN, self.y), (PAGE_SIZE[0] - MARGIN, self.y + height)], outline=box, width=3,
                                fill="#fef2f2" if box == "#dc2626" else "#fffbeb")
        for index, line in enumerate(lines):
            self.text((MARGIN + pad, self.y + pad + index * 46), line, font, fill)
        self.y += height + 16

    def table(self, headers: list[str], widths: list[float], rows: list[list[str]], shade: Optional[list[str]] = None) -> None:
        total = sum(widths)
        cols = [w * self.content_w / total for w in widths]

        def draw_row(cells: list[str], font: Any, fill_bg: Optional[str]) -> None:
            wrapped = [self.wrap(cell, font, cols[i] - 24) for i, cell in enumerate(cells)]
            height = max(len(w) for w in wrapped) * 42 + 22
            if self.y + height > self.bottom:
                self.new_page()
                draw_row(headers, self.f_bold, "#e2e8f0")
            x = MARGIN
            if fill_bg:
                self.draw.rectangle([(MARGIN, self.y), (PAGE_SIZE[0] - MARGIN, self.y + height)], fill=fill_bg)
            for i, lines in enumerate(wrapped):
                for j, line in enumerate(lines):
                    self.text((x + 12, self.y + 10 + j * 42), line, font)
                x += cols[i]
            self.draw.rectangle([(MARGIN, self.y), (PAGE_SIZE[0] - MARGIN, self.y + height)], outline="#94a3b8", width=2)
            x = MARGIN
            for width in cols[:-1]:
                x += width
                self.draw.line([(x, self.y), (x, self.y + height)], fill="#94a3b8", width=2)
            self.y += height

        self.ensure(200)
        draw_row(headers, self.f_bold, "#e2e8f0")
        for index, row in enumerate(rows):
            draw_row(row, self.f_body, (shade[index] if shade else None))
        self.y += 20

    # ---- klemens düzeni ----
    def board(self, relay_texts: list[str], di_texts: list[str], title: str, first_ch: int, kind_colors: list[str]) -> None:
        count = len(relay_texts)
        height = 980
        self.ensure(height + 40)
        top = self.y
        box_top, box_bottom = top + 330, top + 650
        d = self.draw
        d.rounded_rectangle([(MARGIN + 40, box_top), (PAGE_SIZE[0] - MARGIN - 40, box_bottom)], radius=30,
                            outline="#0f172a", width=5, fill="#f1f5f9")
        center = (MARGIN + 40 + PAGE_SIZE[0] - MARGIN - 40) / 2
        title_w = self.width_of(title, self.f_head)
        self.text((center - title_w / 2, (box_top + box_bottom) / 2 - 26), title, self.f_head)
        slot = (self.content_w - 80) / max(count, 1)
        for i in range(count):
            cx = MARGIN + 40 + slot * i + slot / 2
            ch = first_ch + i
            # Röle klemensi (üst kenar): COM / NO
            d.rectangle([(cx - slot / 2 + 10, box_top - 70), (cx + slot / 2 - 10, box_top)], outline="#0f172a", width=3,
                        fill=kind_colors[i])
            label = f"R{ch} COM|NO"
            self.text((cx - self.width_of(label, self.f_term) / 2, box_top - 56), label, self.f_term)
            d.line([(cx, box_top - 70), (cx, top + 200)], fill="#334155", width=3)
            lines = self.wrap(relay_texts[i], self.f_small, slot - 16)[:5]
            for j, line in enumerate(lines):
                self.text((cx - self.width_of(line, self.f_small) / 2, top + 10 + j * 36), line, self.f_small)
            # Giriş klemensi (alt kenar): DI / GND
            d.rectangle([(cx - slot / 2 + 10, box_bottom), (cx + slot / 2 - 10, box_bottom + 70)], outline="#0f172a", width=3,
                        fill="#e0f2fe")
            label = f"D{ch} DI|GND"
            self.text((cx - self.width_of(label, self.f_term) / 2, box_bottom + 14), label, self.f_term)
            d.line([(cx, box_bottom + 70), (cx, box_bottom + 130)], fill="#334155", width=3)
            lines = self.wrap(di_texts[i], self.f_small, slot - 16)[:5]
            for j, line in enumerate(lines):
                self.text((cx - self.width_of(line, self.f_small) / 2, box_bottom + 140 + j * 36), line, self.f_small)
        self.y = top + height


def _qr_image(payload: str, max_px: int) -> Any:
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2)
    qr.add_data(payload)
    qr.make(fit=True)
    qr.box_size = max(4, max_px // (qr.modules_count + 2 * qr.border))
    return qr.make_image(fill_color="black", back_color="white").convert("RGB")


# ---------------------------------------------------------------------------
# İçerik metinleri (saf; testlerde de kullanılır)
# ---------------------------------------------------------------------------
def _actuator_for_relay(template: dict[str, Any], ch: int) -> Optional[dict[str, Any]]:
    for act in template["safety"].get("actuators", []):
        if ch in (act.get("relay"), act.get("relay2")):
            return act
    return None


def actuator_text(act: dict[str, Any]) -> str:
    kind = tm.ACT_KIND_TEXT.get(act.get("kind", ""), act.get("kind", ""))
    parts = [f"Güvenlik: {kind}"]
    if act.get("kind") == "valve":
        parts.append(f"{tm.MEDIUM_TEXT.get(act.get('medium', 'none'), '-')} vanası")
        parts.append(tm.CLOSE_MODE_TEXT.get(act.get("close_mode", "energize"), ""))
    zones = act.get("zones") or []
    if zones:
        parts.append("bölge " + ",".join(str(z) for z in zones))
    return " · ".join(p for p in parts if p)


def relay_note(template: dict[str, Any], ch: int) -> str:
    relay = template["relays"][ch - 1]
    kind = relay["type"]
    notes: list[str] = []
    if kind == "shutter_up":
        notes.append(f"Panjur YUKARI yön ucu; eşi R{ch + 1} (aşağı). Süre {relay.get('runtime_s')} sn. Kilitli çift: "
                     "ikisi aynı anda enerjilenmez.")
    elif kind == "shutter_down":
        notes.append(f"Panjur AŞAĞI yön ucu; eşi R{ch - 1} (yukarı). Süre {relay.get('runtime_s')} sn.")
    elif kind == "impulse":
        notes.append(f"Darbe rölesi: {relay.get('pulse_ms')} ms kapanıp açılır (kapı otomatiği/zil).")
    act = _actuator_for_relay(template, ch)
    if act is not None:
        notes.append(actuator_text(act))
        if act.get("kind") == "valve" and act.get("close_mode") == "pulse":
            notes.append("KAPAT rölesi" if act.get("relay") == ch else "AÇ rölesi")
    light = tm.light_option(template, ch)
    if light and light.get("dimmable"):
        src = tm.DIMMER_SRC_TEXT.get(light.get("src", 0), "?")
        notes.append(f"Parlaklık ayarlı: {src}, adres {light.get('addr', 0)}, kanal {light.get('ch', 0)} (dimmer gerekir)")
    return " ".join(notes)


def di_note(template: dict[str, Any], ch: int) -> tuple[str, str]:
    """(kip/hedef, sensör) metinleri."""
    item = template["dis"][ch - 1]
    sensor = tm.di_sensor(template, ch)
    if sensor is not None:
        contact = "NC (normalde kapalı)" if sensor.get("active_open") else "NO (normalde açık)"
        zone = sensor.get("zone", 0)
        zone_text = "tüm bölgeler" if zone == 0 else f"bölge {zone}"
        kind = tm.SENSOR_KIND_TEXT.get(sensor.get("kind", ""), sensor.get("kind", ""))
        return "Sensör (hedef yok)", f"{kind} · {contact} · {zone_text}"
    target = item["target_relay"]
    mode = tm.DI_MODE_TEXT.get(item["mode"], item["mode"])
    if target == 0:
        return "Boşta", ""
    relay_name = template["relays"][target - 1]["name"]
    return f"{mode} -> R{target} ({relay_name})", ""


def build_wiring_document(
    template: dict[str, Any],
    *,
    site_name: str = "",
    block: Any = "",
    number: Any = "",
    date: Optional[datetime] = None,
    font_loader: FontLoader = default_font_loader,
) -> WiringDocument:
    """Şablondan kablolama şeması sayfaları (PIL görüntüleri) üretir. Şablon geçersizse ``ValueError``."""
    issue = tm.validate_template(template)
    if issue is not None:
        raise ValueError(str(issue))
    meta = template["meta"]
    n = tm.total_channels(template)
    when = (date or datetime.now()).strftime("%d.%m.%Y %H:%M")
    place = tm.flat_info_line(block, number) or "-"
    header = [
        ("Site", site_name or "Genel (tek daire)"),
        ("Blok / Daire", place),
        ("Şablon", meta["name"]),
        ("Daire tipi", meta["flat_type"]),
        ("Şablon sürümü", f"v{meta['version']}"),
        ("Tarih", when),
    ]
    r = _Renderer(template, header, font_loader)
    r.new_page()

    def relay_label(ch: int) -> str:
        relay = template["relays"][ch - 1]
        kind = tm.RELAY_TYPE_TEXT.get(relay["type"], relay["type"])
        act = _actuator_for_relay(template, ch)
        if act is not None:
            kind = tm.ACT_KIND_TEXT.get(act.get("kind", ""), kind)
        return f"{relay['name']} · {kind}" + (f" · {relay.get('room')}" if relay.get("room") else "")

    def di_label(ch: int) -> str:
        item = template["dis"][ch - 1]
        mode, sensor = di_note(template, ch)
        if not sensor and mode == "Boşta":
            return item["name"] if item["name"].lower().startswith("boş") else f"{item['name']} (boşta)"
        return f"{item['name']} · {sensor or mode}"

    def color(ch: int) -> str:
        kind = template["relays"][ch - 1]["type"]
        if _actuator_for_relay(template, ch) is not None:
            return "#fee2e2"
        return {"shutter_up": "#ede9fe", "shutter_down": "#ede9fe", "impulse": "#fef3c7"}.get(kind, "#dcfce7")

    r.heading("1. Karta bakan klemens düzeni (ana kart: 8 röle çıkışı üstte, 8 giriş altta)")
    base = list(range(1, min(n, 8) + 1))
    r.board([relay_label(ch) for ch in base], [di_label(ch) for ch in base], "Ana kart ESP32-S3 8DI-8RO", 1,
            [color(ch) for ch in base])
    ext = template["ext_module"]
    if ext.get("enabled"):
        r.paragraph(
            f"Ek modül (RS485 Modbus): adres {ext['address']}, {ext['channels']} kanal -> röleler R9-R{n}, girişler D9-D{n}. "
            "RS485 A/B hattını panodan ek modüle taşıyın; hat sonunda sonlandırma direnci olmalı.",
            r.f_bold, box="#d97706",
        )
        for start in range(9, n + 1, 8):
            chans = list(range(start, min(start + 7, n) + 1))
            r.board([relay_label(ch) for ch in chans], [di_label(ch) for ch in chans],
                    f"Ek modül (adres {ext['address']}) R{chans[0]}-R{chans[-1]}", start, [color(ch) for ch in chans])

    r.heading("2. Röle çıkışları -> bağlanacak yük")
    rows, shade = [], []
    for ch in range(1, n + 1):
        relay = template["relays"][ch - 1]
        kind = tm.RELAY_TYPE_TEXT.get(relay["type"], relay["type"])
        act = _actuator_for_relay(template, ch)
        if act is not None:  # güvenlik cihazı rölesi "Lamba/Priz" değil cihaz türüyle görünür (klemens satırıyla aynı)
            kind = tm.ACT_KIND_TEXT.get(act.get("kind", ""), kind)
        rows.append([f"R{ch}", relay["name"], relay.get("room", ""), kind, relay.get("load", ""), relay_note(template, ch)])
        shade.append(color(ch))
    r.table(["Çıkış", "Ad", "Oda", "Tip", "Bağlanacak yük", "Not"], [0.6, 1.6, 1.0, 1.0, 1.8, 2.6], rows, shade)
    if any(rel["type"].startswith("shutter") for rel in template["relays"]):
        r.paragraph(SHUTTER_WARNING, r.f_body, box="#d97706")

    r.heading("3. Girişler (DI) -> anahtar / buton / sensör")
    rows = []
    for ch in range(1, n + 1):
        item = template["dis"][ch - 1]
        mode, sensor = di_note(template, ch)
        rows.append([f"D{ch}", item["name"], mode, item.get("wiring", ""), sensor])
    r.table(["Giriş", "Ad", "Kip / hedef", "Kablolama notu", "Sensör (tür · kontak · bölge)"], [0.6, 1.6, 2.2, 1.8, 2.4], rows)

    lights = [light for light in template["safety"].get("lights", []) if light.get("dimmable")]
    if lights:
        r.heading("4. Dimmer (parlaklık) yerleşimi")
        for light in lights:
            name = template["relays"][light["relay"] - 1]["name"]
            r.paragraph(f"R{light['relay']}: " + tm.dimmer_guidance(light, name))

    safety = template["safety"]
    r.heading("5. Güvenlik cihazları ve uyarılar")
    zones = ", ".join(f"{z['id']}={z['name']}" for z in safety.get("zones", []))
    r.paragraph(f"Güvenlik tepkileri: {'AÇIK' if safety['policy']['on'] else 'KAPALI'} · kuruluk bekleme "
                f"{safety['policy']['dry_hold_ms'] // 1000} sn · bölgeler: {zones}")
    actuators = safety.get("actuators", [])
    if actuators:
        rows = []
        for index, act in enumerate(actuators, 1):
            relays = f"R{act['relay']}" + (f" + R{act['relay2']} (aç)" if act.get("relay2") else "")
            rows.append([f"a{index}", act.get("name", ""), relays, actuator_text(act)])
        r.table(["#", "Ad", "Röle", "Tür / kip / bölge"], [0.5, 1.6, 1.4, 4.0], rows)
        for act in actuators:
            if act.get("kind") == "valve" and act.get("close_mode") == "deenergize":
                r.paragraph(f"{act.get('name') or 'Vana'}: enerji kesilince KAPANAN vana (NC tip). Elektrik kesintisinde "
                            "vana kapanır; röle normalde enerjili tutulur.", box="#d97706")
            elif act.get("kind") == "valve" and act.get("close_mode") == "energize":
                r.paragraph(f"{act.get('name') or 'Vana'}: enerji verince KAPANAN vana (NO tip). Kapatmak için röle "
                            "enerjilenir; elektrik kesintisinde vana açık kalır.", box="#d97706")
    else:
        r.paragraph("Bu şablonda güvenlik eylemcisi (vana/siren/fan) yok.")
    has_gas = any(s.get("kind") == "gas" for s in safety.get("sensors", [])) or any(
        a.get("medium") == "gas" for a in actuators)
    if has_gas:
        r.paragraph(GAS_WARNING, r.f_bold, "#991b1b", box="#dc2626")

    r.heading("6. Genel kurallar")
    for note in GENERAL_NOTES:
        r.paragraph("• " + note)
    return r.finish()


def save_wiring_pdf(path: str, template: dict[str, Any], **kwargs: Any) -> WiringDocument:
    """Belgeyi üretip ``path``'e PDF olarak yazar (çok sayfalı, 300 DPI)."""
    doc = build_wiring_document(template, **kwargs)
    doc.save(path)
    return doc
