from PIL import Image, ImageDraw
import os

src_path = r"g:\site\ev_otomasyon\assets\images\round_app_logo.png"
img = Image.open(src_path).convert("RGBA")
width, height = img.size

# Yuvarlak maske oluştur
mask = Image.new("L", (width, height), 0)
draw = ImageDraw.Draw(mask)
draw.ellipse((2, 2, width - 2, height - 2), fill=255)

round_img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
round_img.paste(img, (0, 0), mask=mask)

# Ana asset dosyalarını güncelle
round_img.save(r"g:\site\ev_otomasyon\assets\images\round_app_logo.png", format="PNG")
round_img.save(r"g:\site\ev_otomasyon\assets\images\app_logo.png", format="PNG")

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
    target_dir = os.path.join(r"g:\site\ev_otomasyon\android\app\src\main\res", folder)
    os.makedirs(target_dir, exist_ok=True)
    resized.save(os.path.join(target_dir, "ic_launcher.png"), format="PNG")
    resized.save(os.path.join(target_dir, "ic_launcher_round.png"), format="PNG")

# Android drawable için de yüksek çözünürlüklü splash ikonu kaydedelim
drawable_dir = r"g:\site\ev_otomasyon\android\app\src\main\res\drawable"
splash_icon = round_img.resize((288, 288), Image.Resampling.LANCZOS)
splash_icon.save(os.path.join(drawable_dir, "splash_logo.png"), format="PNG")

print("Dairesel logo ve Android launcher ikonlari basariyla hazirlandi!")

