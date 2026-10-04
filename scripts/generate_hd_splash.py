"""Native Android açılış bitmap'ini (drawable-nodpi/splash_screen_full.webp) üretir.

* Çıktı drawable-nodpi/ altındadır: drawable/ (yoğunluksuz) içindeki bitmap'i sistem yoğunluk oranıyla büyütür.
* Biçim kayıplı WebP (kalite 90): görünüm aynı, PNG'ye göre yaklaşık 10 kat küçük.
* Kök dizin bu dosyanın konumundan türetilir (ana ağaç / geliştirme kopyası fark etmez).
"""
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
bg_path = ROOT / "assets" / "images" / "ai_circuit_bg.jpg"
logo_path = ROOT / "assets_src" / "round_app_logo.png"  # tam boyutlu ana kopya (pakete girmez)
out_path = ROOT / "android" / "app" / "src" / "main" / "res" / "drawable-nodpi" / "splash_screen_full.webp"

# Hedef çözünürlük: Modern telefon standardı (1080 x 2400)
W, H = 1080, 2400

# 1. Arka plan devre görselini aç ve ölçekle
bg = Image.open(bg_path).convert("RGBA")
bg = bg.resize((W, H), Image.Resampling.LANCZOS)

# 2. Üzerine siber karartma gradyanı uygula (devreler net görünsün)
overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)
for y in range(H):
    # Üstten alta yumuşak koyulaşma (%30'dan %65'e)
    ratio = y / H
    alpha = int(255 * (0.30 + ratio * 0.35))
    draw.line([(0, y), (W, y)], fill=(7, 11, 20, alpha))

canvas = Image.alpha_composite(bg, overlay)

# 3. Ortadaki parlayan neon logoyu hazırla
logo = Image.open(logo_path).convert("RGBA")
logo_size = 380
logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)

# Neon ışık parıltısı (Glow)
glow = Image.new("RGBA", (logo_size + 160, logo_size + 160), (0, 0, 0, 0))
glow_draw = ImageDraw.Draw(glow)
center = (logo_size + 160) // 2
glow_radius = (logo_size // 2) + 20
glow_draw.ellipse(
    (center - glow_radius, center - glow_radius, center + glow_radius, center + glow_radius),
    fill=(56, 189, 248, 120),
)
glow = glow.filter(ImageFilter.GaussianBlur(30))

logo_x = (W - logo_size) // 2
logo_y = int(H * 0.36)

glow_x = logo_x - 80
glow_y = logo_y - 80

canvas.paste(glow, (glow_x, glow_y), mask=glow)
canvas.paste(logo, (logo_x, logo_y), mask=logo)

# 4. Yazıları ve yükleme kartını çiz
draw_canvas = ImageDraw.Draw(canvas)

# Başlık: AHBU OTOMASYON
# Font bulmaya çalış (Windows Arial veya default)
try:
    font_title = ImageFont.truetype("arialbd.ttf", 64)
    font_sub = ImageFont.truetype("arialbd.ttf", 30)
    font_card = ImageFont.truetype("arial.ttf", 34)
except:
    font_title = ImageFont.load_default()
    font_sub = ImageFont.load_default()
    font_card = ImageFont.load_default()

title_text = "AHBU OTOMASYON"
bbox_title = draw_canvas.textbbox((0, 0), title_text, font=font_title)
t_w = bbox_title[2] - bbox_title[0]
draw_canvas.text(((W - t_w) // 2, logo_y + logo_size + 50), title_text, fill=(255, 255, 255, 255), font=font_title)

# Alt başlık rozeti
sub_text = "YAPAY ZEKA DESTEKLİ AKILLI YAŞAM"
bbox_sub = draw_canvas.textbbox((0, 0), sub_text, font=font_sub)
s_w = bbox_sub[2] - bbox_sub[0]
s_h = bbox_sub[3] - bbox_sub[1]

badge_x1 = (W - s_w) // 2 - 30
badge_y1 = logo_y + logo_size + 140
badge_x2 = badge_x1 + s_w + 60
badge_y2 = badge_y1 + s_h + 24

draw_canvas.rounded_rectangle([badge_x1, badge_y1, badge_x2, badge_y2], radius=24, fill=(56, 189, 248, 35), outline=(56, 189, 248, 70), width=2)
draw_canvas.text(((W - s_w) // 2, badge_y1 + 10), sub_text, fill=(125, 211, 252, 255), font=font_sub)

# Yükleme kartı (Oturum güvenli şekilde doğrulanıyor...)
card_w = 760
card_h = 130
card_x = (W - card_w) // 2
card_y = badge_y2 + 80

draw_canvas.rounded_rectangle([card_x, card_y, card_x + card_w, card_y + card_h], radius=32, fill=(15, 23, 42, 190), outline=(56, 189, 248, 60), width=2)

# Spinner simgesi & Metin
card_text = "Oturum güvenli şekilde doğrulanıyor..."
bbox_card = draw_canvas.textbbox((0, 0), card_text, font=font_card)
c_w = bbox_card[2] - bbox_card[0]

# Küçük cyan dönen halka
spin_r = 16
spin_cx = (W - c_w) // 2 - 30
spin_cy = card_y + (card_h // 2)
draw_canvas.arc([spin_cx - spin_r, spin_cy - spin_r, spin_cx + spin_r, spin_cy + spin_r], start=45, end=300, fill=(56, 189, 248, 255), width=4)

draw_canvas.text(((W - c_w) // 2 + 15, card_y + (card_h - (bbox_card[3] - bbox_card[1])) // 2), card_text, fill=(203, 213, 225, 255), font=font_card)

# Kaydet (kayıplı WebP; drawable-nodpi/ altında)
out_path.parent.mkdir(parents=True, exist_ok=True)
canvas.convert("RGB").save(out_path, "WEBP", quality=90, method=6)
print(f"Yüksek çözünürlüklü Android native splash başarıyla üretildi: {out_path} ({W}x{H})")

