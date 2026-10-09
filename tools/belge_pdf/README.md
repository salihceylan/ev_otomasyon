# belge_pdf: akış belgelerini renkli PDF'e çevirme

`docs/akislar/*.md` gibi Türkçe akış belgelerini kapaklı, içindekiler sayfalı, renkli A4 PDF'e çevirir.
Yalnız Python standart kütüphanesi kullanılır. PDF'i başsız (headless) Microsoft Edge basar.

## Yeniden üretme

Markdown değişince aynı komutu yeniden çalıştırmanız yeterli (depo kökünden):

```powershell
$py = "ev_otomasyon_servis_yazilimi\.venv\Scripts\python.exe"
& $py tools\belge_pdf\belge_pdf.py docs\akislar\SERVIS_SORUMLUSU_AKISI.md
& $py tools\belge_pdf\belge_pdf.py docs\akislar\DAIRE_KULLANICISI_AKISI.md
```

PDF, Markdown dosyasının yanına aynı adla (`.pdf`) yazılır. Seçenekler:

| Seçenek | Anlamı |
|---|---|
| `--diagram <ayar.json>` | Belge ayarı ve genel akış diyagramı. Verilmezse `tools/belge_pdf/<ad>.json` aranır: `SERVIS_SORUMLUSU_AKISI.md` için `servis_sorumlusu.json` |
| `--out <çıktı.pdf>` | PDF'in yolu |
| `--html <kopya.html>` | Ara HTML'nin bir kopyası (varsayılan: geçici klasöre yazılır, sonra silinir) |

Edge başka bir yerdeyse `EDGE_PATH` ortam değişkeniyle yolunu verin. Edge açık pencerelerinizden
bağımsız, geçici bir profille çalışır.

## Dosyalar

- `belge_pdf.py`: Markdown çözümleyici, HTML üretici, SVG diyagram çizici ve Edge ile PDF basımı.
- `belge.css`: A4 baskı stili (kapak, bölüm bantları, adım akışı, kutular, tablolar, sayfa numarası).
- `servis_sorumlusu.json`, `daire_kullanicisi.json`: belgeye özel ayar ve elle tasarlanmış diyagram.

## Markdown'dan neler üretilir

- **Kapak:** `#` başlığı belgenin adı olur. Hemen altındaki ilk alıntı (`>`) kapağa taşınır: "Kimin için: …"
  cümlesi alt başlık ve rol çipleri olur, kalanı "Belge hakkında" kutusuna girer. Tarih, bu alıntıdaki ve
  başlıklardaki en yeni `YYYY-AA-GG` tarihidir. Diyagramdaki aşamalar kapakta "Akışın aşamaları" olarak görünür.
- **İçindekiler:** `##` ve `###` başlıklarından kendiliğinden (tıklanabilir bağlantılar). Sayfa numarası her
  sayfanın altında ("Sayfa N / M").
- **Bölüm bantları:** `## 3. Başlık` renkli bant olur. Renk bölüm numarasından gelir ve bölüm içindeki adım
  dairelerinde, tablo başlığında, kapaktaki ve diyagramdaki "Bölüm 3" rozetinde aynıdır.
- **Rol çipleri:** Süper kullanıcı, Servis sorumlusu, Servis oturumu (ya da "Geçici servis"), Ev sahibi,
  Aile üyesi (ya da "Ev üyesi"), Misafir, Bireysel kullanıcı. Başlıklarda, tablo başlıklarında ve
  `**Servis sorumlusu:**` gibi tek başına kalın yazılmış rol adlarında çip olur. Renkler `ROLES` listesindedir.
- **Yetki rozetleri:** tablo hücresi "Evet" ya da "Hayır" ile başlıyorsa yeşil/kırmızı rozet olur; kalın yazılmışsa
  koyu rozet.
- **Kutular:** her alıntı (`>`) renkli bilgi kutusu olur. `Dikkat:`, `Uyarı:`, `Önemli:`, `Not:`, `İpucu:` ile başlayan
  paragraf ya da alıntı (kalın da olabilir) simgeli renkli kutu olur. Böyle başlayan liste maddesi de renklenir.
- **Ekran metni:** tırnak içindeki metin ("Düğme adı") hafif renkli zeminle gösterilir.
- **Liste biçimleri:** numaralı liste, hemen üstündeki başlığa göre seçilir:
  - `adim_basliklari` (ayar dosyası) ile eşleşen başlıklar: dikey adım akışı (çizgiyle bağlı numaralı daireler);
  - "değişenler": iki sütunlu kartlar; "kontrol listesi": işaretlenecek kutular;
  - diğerleri: renkli numaralı olağan liste.
- **Desteklenen Markdown:** `#`–`####` başlık, paragraf, `**kalın**`, `*italik*`, `` `kod` ``, iç içe numaralı ve
  madde listeler, alıntı, tablo (hizalama dahil), `---`, bağlantı (yalnız metni basılır), `\.` gibi kaçışlar.
  Bir maddenin metni sayıyla başlıyorsa ("1. 4. sekmede …") baştaki sayı metin sayılır, iç liste değil.

## Ayar dosyası (JSON)

```json
{
  "adim_basliklari": ["^Adımlar$", "montaj ve test"],
  "kart_basliklari": ["değişenler"],
  "kontrol_basliklari": ["kontrol listesi"],
  "alt_baslik": "isteğe bağlı, kapaktaki 'Kimin için' metninin yerine",
  "tarih": "isteğe bağlı, ör. 9 Ekim 2026",
  "diyagram": {
    "baslik": "Genel akış: …",
    "aciklama": "Diyagramın üstündeki kısa açıklama",
    "kulvarlar": ["Süper kullanıcı", "Servis sorumlusu", "Ev sahibi", "Pano"],
    "asamalar": [{"ad": "Ofis", "bolum": "2", "satirlar": [1, 2]}],
    "kutular": [
      {"id": "site", "satir": 1, "kulvar": "Süper kullanıcı", "kulvar_son": "Servis sorumlusu",
       "baslik": "Site, daire ve şablon", "metin": "kısa açıklama", "bolum": "2.2"}
    ],
    "oklar": [{"den": "site", "e": "kayit", "etiket": "isteğe bağlı", "kesikli": false}]
  }
}
```

Başlık eşleşmeleri düzenli ifadedir ve başlığın numarasız metnine uygulanır (büyük/küçük harf fark etmez).

Diyagram kuralları:

- Sütunlar (`kulvarlar`) rol adı ya da `Pano` olmalıdır; renkleri rol renkleridir, `Pano` gri ve kesik çizgilidir.
- Her kutu bir satıra (`satir`) ve bir sütuna yerleşir. `kulvar_son` verilirse kutu yan yana sütunlara yayılır ve
  üst şeridi her rolün renginde olur (o işi birden çok rol yapabilir demektir).
- `asamalar` satır aralıklarını adlandırır. Soldaki gri bandın rozeti bölüm rengindedir.
- Oklar kendiliğinden çizilir. Aynı satırdaki kutular arasında ok yataydır, aradaki sütunlar o satırda boş olmalıdır.
  Alt satıra giden ok, sütunlar örtüşüyorsa düz iner, örtüşmüyorsa hedefin üstündeki boşlukta dirsek yapar.
  Kaynağın altında, aradaki satırlarda aynı sütun boş olmalıdır. `kesikli: true`, kod/PIN alışverişi ya da
  panonun kendiliğinden yaptığı iş içindir.
- Kutu metinleri satır sığmazsa kendiliğinden kaydırılır. Elle bölmek için `\n` kullanın.

Belgedeki bölüm numaraları ya da ana akış değişirse diyagramdaki `§` bölüm etiketlerini ve kutuları
belgeyle karşılaştırın. Diyagram belgeden kendiliğinden üretilmez.

## Kontrol

PDF'i açıp her sayfaya bakın. Neredeyse boş sayfa, kesik tablo ya da kutu olmamalı. Diyagram tek sayfaya
sığmalı. Diyagram sığmazsa kutu metinlerini kısaltın ya da satır sayısını azaltın.
