import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/ui/dashboard/labels.dart';
import 'package:flutter_test/flutter_test.dart';

/// Arayüz metin/biçim yardımcılarının (saf fonksiyonlar) davranış testleri: Türkçe harf kuralları,
/// güvenli baş harf/ad, oda adı normalleştirme, rol adları ve zaman/kalan süre biçimleri.
void main() {
  group('Türkçe harf kuralları', () {
    test('büyük harfe çevirirken i -> İ ve ı -> I olur', () {
      expect(turkishUpper('istanbul ılık'), 'İSTANBUL ILIK');
    });

    test('küçük harfe çevirirken İ -> i ve I -> ı olur', () {
      expect(turkishLower('İSTANBUL IŞIK'), 'istanbul ışık');
    });

    test('baş harfler büyütülür, kalan harfler küçültülür ve fazla boşluklar tek boşluğa iner', () {
      expect(turkishTitleCase('ayşe   yılmaz'), 'Ayşe Yılmaz');
      expect(turkishTitleCase('IŞIK ıSITMA'), 'Işık Isıtma');
      expect(turkishTitleCase('iPEK'), 'İpek');
      expect(turkishTitleCase('   '), '');
    });
  });

  group('Baş harf ve ilk ad', () {
    test('ad boş ya da yoksa yedek harf döner (çökmez)', () {
      expect(initialOf(null), 'U');
      expect(initialOf(''), 'U');
      expect(initialOf('   '), 'U');
      expect(initialOf('  ', fallback: '?'), '?');
    });

    test('baş harf Türkçe kurallarıyla büyütülür', () {
      expect(initialOf('ayşe'), 'A');
      expect(initialOf('ışık'), 'I');
      expect(initialOf('ilhan'), 'İ');
    });

    test('emoji ile başlayan ad bile bozuk karakter üretmez', () {
      final initial = initialOf('😀 Ali');
      expect(initial, '😀');
      expect(initial.runes.length, 1, reason: 'yedek çift kodlu karakter ikiye bölünmez');
    });

    test('ilk ad adın ilk sözcüğüdür', () {
      expect(firstNameOf('Ayşe Yılmaz'), 'Ayşe');
      expect(firstNameOf('  Mehmet   Ali  Kaya '), 'Mehmet');
    });

    test('ad yoksa e-postanın yerel kısmı, o da yoksa yedek ad kullanılır (uydurma ad yok)', () {
      expect(firstNameOf('  ', email: 'ayse@example.test'), 'ayse');
      expect(firstNameOf(null), 'Kullanıcı');
      expect(firstNameOf('', email: 'bozuk-adres'), 'Kullanıcı');
      expect(firstNameOf(null, fallback: 'Misafir'), 'Misafir');
    });
  });

  group('Oda adları', () {
    test('sunucudaki farklı yazımlar aynı oda anahtarına iner', () {
      expect(roomKey('yatak_odasi'), 'yatak odasi');
      expect(roomKey('Yatak Odası'), 'yatak odasi');
      expect(roomKey('YATAK-ODASI'), 'yatak odasi');
      expect(roomKey('Çocuk Odası'), 'cocuk odasi');
    });

    test('boş oda adı "genel" olur', () {
      expect(roomKey(''), 'genel');
      expect(roomKey('  _ '), 'genel');
      expect(roomLabel(''), 'Genel');
    });

    test('bilinen odalar okunur ve Türkçe karakterli etiketle gösterilir', () {
      expect(roomLabel('yatak_odasi'), 'Yatak Odası');
      expect(roomLabel('cocuk-odasi'), 'Çocuk Odası');
      expect(roomLabel('bahce'), 'Bahçe');
      expect(roomLabel('SALON'), 'Salon');
    });

    test('bilinmeyen oda adının baş harfleri büyütülür', () {
      expect(roomLabel('bilardo_salonu'), 'Bilardo Salonu');
    });

    test('aynı odanın farklı yazımları tek etiket üretir (çip tekrarı olmaz)', () {
      final labels = <String>{
        for (final raw in ['yatak_odasi', 'Yatak Odası', 'yatak odasi', 'YATAK-ODASI']) roomLabel(raw),
      };
      expect(labels, <String>{'Yatak Odası'});
    });
  });

  group('Rol adları', () {
    test('her ev rolünün ayrı, boş olmayan bir Türkçe adı vardır', () {
      final labels = <String>[
        for (final role in HomeRole.values) homeRoleLabel(role),
      ];
      expect(labels.every((l) => l.isNotEmpty), isTrue);
      // `unknown` ve null aynı "Tanımsız" adını paylaşır; diğerleri benzersizdir.
      expect(labels.toSet().length, HomeRole.values.length);
      expect(homeRoleLabel(HomeRole.owner), 'Ev Sahibi');
      expect(homeRoleLabel(HomeRole.resident), 'Aile Üyesi');
      expect(homeRoleLabel(HomeRole.guest), 'Misafir');
      expect(homeRoleLabel(null), homeRoleLabel(HomeRole.unknown));
    });

    test('her küresel rolün ayrı, boş olmayan bir Türkçe adı vardır', () {
      final labels = <String>[
        for (final role in GlobalRole.values) globalRoleLabel(role),
      ];
      expect(labels.every((l) => l.isNotEmpty), isTrue);
      expect(labels.toSet().length, GlobalRole.values.length);
      expect(globalRoleLabel(GlobalRole.superUser), 'Süper Yönetici');
    });
  });

  group('Zaman ve süre biçimleri', () {
    test('kalan süre bir saatin altında DD:SS, üstünde saat-dakika-saniye olarak yazılır', () {
      expect(formatRemaining(const Duration(seconds: 59)), '00:59');
      expect(formatRemaining(const Duration(minutes: 5, seconds: 7)), '05:07');
      expect(formatRemaining(const Duration(hours: 1, minutes: 2, seconds: 3)), '1 sa 02 dk 03 sn');
    });

    test('süre dolmuşsa (negatif) 00:00 gösterilir, eksi işareti çıkmaz', () {
      expect(formatRemaining(const Duration(seconds: -5)), '00:00');
      expect(formatRemaining(Duration.zero), '00:00');
    });

    test('rakamlar okunaklı gruplanır ama değer değişmez', () {
      expect(groupDigits('123456'), '123 456');
      expect(groupDigits('1234567'), '123 4567');
      expect(groupDigits('123'), '123');
      expect(groupDigits(' 1234 '), '12 34');
    });

    test('aynı gün yalnızca saat, başka gün tarih ve saat gösterilir', () {
      final now = DateTime(2026, 10, 1, 15, 30);
      expect(formatWhen(DateTime(2026, 10, 1, 7, 5), now: now), '07:05');
      expect(formatWhen(DateTime(2026, 9, 30, 23, 59), now: now), '30.09 23:59');
      expect(formatWhen(DateTime(2025, 12, 31, 0, 0), now: now), '31.12 00:00');
    });

    test('saat biçimi iki haneli sıfır dolgulu yazılır', () {
      expect(formatClock(DateTime(2026, 1, 2, 3, 4)), '03:04');
    });
  });
}
