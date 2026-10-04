"""Tam boyutlu ana logodan (assets_src/round_app_logo.png) yuvarlak launcher ikonları ve paket içi logolar üretir.

Ana kopya (assets_src/) DEĞİŞTİRİLMEZ: yuvarlak maske yalnız türetilen dosyalara uygulanır (maskeyi ana
kopyanın üstüne yazmak her çalıştırmada kenardan 2 px kırpardı).
Kök dizin bu dosyanın konumundan türetilir: ana ağaçta da geliştirme kopyasında da çalışır.
"""
from pathlib import Path
from PIL import Image, ImageDraw
import os

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "assets_src"
IMAGES_DIR = ROOT / "assets" / "images"
RES_DIR = ROOT / "android" / "app" / "src" / "main" / "res"

# Pakete giren logolar (px). En büyük kullanım 130 dp (3,5x ≈ 455 px); 1024x1024 RGBA ≈ 4 MiB çözülür.
# round_app_logo.png ile app_logo.png AYNI baytlar olmamalı (farklı yol = ayrı ImageCache girdisi).
PACKAGED_LOGOS = {"round_app_logo.png": 512, "app_logo.png": 256}

src_path = SRC_DIR / "round_app_logo.png"
img = Image.open(src_path).convert("RGBA")
width, height = img.size

# Yuvarlak maske oluştur
mask = Image.new("L", (width, height), 0)
draw = ImageDraw.Draw(mask)
draw.ellipse((2, 2, width - 2, height - 2), fill=255)

round_img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
round_img.paste(img, (0, 0), mask=mask)

# Paket içi logolar (assets/images/): küçültülmüş sürümler
IMAGES_DIR.mkdir(parents=True, exist_ok=True)
for name, size in PACKAGED_LOGOS.items():
    round_img.resize((size, size), Image.Resampling.LANCZOS).save(IMAGES_DIR / name, format="PNG", optimize=True)

# Mipmap klasörlerini güncelle
mipmaps = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

for folder, dim in mipmaps.items():
    resized = round_img.resize((dim, dim), Image.Resampling.LANCZOS)
    target_dir = os.path.join(str(RES_DIR), folder)
    os.makedirs(target_dir, exist_ok=True)
    resized.save(os.path.join(target_dir, "ic_launcher.png"), format="PNG")
    resized.save(os.path.join(target_dir, "ic_launcher_round.png"), format="PNG")

# drawable/splash_logo.png artık ÜRETİLMEZ: hiçbir XML/Kotlin dosyasında referanssızdı ve kaldırıldı.
# Native açılış bitmap'i için scripts/generate_hd_splash.py kullanılır.

print("Dairesel logo ve Android launcher ikonlari basariyla hazirlandi!")
