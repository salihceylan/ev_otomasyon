#!/usr/bin/env python3
"""Türkçe akış belgelerini (Markdown) renkli A4 PDF'e çevirir.

Yalnız Python standart kütüphanesi kullanılır; PDF'i başsız (headless) Microsoft Edge basar.

    python tools/belge_pdf/belge_pdf.py <girdi.md> [--diagram <ayar.json>] [--out <çıktı.pdf>] [--html <kopya.html>]

Desteklenen Markdown: # .. #### başlık, paragraf, **kalın**, *italik*, `kod`, iç içe numaralı/madde
listeler, alıntı (>), tablo, yatay çizgi (---), bağlantı (yalnız metin olarak basılır).
Görsel kurallar (rol çipleri, uyarı kutuları, adım akışı, genel akış diyagramı) için README.md'ye bakın.
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PRODUCT, COMPANY, COMPANY_SUB = "AHBU Ev Otomasyonu", "Güde Teknoloji", "Zayıf Akım ve Teknoloji Sistemleri"
EDGE_PATHS = [os.environ.get("EDGE_PATH", ""),
              r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
              r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"]
MONTHS = "Ocak Şubat Mart Nisan Mayıs Haziran Temmuz Ağustos Eylül Ekim Kasım Aralık".split()

# Rol renkleri her yerde aynıdır (çip, tablo başlığı, diyagram kulvarı): (anahtar, ad, renk, eşleşen yazımlar)
ROLES = [
    ("super", "Süper kullanıcı", "#6d28d9", r"süper kullanıcı"),
    ("servis", "Servis sorumlusu", "#1d4ed8", r"servis sorumlusu"),
    ("oturum", "Servis oturumu", "#0e7490", r"servis oturumu|geçici servis(?: \(PIN\))?"),
    ("sahip", "Ev sahibi", "#047857", r"ev sahibi"),
    ("uye", "Aile üyesi", "#b45309", r"aile üyesi|ev üyesi"),
    ("misafir", "Misafir", "#be185d", r"misafir"),
    ("bireysel", "Bireysel kullanıcı", "#4d7c0f", r"bireysel kullanıcı"),
]
DEVICE = ("pano", "Pano", "#475569")  # diyagramda rol olmayan "pano kendisi yapar" kulvarı
ROLE_RE = re.compile(r"\b(?:" + "|".join(f"(?P<{k}>{p})" for k, _, _, p in ROLES) + r")(?!\w)", re.IGNORECASE)
ROLE_COLOR = {k: c for k, _, c, _ in ROLES + [DEVICE + ("",)]}

# Bölüm bantlarının renkleri, bölüm numarasına göre (kapaktaki ve diyagramdaki "Bölüm N" rozetleri de aynı renk)
SECTION_COLORS = ["#0e7490", "#2563eb", "#7c3aed", "#c2410c", "#047857", "#be185d",
                  "#4f46e5", "#b45309", "#0f766e", "#9333ea", "#b91c1c"]

ICONS = {  # 24x24, çizgi simgeler (stroke = currentColor)
    "info": '<circle cx="12" cy="12" r="9.5"/><path d="M12 11v6M12 7.6v.01"/>',
    "warn": '<path d="M12 3.2 2.6 19.6h18.8z"/><path d="M12 9.6v4.4M12 16.8v.01"/>',
    "excl": '<circle cx="12" cy="12" r="9.5"/><path d="M12 7v6.2M12 16.6v.01"/>',
    "bulb": '<path d="M9.2 18h5.6M10.2 21h3.6M12 3a6 6 0 0 0-3.6 10.8c.7.6 1 1.3 1 2.2h5.2c0-.9.3-1.6 1-2.2A6 6 0 0 0 12 3z"/>',
    "doc": '<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4M9.5 12h5M9.5 15.5h5"/>',
    "flow": '<rect x="3" y="4" width="7" height="5" rx="1.5"/><rect x="14" y="15" width="7" height="5" rx="1.5"/>'
            '<path d="M6.5 9v4.5a2 2 0 0 0 2 2H14"/>',
}
CALLOUTS = {"Dikkat": ("#b91c1c", "warn"), "Uyarı": ("#c2410c", "warn"), "Önemli": ("#b45309", "excl"),
            "Not": ("#1d4ed8", "info"), "İpucu": ("#047857", "bulb")}
QUOTE_KIND = ("#0e7490", "info")  # anahtar kelimesiz alıntı (>) da bilgi kutusu olur
CALLOUT_RE = re.compile(r"^(?:\*\*)?(Dikkat|Uyarı|Önemli|Not|İpucu)(?:\*\*)?\s*:(?:\*\*)?\s*")
# Liste biçimi, listenin hemen üstündeki başlığa göre seçilir; ayar dosyasında "<biçim>_basliklari" ile değişir.
LIST_STYLES = {"kart": [r"değişenler", r"yenilikler"], "kontrol": [r"kontrol listesi"], "adim": [r"^Adımlar$"]}


def mix(color: str, t: float) -> str:
    """Rengi t oranında beyaza karıştırır (0: aynı renk, 1: beyaz)."""
    rgb = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(c + (255 - c) * t):02x}" for c in rgb)


def shade(color: str, t: float) -> str:
    """Rengi t oranında koyulaştırır."""
    return "#" + "".join(f"{round(int(color[i:i + 2], 16) * (1 - t)):02x}" for i in (1, 3, 5))


def tone_vars(prefix: str, color: str) -> str:
    return f"--{prefix}:{color};--{prefix}-mid:{mix(color, .7)};--{prefix}-soft:{mix(color, .93)}"


def section_color(no: str) -> str:
    m = re.match(r"\d+", no or "")
    return SECTION_COLORS[int(m[0]) % len(SECTION_COLORS)] if m else SECTION_COLORS[0]


def icon(name: str) -> str:
    return f'<svg class="i" viewBox="0 0 24 24" aria-hidden="true">{ICONS[name]}</svg>'


def esc(s: str) -> str:
    return html.escape(s, quote=True)


# ------------------------------------------------------------------ Markdown blokları
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
HR = re.compile(r"^\s{0,3}([-*_])(?:\s*\1){2,}\s*$")
LIST_ITEM = re.compile(r"^( *)(\d{1,9}[.)]|[-*+])( +)(.*)$")
TABLE_SEP = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def starts_block(line: str) -> bool:
    s = line.strip()
    return bool(HEADING.match(s) or HR.match(line) or s[:1] in (">", "|") or LIST_ITEM.match(line))


def split_row(line: str) -> list[str]:
    s = line.strip()
    s = s[1:] if s.startswith("|") else s
    s = s[:-1] if s.endswith("|") and not s.endswith("\\|") else s
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", s)]


def parse_blocks(lines: list[str]) -> list[dict]:
    out, i = [], 0
    while i < len(lines):
        line, s = lines[i], lines[i].strip()
        if not s:
            i += 1
        elif m := HEADING.match(s):
            out.append({"t": "h", "level": len(m[1]), "text": m[2]})
            i += 1
        elif HR.match(line):
            out.append({"t": "hr"})
            i += 1
        elif s.startswith(">"):
            inner = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                inner.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append({"t": "quote", "blocks": parse_blocks(inner)})
        elif s.startswith("|") and i + 1 < len(lines) and TABLE_SEP.match(lines[i + 1]):
            aligns = [("center" if c.startswith(":") and c.endswith(":") else "right" if c.endswith(":") else "")
                      for c in split_row(lines[i + 1])]
            table = {"t": "table", "head": split_row(s), "aligns": aligns, "rows": []}
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                table["rows"].append(split_row(lines[i]))
                i += 1
            out.append(table)
        elif LIST_ITEM.match(line):
            block, i = parse_list(lines, i)
            out.append(block)
        else:
            para = [s]
            i += 1
            while i < len(lines) and lines[i].strip() and not starts_block(lines[i]):
                para.append(lines[i].strip())
                i += 1
            out.append({"t": "p", "text": " ".join(para)})
    return out


def parse_list(lines: list[str], i: int) -> tuple[dict, int]:
    first = LIST_ITEM.match(lines[i])
    indent, ordered = len(first[1]), first[2][0].isdigit()
    block = {"t": "ol" if ordered else "ul", "start": int(first[2][:-1]) if ordered else 1, "items": []}
    while i < len(lines):
        m = LIST_ITEM.match(lines[i])
        if not m or len(m[1]) != indent or m[2][0].isdigit() != ordered:
            break
        width = len(m[1]) + len(m[2]) + len(m[3])  # madde içeriğinin girintisi
        # "1. 4. sekmede ..." gibi maddede baştaki "4." metindir, iç liste değil
        body, i = [re.sub(r"^(\d{1,9})([.)])(?= )", r"\1\\\2", m[4])], i + 1
        while i < len(lines):
            line = lines[i]
            if not line.strip():  # boş satır: arkasından girintili satır gelirse madde sürer
                j = i
                while j < len(lines) and not lines[j].strip():
                    j += 1
                if j < len(lines) and indent_of(lines[j]) >= width:
                    body += [""] * (j - i)
                    i = j
                    continue
                break
            if indent_of(line) >= width:
                body.append(line[width:])
            elif starts_block(line):
                break
            else:
                body.append(line.strip())  # girintisiz devam satırı
            i += 1
        block["items"].append(parse_blocks(body))
        j = i  # maddeler arasında boş satır (gevşek liste)
        while j < len(lines) and not lines[j].strip():
            j += 1
        if j < len(lines) and (n := LIST_ITEM.match(lines[j])) and len(n[1]) == indent:
            i = j
    return block, i


# ------------------------------------------------------------------ satır içi biçim
def chip(text: str, key: str) -> str:
    return f'<span class="chip r-{key}">{text}</span>'


def role_key(name: str) -> str | None:
    m = ROLE_RE.fullmatch(name.strip())
    return m.lastgroup if m else None


def inline(text: str, roles: str | None = None) -> str:
    """Satır içi Markdown -> HTML. roles='all': tüm rol adları çip olur (başlık, tablo başlığı);
    roles='bold': yalnız tek başına kalın yazılmış rol adı ("**Servis sorumlusu:**") çip olur."""
    codes: list[str] = []

    def keep(m: re.Match) -> str:
        codes.append("<code>" + html.escape(m[2].strip(), quote=False) + "</code>")
        return f"\x00{len(codes) - 1}\x00"

    t = re.sub(r"(`+)(.+?)\1", keep, text)
    t = re.sub(r"\\([!-/:-@\[-`{-~])", lambda m: f"\x03{ord(m[1])}\x03", t)  # \. \* gibi kaçışlar
    t = html.escape(t, quote=False)
    t = re.sub(r'"([^"]+)"', "\x01\\1\x02", t)  # tırnak içi = ekrandaki düğme/mesaj
    t = re.sub(r"!?\[([^\]]+)\]\([^)]*\)", r'<span class="link">\1</span>', t)
    t = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])", r"<em>\1</em>", t)
    t = re.sub(r"(?<!\w)_(?=[^\s_])(.+?)(?<=[^\s_])_(?!\w)", r"<em>\1</em>", t)
    if roles == "all":
        t = ROLE_RE.sub(lambda m: chip(m[0], m.lastgroup), t)
    elif roles == "bold":
        t = re.sub(r"<strong>([^<:]+)(:?)</strong>",
                   lambda m: chip(m[1], k) + m[2] if (k := role_key(m[1])) else m[0], t)
    t = t.replace("\x01", '<span class="ui">“').replace("\x02", "”</span>")
    t = re.sub("\x03(\\d+)\x03", lambda m: html.escape(chr(int(m[1])), quote=False), t)
    return re.sub("\x00(\\d+)\x00", lambda m: codes[int(m[1])], t)


# ------------------------------------------------------------------ belge gövdesi
class Body:
    def __init__(self, cfg: dict):
        self.toc: list[tuple] = []  # (düzey, no, başlık, id, renk)
        self.heading = ""
        self.in_section = False
        self.ids: set[str] = set()
        self.styles = {k: [re.compile(p, re.I) for p in cfg.get(f"{k}_basliklari", v)]
                       for k, v in LIST_STYLES.items()}

    def render(self, blocks: list[dict]) -> str:
        return self.blocks(blocks) + ("\n</section>" if self.in_section else "")

    def blocks(self, blocks: list[dict], depth: int = 0, parent: str | None = None) -> str:
        out = []
        for n, b in enumerate(blocks):
            t = b["t"]
            if t == "h":
                out.append(self.heading_html(b))
            elif t == "hr":  # bölüm bantları zaten ayırıyor; yalnız başlık önünde olmayan çizgi basılır
                nxt = blocks[n + 1] if n + 1 < len(blocks) else None
                if nxt and not (nxt["t"] == "h" and nxt["level"] <= 2):
                    out.append("<hr>")
            elif t == "p":
                out.append(self.para(b["text"]))
            elif t == "quote":
                out.append(self.quote(b["blocks"]))
            elif t == "table":
                out.append(self.table(b))
            else:
                out.append(self.list(b, depth, parent))
        return "\n".join(out)

    def make_id(self, base: str) -> str:
        slug = re.sub(r"[^\w]+", "-", base.lower()).strip("-") or "b"
        hid, n = f"s-{slug}", 2
        while hid in self.ids:
            hid, n = f"s-{slug}-{n}", n + 1
        self.ids.add(hid)
        return hid

    def heading_html(self, b: dict) -> str:
        m = re.match(r"^(\d+(?:\.\d+)*)\.?\s+(.*)$", b["text"])
        no, title = (m[1], m[2]) if m else ("", b["text"])
        self.heading, level = title, b["level"]
        if level == 1:
            return ""  # belge başlığı kapakta
        hid = self.make_id(no or title)
        badge = f'<span class="no">{no}</span>' if no else ""
        if level == 2:
            color = section_color(no) if no else SECTION_COLORS[len(self.toc) % len(SECTION_COLORS)]
            self.toc.append((2, no, title, hid, color))
            start = ("</section>\n" if self.in_section else "") + (
                f'<section class="sec" style="{tone_vars("c", color)};--c2:{mix(color, .3)}">')
            self.in_section = True
            return f'{start}\n<h2 id="{hid}" class="band">{badge}<span class="t">{inline(title, "all")}</span></h2>'
        if level == 3:
            self.toc.append((3, no, title, hid, None))
        return f'<h{level} id="{hid}">{badge}<span class="t">{inline(title, "all")}</span></h{level}>'

    def para(self, text: str) -> str:
        if m := CALLOUT_RE.match(text):
            return self.box(CALLOUTS[m[1]], m[1], [{"t": "p", "text": text[m.end():]}])
        return f"<p>{inline(text, 'bold')}</p>"

    def quote(self, blocks: list[dict]) -> str:
        if blocks and blocks[0]["t"] == "p" and (m := CALLOUT_RE.match(blocks[0]["text"])):
            rest = [dict(blocks[0], text=blocks[0]["text"][m.end():])] + blocks[1:]
            return self.box(CALLOUTS[m[1]], m[1], rest)
        return self.box(QUOTE_KIND, None, blocks)

    def box(self, kind: tuple, title: str | None, blocks: list[dict]) -> str:
        color, ico = kind
        head = f'<div class="k-title">{title}</div>' if title else ""
        return (f'<div class="callout" style="{tone_vars("k", color)}"><div class="ico">{icon(ico)}</div>'
                f'<div class="k-body">{head}{self.blocks(blocks, 1)}</div></div>')

    def table(self, b: dict) -> str:
        def align(k: int) -> str:
            a = b["aligns"][k] if k < len(b["aligns"]) else ""
            return f' style="text-align:{a}"' if a else ""

        # rol tablosu: sütun başlıkları çip, hücreler Evet/Hayır rozeti; uzun tablo sayfada bölünebilir
        cls = " ".join(c for c, on in (("roles", sum(bool(ROLE_RE.search(c)) for c in b["head"]) >= 2),
                                       ("long", len(b["rows"]) > 8)) if on)
        ths = "".join(f"<th{align(k)}>{inline(c, 'all')}</th>" for k, c in enumerate(b["head"]))
        trs = "".join("<tr>" + "".join(f"<td{align(k)}>{self.cell(c)}</td>" for k, c in enumerate(row)) + "</tr>"
                      for row in b["rows"])
        attr = f' class="{cls}"' if cls else ""
        return f"<table{attr}><thead><tr>{ths}</tr></thead><tbody>{trs}</tbody></table>"

    @staticmethod
    def cell(text: str) -> str:
        m = re.match(r"^(\*\*)?(Evet|Hayır)(\*\*)?(?![\w])\s*(.*)$", text)
        if not m:
            return inline(text, "bold")
        cls = ("yes" if m[2] == "Evet" else "no") + (" strong" if m[1] else "")
        note = f'<span class="note">{inline(m[4])}</span>' if m[4] else ""
        return f'<span class="pill {cls}">{m[2]}</span>{note}'

    def list_style(self) -> str | None:
        return next((k for k, pats in self.styles.items() if any(p.search(self.heading) for p in pats)), None)

    def list(self, b: dict, depth: int, parent: str | None) -> str:
        ordered = b["t"] == "ol"
        if depth == 0:
            style = self.list_style() if ordered else None
        else:
            style = "sub" if ordered and parent in ("adim", "kart", "sub") else None
        cls = {"adim": "steps", "kart": "cards", "kontrol": "check", "sub": "sub"}.get(style or "")
        items = []
        for k, item in enumerate(b["items"]):
            body, attrs = self.item(item, depth, style)
            if style == "kontrol":
                items.append(f'<li{attrs}><span class="tick"></span><div class="body">{body}</div></li>')
            elif style:
                items.append(f'<li{attrs}><span class="num">{b["start"] + k}</span><div class="body">{body}</div></li>')
            else:
                items.append(f"<li{attrs}>{body}</li>")
        tag = "ol" if ordered else "ul"
        attr = f' class="{cls}"' if cls else (f' start="{b["start"]}"' if ordered and b["start"] != 1 else "")
        return f"<{tag}{attr}>" + "".join(items) + f"</{tag}>"

    def item(self, blocks: list[dict], depth: int, style: str | None) -> tuple[str, str]:
        if not blocks or blocks[0]["t"] != "p":
            return self.blocks(blocks, depth + 1, style), ""
        text, attrs = blocks[0]["text"], ""
        if m := CALLOUT_RE.match(text):  # "**Önemli:** ..." maddesi renkli kutu olur
            color, ico = CALLOUTS[m[1]]
            attrs = f' class="co" style="{tone_vars("k", color)}"'
            first = f'<span class="co-label">{icon(ico)}{m[1]}:</span> {inline(text[m.end():], "bold")}'
        else:
            first = inline(text, "bold")
            if first.startswith("<strong>"):  # maddenin başındaki kalın ifade adım başlığı gibi renklenir
                first = '<strong class="lead">' + first[len("<strong>"):]
        return f"<p>{first}</p>" + self.blocks(blocks[1:], depth + 1, style), attrs

    def toc_html(self) -> str:
        groups: list[list[str]] = []
        for level, no, title, hid, color in self.toc:
            if level == 2:
                badge = f'<span class="no">{no}</span>' if no else '<span class="no">•</span>'
                groups.append([f'<li style="--c:{color}"><a href="#{hid}">{badge}<span>{inline(title)}</span></a>', ""])
            elif groups:
                sub = f'<span class="sno">{no}</span>' if no else ""
                groups[-1][1] += f'<li><a href="#{hid}">{sub}{inline(title)}</a></li>'
        items = "".join(head + (f"<ol>{sub}</ol>" if sub else "") + "</li>" for head, sub in groups)
        return f'<nav class="toc"><h2 class="toc-title">İçindekiler</h2><ol class="toc-list">{items}</ol></nav>'


# ------------------------------------------------------------------ genel akış diyagramı (SVG)
def text_w(s: str, size: float, bold: bool = False) -> float:
    """Segoe UI için yaklaşık metin genişliği (satır kaydırma ve etiket kutusu için)."""
    w = 0.0
    for ch in s:
        if ch == " ":
            w += .27
        elif ch in "iıljI.,:;'!|’":
            w += .25
        elif ch in "frt()[]-–“”\"/":
            w += .37
        elif ch in "mwMW%@":
            w += .85
        elif ch.isupper():
            w += .64
        elif ch.isdigit():
            w += .56
        else:
            w += .53
    return w * size * (1.07 if bold else 1)


def wrap(s: str, width: float, size: float, bold: bool = False) -> list[str]:
    lines = []
    for part in (s or "").split("\n"):
        cur = ""
        for word in part.split():
            cand = f"{cur} {word}".strip()
            if cur and text_w(cand, size, bold) > width:
                lines.append(cur)
                cur = word
            else:
                cur = cand
        if cur:
            lines.append(cur)
    return lines


def svg_text(lines: list[str], x: float, y: float, size: float, lh: float, fill: str, weight: int = 400,
             anchor: str = "middle") -> str:
    """lines'ı y'den (ilk satırın üstü) başlayarak yazar."""
    spans = "".join(f'<tspan x="{x:.1f}" y="{y + size * .92 + k * lh:.1f}">{esc(t)}</tspan>'
                    for k, t in enumerate(lines))
    return f'<text font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{spans}</text>'


def lane_of(name: str) -> tuple[str, str, str]:
    if name.strip().lower() == "pano":
        return DEVICE
    key = role_key(name)
    if not key:
        raise SystemExit(f"Diyagram: bilinmeyen kulvar adı: {name!r} (rol adı ya da 'Pano' olmalı)")
    return key, name, ROLE_COLOR[key]


def diagram_svg(d: dict) -> str:
    W, PAD, PH_W, HEAD_H, GAP, PH_GAP, INSET = 680, 3, 70, 34, 24, 10, 8
    T, T_LH, S, S_LH = 11, 13.4, 9.5, 11.8
    lanes = [lane_of(n) for n in d["kulvarlar"]]
    names = {n.strip().lower(): k for k, n in enumerate(d["kulvarlar"])}

    def index(name: str) -> int:
        if name.strip().lower() not in names:
            raise SystemExit(f"Diyagram: {name!r} kulvarlar listesinde yok")
        return names[name.strip().lower()]

    x0 = PAD + PH_W + 8
    lw = (W - PAD - x0) / len(lanes)

    boxes = {}
    for b in d["kutular"]:
        a, z = index(b["kulvar"]), index(b.get("kulvar_son", b["kulvar"]))
        w = (z - a + 1) * lw - 2 * INSET
        title, text = wrap(b["baslik"], w - 14, T, True), wrap(b.get("metin", ""), w - 12, S)
        h = 13 + len(title) * T_LH + (3 + len(text) * S_LH if text else 0) + 7
        x = x0 + a * lw + INSET
        tag = f"§ {b['bolum']}" if b.get("bolum") else ""
        tag_w = text_w(tag, 8.5, True) + 10 if tag else 0
        boxes[b["id"]] = dict(b, a=a, z=z, x=x, w=w, h=h, title=title, text=text, tag=tag, tag_w=tag_w,
                              tag_l=x + w - tag_w - 7 if tag else x + w)

    phase_of = {r: k for k, p in enumerate(d["asamalar"]) for r in range(p["satirlar"][0], p["satirlar"][1] + 1)}
    rows = sorted({b["satir"] for b in boxes.values()} | set(phase_of))
    row_h = {r: max([46] + [b["h"] for b in boxes.values() if b["satir"] == r]) for r in rows}
    row_y, y, prev = {}, PAD + HEAD_H + 13, None
    for r in rows:
        if prev is not None and phase_of.get(r) != prev:
            y += PH_GAP
        row_y[r], y, prev = y, y + row_h[r] + GAP, phase_of.get(r)
    H = y - GAP + 9 + PAD
    for b in boxes.values():
        b["y"], b["h"] = row_y[b["satir"]], row_h[b["satir"]]

    parts = []
    # kulvarlar: açık renkli zemin + renkli başlık
    for k, (key, name, color) in enumerate(lanes):
        lx = x0 + k * lw
        parts.append(f'<rect x="{lx + 2:.1f}" y="{PAD + HEAD_H + 3}" width="{lw - 4:.1f}" '
                     f'height="{H - PAD - HEAD_H - 3 - PAD:.1f}" rx="8" fill="{mix(color, .94)}"/>')
        parts.append(f'<rect x="{lx + 2:.1f}" y="{PAD}" width="{lw - 4:.1f}" height="{HEAD_H - 2}" rx="8" fill="{color}"/>')
        lines = wrap(name, lw - 14, 10.5, True)
        parts.append(svg_text(lines, lx + lw / 2, PAD + (HEAD_H - 2 - len(lines) * 12.6) / 2, 10.5, 12.6, "#fff", 700))
    # aşamalar: soldaki gri bantlar (diyagramda renk = rol); bölüm rengi yalnız ince çizgi ve rozette
    for k, p in enumerate(d["asamalar"]):
        r0, r1 = p["satirlar"]
        top, bot = row_y[r0] - 7, row_y[r1] + row_h[r1] + 7
        color = section_color(str(p.get("bolum", k)))
        parts.append(f'<rect x="{PAD}" y="{top:.1f}" width="{PH_W}" height="{bot - top:.1f}" rx="8" '
                     f'fill="#f1f5f9" stroke="#cbd5e1"/>')
        parts.append(f'<rect x="{PAD}" y="{top:.1f}" width="4" height="{bot - top:.1f}" rx="2" fill="{color}"/>')
        name = wrap(p["ad"], PH_W - 14, 11, True)
        badge = f"Bölüm {p['bolum']}" if p.get("bolum") else ""
        block = len(name) * 13 + (17 if badge else 0)
        ty, cx = (top + bot) / 2 - block / 2, PAD + PH_W / 2 + 2
        parts.append(svg_text(name, cx, ty, 11, 13, "#1e293b", 700))
        if badge:
            bw = text_w(badge, 8.5, True) + 10
            parts.append(f'<rect x="{cx - bw / 2:.1f}" y="{ty + len(name) * 13 + 3:.1f}" width="{bw:.1f}" height="13" '
                         f'rx="6.5" fill="{color}"/>')
            parts.append(svg_text([badge], cx, ty + len(name) * 13 + 3.4, 8.5, 10, "#fff", 700))
        if k:
            sep = top - (PH_GAP + GAP - 14) / 2  # önceki aşama bandıyla bu bandın tam ortası
            parts.append(f'<line x1="{x0 + 4:.1f}" x2="{W - PAD - 4:.1f}" y1="{sep:.1f}" y2="{sep:.1f}" '
                         f'stroke="#94a3b8" stroke-width="1" stroke-dasharray="5 4"/>')
    # kutular
    for b in boxes.values():
        colors = [lanes[k][2] for k in range(b["a"], b["z"] + 1)]
        single = len(colors) == 1
        stroke = colors[0] if single else "#64748b"
        dash = ' stroke-dasharray="5 3"' if single and lanes[b["a"]][0] == "pano" else ""
        x, y, w, h = b["x"], b["y"], b["w"], b["h"]
        parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="8" fill="#fff" '
                     f'stroke="{stroke}" stroke-width="1.4"{dash}/>')
        seg = (w - 16 - 3 * (len(colors) - 1)) / len(colors)
        for k, c in enumerate(colors):  # üst şerit: kutuyu kimlerin yaptığı (birden çok rol = çok renk)
            parts.append(f'<rect x="{x + 8 + k * (seg + 3):.1f}" y="{y + 4:.1f}" width="{seg:.1f}" height="3.2" '
                         f'rx="1.6" fill="{c}"/>')
        block = len(b["title"]) * T_LH + (3 + len(b["text"]) * S_LH if b["text"] else 0)
        ty = y + 8 + (h - 8 - block) / 2
        parts.append(svg_text(b["title"], x + w / 2, ty, T, T_LH, shade(stroke, .25) if single else "#1e293b", 700))
        if b["text"]:
            parts.append(svg_text(b["text"], x + w / 2, ty + len(b["title"]) * T_LH + 3, S, S_LH, "#475569"))
        if b["tag"]:  # bölüm etiketi kutunun sağ üst köşesinde
            tw = b["tag_w"]
            parts.append(f'<rect x="{b["tag_l"]:.1f}" y="{y - 7:.1f}" width="{tw:.1f}" height="13" rx="6.5" '
                         f'fill="#fff" stroke="{stroke}"/>')
            parts.append(svg_text([b["tag"]], b["tag_l"] + tw / 2, y - 6.6, 8.5, 10, shade(stroke, .2), 700))
    # oklar (önce beyaz hale: kesişen çizgiler ayrık görünür)
    markers: dict[str, str] = {}
    labels = []
    for o in d.get("oklar", []):
        if o["den"] not in boxes or o["e"] not in boxes:
            raise SystemExit(f"Diyagram: okta bilinmeyen kutu kimliği: {o['den']!r} -> {o['e']!r}")
        A, B = boxes[o["den"]], boxes[o["e"]]
        dashed = bool(o.get("kesikli"))
        src_single = A["a"] == A["z"]
        color = (lanes[A["a"]][2] if src_single else "#64748b") if dashed else "#475569"
        mid = markers.setdefault(color, f"ok{len(markers)}")
        if A["satir"] == B["satir"]:  # aynı satır: yatay ok
            cy = A["y"] + A["h"] / 2
            sx, ex = (A["x"] + A["w"], B["x"]) if A["x"] < B["x"] else (A["x"], B["x"] + B["w"])
            path, lx, ly = f"M{sx:.1f} {cy:.1f}H{ex:.1f}", (sx + ex) / 2, cy - 5
        else:  # aşağı ok: ortak sütun varsa düz, yoksa dirsekli
            up = B["satir"] < A["satir"]
            sy, ey = (A["y"], B["y"] + B["h"]) if up else (A["y"] + A["h"], B["y"])
            lo, hi = max(A["x"], B["x"]), min(A["x"] + A["w"], B["x"] + B["w"])
            edge = B["x"] + B["w"] if up else B["tag_l"] - 9  # ok ucu bölüm etiketine binmesin
            if hi - lo >= 30:
                x = max(lo + 12, min((lo + hi) / 2, edge))
                path, lx, ly = f"M{x:.1f} {sy:.1f}V{ey:.1f}", x + 5, (sy + ey) / 2 + 3
            else:
                sx = min(max(B["x"] + B["w"] / 2, A["x"] + 22), A["x"] + A["w"] - 22)
                ex = max(B["x"] + 12, min(max(sx, B["x"] + 22), B["x"] + B["w"] - 22, edge))
                ym = ey + GAP / 2 if up else ey - GAP / 2
                path, lx, ly = f"M{sx:.1f} {sy:.1f}V{ym:.1f}H{ex:.1f}V{ey:.1f}", (sx + ex) / 2, ym - 4
        da = ' stroke-dasharray="5 4"' if dashed else ""
        parts.append(f'<path d="{path}" fill="none" stroke="#fff" stroke-width="5"/>')
        parts.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="1.6"{da} marker-end="url(#{mid})"/>')
        if o.get("etiket"):
            vertical = path.count("V") == 1 and "H" not in path
            anchor = "start" if vertical else "middle"
            tw = text_w(o["etiket"], 9, True) + 8
            rx = lx - 4 if vertical else lx - tw / 2
            labels.append(f'<rect x="{rx:.1f}" y="{ly - 9.5:.1f}" width="{tw:.1f}" height="12.5" rx="3" '
                          f'fill="#fff" fill-opacity=".92"/>')
            labels.append(svg_text([o["etiket"]], lx, ly - 9, 9, 11, shade(color, .1), 700, anchor))
    defs = "".join(f'<marker id="{m}" viewBox="0 0 10 10" refX="9.6" refY="5" markerWidth="8" markerHeight="8" '
                   f'markerUnits="userSpaceOnUse" orient="auto"><path d="M0 .5 10 5 0 9.5z" fill="{c}"/></marker>'
                   for c, m in markers.items())
    return (f'<svg class="flow" viewBox="0 0 {W} {H:.0f}" role="img" aria-label="{esc(d["baslik"])}" '
            f'font-family="Segoe UI, Noto Sans, Arial, sans-serif"><defs>{defs}</defs>{"".join(parts + labels)}</svg>')


def diagram_html(d: dict) -> str:
    legend = ('<div class="dg-legend"><span><svg viewBox="0 0 30 8"><path d="M1 4H23" stroke="#475569" '
              'stroke-width="1.6"/><path d="M22 .8 29 4l-7 3.2z" fill="#475569"/></svg>akış sırası</span>'
              '<span><svg viewBox="0 0 30 8"><path d="M1 4H23" stroke="#047857" stroke-width="1.6" '
              'stroke-dasharray="4 3"/><path d="M22 .8 29 4l-7 3.2z" fill="#047857"/></svg>kod, PIN ya da '
              'kendiliğinden</span><span><i class="multi"></i>renkli şerit: işi yapabilen roller</span>'
              '<span><b>§</b> belgedeki bölüm</span><span><i class="dash"></i>panonun kendisi</span></div>')
    return (f'<section class="diagram"><h2 class="dg-title">{icon("flow")}<span>{esc(d["baslik"])}</span></h2>'
            f'<p class="dg-desc">{inline(d.get("aciklama", ""))}</p>{diagram_svg(d)}{legend}</section>')


# ------------------------------------------------------------------ kapak, açıklama, sayfa
def tr_date(texts: list[str]) -> str:
    found = [dt.date(int(y), int(m), int(d)) for t in texts for y, m, d in re.findall(r"\b(20\d\d)-(\d\d)-(\d\d)\b", t)]
    day = max(found) if found else dt.date.today()
    return f"{day.day} {MONTHS[day.month - 1]} {day.year}"


DECO = ('<svg class="cv-deco" viewBox="0 0 420 300" aria-hidden="true"><g fill="#fff">'
        '<circle cx="330" cy="70" r="120" fill-opacity=".07"/><circle cx="380" cy="250" r="90" fill-opacity=".06"/>'
        '</g><path d="M40 250C130 250 120 160 210 160S300 70 380 70" fill="none" stroke="#fff" stroke-opacity=".55" '
        'stroke-width="3" stroke-dasharray="2 9" stroke-linecap="round"/><g fill="#fff" fill-opacity=".95">'
        '<circle cx="40" cy="250" r="15"/><circle cx="210" cy="160" r="19"/><circle cx="380" cy="70" r="24"/></g>'
        '<g fill="none" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">'
        '<path d="M33 250l5 5 9-10" stroke="#0e7490"/><path d="M201 160l6 6 11-12" stroke="#2563eb"/>'
        '<path d="M369 72l12-11 12 11v13h-24z" stroke="#6d28d9"/></g></svg>')


def cover_html(title: str, intro: list[dict], date_text: str, subtitle: str | None, phases: list[dict]) -> str:
    text = " ".join(b["text"] for b in intro if b["t"] == "p")
    audience, about = subtitle, text
    if m := re.match(r"\s*Kimin için:\s*([^.]+)\.\s*(.*)$", text):
        audience, about = subtitle or m[1], m[2]
    keys = list(dict.fromkeys(m.lastgroup for m in ROLE_RE.finditer(audience or "")))
    chips = "".join(chip(label, k) for k in keys for key, label, _, _ in ROLES if key == k)
    aud = ""
    if audience:
        aud = (f'<div class="cv-aud"><div class="cv-lbl">Kimin için</div><p>{inline(audience[:1].upper() + audience[1:])}'
               f'</p><div class="cv-chips">{chips}</div></div>')
    about_html = (f'<div class="cv-about"><div class="ico">{icon("doc")}</div><div><div class="cv-lbl">Belge hakkında'
                  f'</div><p>{inline(about)}</p></div></div>') if about.strip() else ""
    flow = ""
    if phases:  # diyagramdaki aşamalar, bölüm renkleriyle
        arrow = '<svg class="i cv-arrow" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>'
        flow = arrow.join(f'<div class="cv-step" style="{tone_vars("c", section_color(str(p.get("bolum", k))))}">'
                          f'<b>{esc(p["ad"])}</b>' + (f'<small>Bölüm {esc(str(p["bolum"]))}</small>' if p.get("bolum") else "")
                          + "</div>" for k, p in enumerate(phases))
        flow = f'<div class="cv-flow"><div class="cv-lbl">Akışın aşamaları</div><div class="cv-steps">{flow}</div></div>'
    return (f'<section class="cover"><div class="cv-art">{DECO}<div class="cv-brand">{PRODUCT}</div>'
            f'<div class="cv-kind">Akış belgesi</div></div><div class="cv-main"><h1>{inline(title)}</h1>{aud}'
            f'{flow}{about_html}</div><div class="cv-foot"><div><div class="cv-lbl">Belge tarihi</div><b>{date_text}</b>'
            f'</div><div class="cv-co"><b>{COMPANY}</b><span>{COMPANY_SUB}</span></div></div></section>')


def legend_html() -> str:
    chips = " ".join(chip(label, key) for key, label, _, _ in ROLES)
    boxes = "".join(f'<span class="mini" style="{tone_vars("k", c)}">{icon(i)}{k}</span>'
                    for k, (c, i) in CALLOUTS.items() if k in ("Not", "Önemli", "Uyarı", "Dikkat"))
    rows = [("Roller", chips),
            ("Yetki", '<span class="pill yes">Evet</span> <span class="pill no">Hayır</span> '
                      '<span class="pill no strong">Hayır</span> <small>koyu: belgede vurgulanmış</small>'),
            ("Ekran metni", '<span class="ui">“Düğme ya da mesaj”</span> <small>uygulamadaki ya da servis '
                            'yazılımındaki yazı, koddaki gibi</small>'),
            ("Kutular", boxes + ' <small>alıntılar ve bu sözcüklerle başlayan paragraflar</small>'),
            ("Adımlar", '<span class="mini-steps"><i>1</i><b></b><i>2</i><b></b><i>3</i></span> '
                        '<small>sırayla yapılan işler; renk bölüm rengidir</small>')]
    body = "".join(f'<div class="lg-k">{k}</div><div class="lg-v">{v}</div>' for k, v in rows)
    return f'<section class="legend"><h2 class="toc-title">Renkler ve işaretler</h2><div class="lg">{body}</div></section>'


def build_html(md_text: str, cfg: dict) -> tuple[str, str]:
    blocks = parse_blocks(md_text.splitlines())
    h1 = next((k for k, b in enumerate(blocks) if b["t"] == "h" and b["level"] == 1), None)
    title = blocks[h1]["text"] if h1 is not None else cfg.get("baslik", "Belge")
    intro: list[dict] = []
    if h1 is not None and h1 + 1 < len(blocks) and blocks[h1 + 1]["t"] == "quote":
        intro = blocks.pop(h1 + 1)["blocks"]  # ilk alıntı kapağa ("Kimin için", "Belge hakkında") taşınır
    body = Body(cfg)
    main = body.render(blocks)
    dates = [b.get("text", "") for b in intro] + [b["text"] for b in blocks if b["t"] == "h"]
    cover = cover_html(title, intro, cfg.get("tarih") or tr_date(dates), cfg.get("alt_baslik"),
                       cfg.get("diyagram", {}).get("asamalar", []))
    diagram = diagram_html(cfg["diyagram"]) if cfg.get("diyagram") else ""
    css = (HERE / "belge.css").read_text(encoding="utf-8")
    roles_css = "\n".join(f".r-{k}{{color:{shade(c, .1)};background:{mix(c, .9)};border-color:{mix(c, .6)}}}"
                          for k, c in ROLE_COLOR.items())
    footer = f"{title} · {COMPANY}".replace('"', '\\"')
    page = (f'<!doctype html>\n<html lang="tr">\n<head>\n<meta charset="utf-8">\n<title>{esc(title)}</title>\n'
            f'<style>\n{css}\n{roles_css}\n@page {{ @bottom-left {{ content: "{footer}"; }} }}\n</style>\n</head>\n'
            f'<body>\n{cover}\n<div class="front">{body.toc_html()}\n{legend_html()}</div>\n{diagram}\n'
            f'<main>\n{main}\n</main>\n</body>\n</html>\n')
    return title, page


def find_edge() -> str:
    for p in EDGE_PATHS:
        if p and Path(p).is_file():
            return p
    raise SystemExit("Microsoft Edge bulunamadı (EDGE_PATH ortam değişkeniyle yolunu verebilirsiniz).")


def render_pdf(html_path: Path, pdf_path: Path) -> None:
    before = pdf_path.stat().st_mtime if pdf_path.exists() else 0.0
    profile = tempfile.mkdtemp(prefix="belge_pdf_edge_")  # açık Edge pencerelerinden bağımsız profil
    cmd = [find_edge(), "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--no-first-run",
           "--disable-extensions", f"--user-data-dir={profile}", f"--print-to-pdf={pdf_path}", html_path.as_uri()]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180, check=False)
        deadline = time.time() + 20
        while time.time() < deadline:
            if pdf_path.exists() and pdf_path.stat().st_mtime > before and pdf_path.stat().st_size > 0:
                break
            time.sleep(0.5)
        else:
            raise SystemExit(f"PDF üretilemedi ya da güncellenmedi: {pdf_path}")
    finally:
        shutil.rmtree(profile, ignore_errors=True)


def default_config(md_path: Path) -> Path | None:
    stem = md_path.stem.lower()
    for name in (stem, re.sub(r"_akisi$", "", stem)):
        if (HERE / f"{name}.json").is_file():
            return HERE / f"{name}.json"
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Markdown akış belgesini renkli A4 PDF'e çevirir (başsız Edge ile).")
    ap.add_argument("girdi", type=Path, help="Markdown dosyası")
    ap.add_argument("--diagram", type=Path, help="Belge ayarı ve diyagram (JSON). Verilmezse "
                    "tools/belge_pdf/<ad>.json aranır (ör. SERVIS_SORUMLUSU_AKISI.md -> servis_sorumlusu.json)")
    ap.add_argument("--out", type=Path, help="PDF yolu (varsayılan: girdinin yanında, .pdf)")
    ap.add_argument("--html", type=Path, help="Ara HTML'yi bu yola da yaz (varsayılan: geçici klasör)")
    args = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    src = args.girdi.resolve()
    cfg_path = args.diagram or default_config(src)
    cfg = json.loads(cfg_path.read_text(encoding="utf-8")) if cfg_path else {}
    title, page = build_html(src.read_text(encoding="utf-8"), cfg)
    pdf = (args.out or src.with_suffix(".pdf")).resolve()
    pdf.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="belge_pdf_") as tmp:
        html_path = Path(tmp) / f"{pdf.stem}.html"
        html_path.write_text(page, encoding="utf-8")
        if args.html:
            args.html.parent.mkdir(parents=True, exist_ok=True)
            args.html.write_text(page, encoding="utf-8")
        render_pdf(html_path, pdf)
    print(f"{title}: {pdf} ({pdf.stat().st_size // 1024} KB)" + (f", ayar: {cfg_path.name}" if cfg_path else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
