# Deneme listeleri (claude.ai sayfaları)

Proje sahibinin rol rol deneme yaptığı üç sayfa. Her madde "Çalışıyor / Çalışmıyor", "Böyle istiyorum / istemiyorum" ve not
ile işaretlenir; işaretler sayfanın veritabanında (`yanitlar` koleksiyonu) tutulur, Claude `ArtifactData` ile okur/yanıtlar.

| Rol | Sayfa | Madde listesi |
|---|---|---|
| Daire kullanıcısı | https://claude.ai/artifact/UYEqjqJiDEGPyx9aFymsXr | `daire.json` |
| Servis sorumlusu | https://claude.ai/artifact/1oAekG6JTJdYBt9txR4Gmq | `servis.json` |
| Süper kullanıcı | https://claude.ai/artifact/WxV5K1LC6A4Rkd5AjdcHoa | `super.json` |

- **Kayıt biçimi:** belge kimliği = madde kimliğinde nokta yerine alt çizgi (`D5.07` -> `D5_07`). Alanlar: `madde`, `durum`
  (`calisiyor` / `calismiyor` / boş), `istek` (`istiyorum` / `istemiyorum` / boş), `not`, `guncellendi`. Claude'un yanıtı:
  `claude_yanit` (metin), `claude_tarih`, `claude_durum` (`duzeltildi` -> sayfada "Düzeltildi · yeniden deneyin").
- **Sayfayı yeniden üretmek:** `python uret.py [daire|servis|super]` -> `<rol>.html`; aynı URL'ye yayınlanır (Artifact `url`).
  Maddeler değişse de kayıtlar kalır (kimlikleri değiştirmeyin; yeni madde yeni kimlik alır).
- Maddeler 2026-10-09'da akış belgeleri, servis yazılımı rehberi ve koddan çıkarıldı; tırnaklı metinler `lib/` ve servis
  yazılımında birebir doğrulandı.
