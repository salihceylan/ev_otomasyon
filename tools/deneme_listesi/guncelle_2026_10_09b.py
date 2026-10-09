"""2026-10-09 aksam: "Kurulumu sürdür" servis sorumlusuna acildi; super kullaniciya "Rol Değiştir" ve "Kalıcı Sil" eklendi.
Madde kimlikleri degismez (kayitlar korunur); yeni maddeler yeni kimlik alir. Bir kez calistirilir."""
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SMP = 'lib/ui/pages/service_management_page.dart'
DLG = 'lib/ui/pages/service_setup/panel/admin_account_dialogs.dart'
SUB = 'lib/ui/pages/service_subscribers_page.dart'


def load(rol):
    return json.load(io.open(os.path.join(HERE, rol + '.json'), encoding='utf-8'))


def save(rol, v):
    io.open(os.path.join(HERE, rol + '.json'), 'w', encoding='utf-8', newline='\n').write(json.dumps(v, ensure_ascii=False, indent=1))


def section(v, sid):
    return next(b for b in v['bolumler'] if b['id'] == sid)


def item(sid_no, baslik, adimlar, beklenen, on_kosul, kaynak, rol_notu, yeni=True):
    return {'id': sid_no, 'baslik': baslik, 'adimlar': adimlar, 'beklenen': beklenen, 'rol_notu': rol_notu,
            'on_kosul': on_kosul, 'yeni': yeni, 'kaynak': kaynak}


# --- servis ---------------------------------------------------------------------------------------------------------
v = load('servis')
s14 = section(v, 'S14')
ids = [m['id'] for m in s14['maddeler']]
assert 'S14.09' in ids and 'S14.10' not in ids, ids
s14['maddeler'] = [m for m in s14['maddeler'] if m['id'] != 'S14.09'] + [
    item('S14.09', '"Kurulumu sürdür" servis sorumlusuna da görünür ve sihirbazı açar',
         ['Servis sorumlusu hesabıyla "Abonelerim & Cihaz Atama" ekranını açın',
          'Son 72 saatte sizin sahiplendirdiğiniz, kurulumu yarım kalmış (devreye alınmamış) dairenin satırında "Kurulumu sürdür"e basın'],
         'Kurulum sihirbazı o dairenin panosuyla 5. adımdan (Wi-Fi) açılır; dairede birden çok pano varsa önce "Hangi pano?" sorulur. '
         'Devreye alınmış dairede ya da müşteri hesabında düğme görünmez.',
         'son 72 saatte sizin sahiplendirdiğiniz, devreye alınmamış daire', SUB + ':591', 'servis sorumlusu'),
    item('S14.10', 'Kurulum süresi dolmuş dairede "Kurulumu sürdür" yetki iletisi verir',
         ['"Abonelerim & Cihaz Atama" ekranı açıkken dairenin 72 saatlik kurulum süresi dolsun (ya da başka servisin dairesini deneyin)',
          '"Kurulumu sürdür"e basın'],
         '"Bu dairede servis yetkiniz yok. Müşteriden Servis PIN\'i isteyip PIN ile girin." iletisi çıkar, sihirbaz açılmaz. '
         'Liste yenilenince süresi dolan daire listeden düşer; o dairede çalışmak için müşterinin Servis PIN\'iyle girilir.',
         'kurulum süresi (72 saat) dolmuş daire', SUB + ':65', 'servis sorumlusu'),
]
save('servis', v)

# --- super ----------------------------------------------------------------------------------------------------------
v = load('super')
u6 = section(v, 'U6')
ids = [m['id'] for m in u6['maddeler']]
assert ids[-1] == 'U6.15' and 'U6.16' not in ids, ids
R = 'süper kullanıcı'
u6['maddeler'] += [
    item('U6.16', '"Rol Değiştir" ve "Kalıcı Sil" yalnız süper yöneticide ve başkasının hesabında görünür',
         ['Servis Yönetimi > Hesaplar\'da başka bir hesabın kartına bakın', 'Kendi hesabınızın kartına bakın',
          'Servis sorumlusu hesabıyla girip aynı ekrana bakın'],
         'Başka hesabın kartında "Rol Değiştir" ve "Kalıcı Sil" düğmeleri var; kendi kartınızda yok; servis sorumlusu hiçbir kartta görmez.',
         'ikinci bir hesap (servis sorumlusu)', SMP + ':958', R),
    item('U6.17', 'Hesabın rolünü iki adımlı onayla değiştirme',
         ['Hesap kartında "Rol Değiştir"e basın', '"Yeni rol" altında seçin (Süper yönetici / Servis sorumlusu / Müşteri), "Devam"',
          'Onay metnini okuyup "Rolü Değiştir"e basın'],
         'Kısa ileti: "<Ad> hesabının rolü "<Yeni rol>" olarak değiştirildi."; liste yenilenir. O kişinin tüm oturumları kapanır, '
         'yeniden giriş yapınca yeni rolüyle açılır.',
         'deneme amaçlı ikinci bir hesap', SMP + ':274', R),
    item('U6.18', 'Servis sorumlusunu müşteriye düşürünce servis üyelikleri kalkar',
         ['Servis üyeliği olan bir servis sorumlusu hesabında "Rol Değiştir" > "Müşteri" > "Devam"', 'Onay ekranındaki uyarıyı okuyup onaylayın',
          'O hesapla girip "Abonelerim & Cihaz Atama"ya bakmayı deneyin'],
         'Onay ekranında "Dairelerdeki servis üyelikleri kaldırılır." yazar; değişiklikten sonra hesap müşteri olur ve servis ekranlarını göremez.',
         'en az bir dairede servis üyeliği olan deneme servis sorumlusu hesabı', DLG + ':604', R),
    item('U6.19', 'Silinmiş hesap "Silinmiş" etiketiyle görünür, rolü değiştirilemez',
         ['Hesaplar listesinde daha önce silinmiş (kalıcı olmayan silme) bir hesabı bulun', 'Kartındaki "Rol Değiştir" düğmesine bakın'],
         'Durum etiketi "Silinmiş" (eskiden "Donduruldu" görünüyordu); "Rol Değiştir" pasif, altında "Silinmiş hesabın rolü değiştirilemez." notu var.',
         'silinmiş bir hesap', 'lib/ui/pages/service_setup/panel/admin_account.dart:218', R),
    item('U6.20', 'Kalıcı silme, e-posta doğru yazılmadan yapılamaz',
         ['Hesap kartında "Kalıcı Sil"e basın', 'Onay kutusuna e-postayı eksik ya da yanlış yazın', '"Vazgeç"e basın'],
         '"Bu işlem geri alınamaz." uyarısı görünür; e-posta tam eşleşmedikçe "Kalıcı Olarak Sil" pasif kalır; "Vazgeç" ile hiçbir şey silinmez.',
         'deneme amaçlı ikinci bir hesap', DLG + ':866', R),
    item('U6.21', 'Panosuz hesabı kalıcı silme',
         ['Panosu olan dairesi bulunmayan deneme hesabında "Kalıcı Sil"', 'Hesabın e-postasını tam yazın', '"Kalıcı Olarak Sil"e basın'],
         'Kısa ileti "Kullanıcı kalıcı olarak silindi." (boş daire kaydı da silindiyse "… (üyesi ve panosu olmayan N daire kaydı da silindi).") '
         've hesap listeden kalkar. Gerçek müşteri hesabıyla denemeyin: geri alınamaz.',
         'silinebilecek deneme hesabı (panolu dairesi yok)', DLG + ':866', R),
    item('U6.22', 'Panolu dairenin tek sahibi kalıcı silinemez',
         ['Panosu takılı bir dairenin tek sahibi olan deneme hesabında "Kalıcı Sil"', 'E-postayı yazıp "Kalıcı Olarak Sil"e basın'],
         'Pencerede "Kullanıcı, panosu olan bir dairenin tek sahibi. Kalıcı silmeden önce daireyi devredin ya da panoya acil sıfırlama yapın." '
         'yazar; hesap silinmez.',
         'panosu takılı bir dairenin tek sahibi olan deneme hesabı', 'server/src/services/admin_user_service.js', R),
]
save('super', v)
print('servis S14:', len(s14['maddeler']), 'super U6:', len(u6['maddeler']))
