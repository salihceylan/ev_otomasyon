# -*- coding: utf-8 -*-
"""Küçük, bağımsız QR çözücü - YALNIZCA test içindir (test modülü değil, yardımcı modüldür).

Amaç: etiket görselindeki karekodların GERÇEKTEN beklenen metni taşıdığını, etiketi üreten koddan bağımsız bir yolla
(telefon kamerası/uygulama olmadan) doğrulamak. Çözücü temiz, eksen hizalı ve tek bir QR içeren bölgeleri çözer.

Kapsam: sürüm 1-10, hata düzeltme L/M/Q/H, sayısal / alfasayısal / bayt kipleri. Reed-Solomon hata düzeltmesi
UYGULANMAZ: görüntü bilgisayarda kusursuz üretildiği için gerekmez (bozuk bir görüntü ya hata verir ya da farklı metin döner).
Blok yapısı ve hizalama konumları tabloları ``qrcode`` kütüphanesinden alınır (yeni paket gerekmez).
"""
from __future__ import annotations

from typing import Optional

try:  # qrcode yoksa etiket testleri zaten atlanır; bu modülün içe aktarımı yine de başarılı olmalı
    import qrcode.base as _qr_base
    import qrcode.util as _qr_util
except ImportError:  # pragma: no cover - ortam sorunu
    _qr_base = _qr_util = None

ALNUM_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
_MAX_VERSION = 10


class QrDecodeError(Exception):
    """Görüntüde çözülebilir bir karekod bulunamadı veya bozuk."""


def _is_dark(gray, x: int, y: int) -> bool:
    return gray.getpixel((x, y)) < 128


def _finder_ok(sample, n: int) -> bool:
    """Üç köşedeki 7x7 bulucu desen doğru mu? (halka: dış=koyu, 2. halka=açık, çekirdek 3x3=koyu)"""
    for top, left in ((0, 0), (0, n - 7), (n - 7, 0)):
        for r in range(7):
            for c in range(7):
                ring = max(abs(r - 3), abs(c - 3))
                expected = ring in (0, 1, 3)
                if sample(top + r, left + c) != expected:
                    return False
    return True


def _locate(gray, box):
    """Bölgedeki koyu piksellerin sınır kutusundan (QR sembolü) modül boyutunu ve sürümü bulur."""
    x0, y0, x1, y1 = box
    dark = gray.crop(box).point(lambda value: 255 if value < 128 else 0)
    bbox = dark.getbbox()
    if bbox is None:
        raise QrDecodeError("bölgede karekod yok")
    left, top, right, bottom = bbox
    width, height = right - left, bottom - top
    if width != height:
        raise QrDecodeError("karekod kare değil (%dx%d)" % (width, height))
    origin_x, origin_y = x0 + left, y0 + top
    for version in range(1, _MAX_VERSION + 1):
        n = 17 + 4 * version
        if width % n:
            continue
        module = width // n

        def sample(row, col, _m=module, _ox=origin_x, _oy=origin_y):
            return _is_dark(gray, _ox + col * _m + _m // 2, _oy + row * _m + _m // 2)

        if _finder_ok(sample, n):
            return origin_x, origin_y, module, version
    raise QrDecodeError("karekod boyutu/bulucu desenleri uyuşmuyor (genişlik %d)" % width)


def _function_modules(version: int) -> list[list[bool]]:
    n = 17 + 4 * version
    func = [[False] * n for _ in range(n)]

    def block(r0: int, c0: int, h: int, w: int) -> None:
        for r in range(max(r0, 0), min(r0 + h, n)):
            for c in range(max(c0, 0), min(c0 + w, n)):
                func[r][c] = True

    block(0, 0, 9, 9)          # sol-üst bulucu + ayırıcı + biçim bilgisi
    block(0, n - 8, 9, 8)      # sağ-üst
    block(n - 8, 0, 8, 9)      # sol-alt (karanlık modül dahil)
    for i in range(n):         # zamanlama desenleri
        func[6][i] = True
        func[i][6] = True
    centers = _qr_util.PATTERN_POSITION_TABLE[version - 1]
    for r in centers:
        for c in centers:
            if (r <= 8 and c <= 8) or (r <= 8 and c >= n - 9) or (r >= n - 9 and c <= 8):
                continue       # bulucu desenle çakışan hizalama deseni yok
            block(r - 2, c - 2, 5, 5)
    if version >= 7:           # sürüm bilgisi blokları
        block(0, n - 11, 6, 3)
        block(n - 11, 0, 3, 6)
    return func


def _mask(pattern: int, i: int, j: int) -> bool:
    return (
        (i + j) % 2 == 0,
        i % 2 == 0,
        j % 3 == 0,
        (i + j) % 3 == 0,
        (i // 2 + j // 3) % 2 == 0,
        (i * j) % 2 + (i * j) % 3 == 0,
        ((i * j) % 2 + (i * j) % 3) % 2 == 0,
        ((i + j) % 2 + (i * j) % 3) % 2 == 0,
    )[pattern]


def _read_format(matrix) -> tuple[int, int]:
    """Biçim bilgisi (kütüphane kodlamasıyla hata düzeltme düzeyi, maske deseni)."""
    n = len(matrix)
    bits = 0
    for i in range(15):
        if i < 6:
            r, c = i, 8
        elif i < 8:
            r, c = i + 1, 8
        else:
            r, c = n - 15 + i, 8
        bits |= (1 if matrix[r][c] else 0) << i
    data = (bits ^ 0x5412) >> 10
    return data >> 3, data & 7


def _data_codewords(matrix, version: int) -> list[int]:
    n = len(matrix)
    ecl, mask = _read_format(matrix)
    func = _function_modules(version)
    positions = []
    col = n - 1
    upward = True
    while col > 0:
        if col == 6:
            col -= 1
        rows = range(n - 1, -1, -1) if upward else range(n)
        for r in rows:
            for c in (col, col - 1):
                if not func[r][c]:
                    positions.append((r, c))
        upward = not upward
        col -= 2
    bits = [(1 if matrix[r][c] else 0) ^ (1 if _mask(mask, r, c) else 0) for r, c in positions]
    codewords = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits) - len(bits) % 8, 8)]
    blocks = _qr_base.rs_blocks(version, ecl)
    if len(codewords) < sum(b.total_count for b in blocks):
        raise QrDecodeError("veri kod sözcüğü sayısı yetersiz")
    per_block: list[list[int]] = [[] for _ in blocks]
    cursor = 0
    for index in range(max(b.data_count for b in blocks)):
        for number, block in enumerate(blocks):
            if index < block.data_count:
                per_block[number].append(codewords[cursor])
                cursor += 1
    return [value for chunk in per_block for value in chunk]


class _Bits:
    def __init__(self, data: list[int]) -> None:
        self._bits = "".join(format(value, "08b") for value in data)
        self._pos = 0

    def left(self) -> int:
        return len(self._bits) - self._pos

    def read(self, count: int) -> int:
        if self.left() < count:
            raise QrDecodeError("veri akışı beklenenden kısa")
        value = int(self._bits[self._pos:self._pos + count], 2)
        self._pos += count
        return value


def _parse(data: list[int], version: int) -> str:
    bits = _Bits(data)
    small = version <= 9
    out = bytearray()
    while bits.left() >= 4:
        mode = bits.read(4)
        if mode == 0:  # sonlandırıcı
            break
        if mode == 1:  # sayısal
            count = bits.read(10 if small else 12)
            text = ""
            while count >= 3:
                text += "%03d" % bits.read(10)
                count -= 3
            if count == 2:
                text += "%02d" % bits.read(7)
            elif count == 1:
                text += "%d" % bits.read(4)
            out += text.encode("ascii")
        elif mode == 2:  # alfasayısal
            count = bits.read(9 if small else 11)
            text = ""
            while count >= 2:
                pair = bits.read(11)
                text += ALNUM_CHARS[pair // 45] + ALNUM_CHARS[pair % 45]
                count -= 2
            if count == 1:
                text += ALNUM_CHARS[bits.read(6)]
            out += text.encode("ascii")
        elif mode == 4:  # bayt
            count = bits.read(8 if small else 16)
            out += bytes(bits.read(8) for _ in range(count))
        else:
            raise QrDecodeError("desteklenmeyen kip: %d" % mode)
    try:
        return out.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise QrDecodeError("veri geçerli UTF-8 değil") from exc


def label_qr_boxes(tool, record) -> tuple[tuple[int, int, int, int], tuple[int, int, int, int]]:
    """Aracın etiket düzenine göre (sol-üst x, y, sağ-alt x, y): 1. (claim) ve 2. (Wi-Fi) karekod bölgeleri.
    2. karekod üretilemeyen kayıtta ikinci bölge, uyarı kutusunun yeridir (1. karekodla aynı boyut)."""
    claim = tool.make_qr_image(tool.label_qr_payload(record))
    wifi_payload = tool.label_wifi_qr_payload(record)
    wifi = tool.make_qr_image(wifi_payload) if wifi_payload else claim
    (claim_x, claim_y), (wifi_x, wifi_y) = tool.label_qr_positions(claim.size, wifi.size)
    return (
        (claim_x, claim_y, claim_x + claim.width, claim_y + claim.height),
        (wifi_x, wifi_y, wifi_x + wifi.width, wifi_y + wifi.height),
    )


def decode_qr_image(image, box: Optional[tuple[int, int, int, int]] = None) -> str:
    """``image`` (veya ``box`` bölgesi) içindeki TEK karekodu çözer ve metnini döndürür."""
    if _qr_base is None or _qr_util is None:
        raise QrDecodeError("qrcode kütüphanesi yok (blok/hizalama tabloları alınamıyor)")
    gray = image.convert("L")
    region = box if box is not None else (0, 0, gray.width, gray.height)
    origin_x, origin_y, module, version = _locate(gray, region)
    n = 17 + 4 * version
    matrix = [
        [_is_dark(gray, origin_x + c * module + module // 2, origin_y + r * module + module // 2) for c in range(n)]
        for r in range(n)
    ]
    return _parse(_data_codewords(matrix, version), version)
