"""İnce halkalı kaynak logodan Android adaptive/legacy launcher ikonlarını ve paket içi logoları üretir.

Dizin düzeni (WP-BOOT, PF-16/PF-17):
  assets_src/    tam boyutlu ana kopyalar ve kaynaklar (pakete GİRMEZ)
  assets/images/ yalnız pakete giren dosyalar (pubspec.yaml'daki AÇIK liste)
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


def save_packaged_logos(logo):
    """Tam boyutlu logodan pakete giren küçük sürümleri üretir."""
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)
    for name, size in PACKAGED_LOGOS.items():
        logo.resize((size, size), Image.Resampling.LANCZOS).save(IMAGES_DIR / name, format="PNG", optimize=True)


src_path = SRC_DIR / "round_app_logo_thin_ring.png"
logo = Image.open(src_path).convert("RGBA")

# 1. Ana kopya (tam boyut, assets_src/) ve paket içi küçük logolar
SRC_DIR.mkdir(parents=True, exist_ok=True)
logo.save(SRC_DIR / "round_app_logo.png", format="PNG")
save_packaged_logos(logo)

# 2. Android mipmap klasörleri
res_dir = str(RES_DIR)

# Adaptive icon foreground boyutları (108dp standardı)
adaptive_sizes = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# Legacy icon boyutları (48dp standardı)
legacy_sizes = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

for folder, total_size in adaptive_sizes.items():
    folder_path = os.path.join(res_dir, folder)
    os.makedirs(folder_path, exist_ok=True)

    # Adaptive Foreground: 108dp canvas üzerinde güvenli alanı dolduran büyük logo
    # Standart safe zone %66'dır ama Gmail/Chrome gibi dopdolu görünmesi için %76 ölçekliyoruz
    fg_canvas = Image.new("RGBA", (total_size, total_size), (0, 0, 0, 0))
    logo_size = int(total_size * 0.76)
    resized_logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
    offset = (total_size - logo_size) // 2
    fg_canvas.paste(resized_logo, (offset, offset), mask=resized_logo)
    fg_canvas.save(os.path.join(folder_path, "ic_launcher_foreground.png"), format="PNG")

    # Legacy Launcher Icons (Dopdolu tam kenar)
    leg_size = legacy_sizes[folder]
    leg_img = logo.resize((leg_size, leg_size), Image.Resampling.LANCZOS)
    leg_img.save(os.path.join(folder_path, "ic_launcher.png"), format="PNG")
    leg_img.save(os.path.join(folder_path, "ic_launcher_round.png"), format="PNG")

# 3. Native açılış görseli bu betikle ÜRETİLMEZ: drawable/splash_logo.png hiçbir XML/Kotlin dosyasında
#    referanssızdı ve kaldırıldı. Açılış bitmap'i için scripts/generate_hd_splash.py kullanılır.

print("Tüm Android Adaptive ve Legacy ikonları başarıyla üretildi!")
