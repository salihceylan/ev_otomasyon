import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';

const String _home = '3f2b8c1e-9d4a-4e7b-a1c2-5d6e7f8a9b0c';

/// Kaynak dosyaya görünmez/çift yönlü karakter yazmamak için kod noktasından metin üretir.
String _c(int codePoint) => String.fromCharCode(codePoint);

Map<String, dynamic> _data({Map<String, dynamic>? override, List<String> remove = const <String>[]}) {
  final map = <String, dynamic>{
    'type': 'peace_open_devices',
    'home_id': _home,
    'notice_id': '41',
    'open_lights': '2',
    'open_shutters': '1',
    'action': 'close_all',
    'v': '1',
    ...?override,
  };
  for (final key in remove) {
    map.remove(key);
  }
  return map;
}

/// Her okumada fırlatan, düşmanca bir harita.
class _ThrowingMap extends MapBase<String, dynamic> {
  @override
  dynamic operator [](Object? key) => throw StateError('okuma hatası');

  @override
  void operator []=(String key, dynamic value) {}

  @override
  void clear() {}

  @override
  Iterable<String> get keys => const <String>[];

  @override
  dynamic remove(Object? key) => null;
}

void main() {
  _emptyNoticeIdTests();
  _fromSettingsTests();
  final fixedNow = DateTime.utc(2026, 10, 1, 20, 30);

  group('PeaceNotice.tryParse geçerli girdi', () {
    test('sunucu sözleşmesindeki tüm alanları okur', () {
      final notice = PeaceNotice.tryParse(
        _data(),
        title: 'Evim',
        body: 'Salonda 2 lamba, 1 panjur açık.',
        source: PeaceNoticeSource.opened,
        now: fixedNow,
      );
      expect(notice, isNotNull);
      expect(notice!.homeId, _home);
      expect(notice.noticeId, 41);
      expect(notice.openLights, 2);
      expect(notice.openShutters, 1);
      expect(notice.title, 'Evim');
      expect(notice.body, 'Salonda 2 lamba, 1 panjur açık.');
      expect(notice.source, PeaceNoticeSource.opened);
      expect(notice.receivedAt, fixedNow);
    });

    test('kaynak varsayılanı foreground, now verilmezse şimdiki zaman', () {
      final before = DateTime.now();
      final notice = PeaceNotice.tryParse(_data())!;
      expect(notice.source, PeaceNoticeSource.foreground);
      expect(notice.receivedAt.isBefore(before), isFalse);
    });

    test('notice_id yoksa ya da null ise noticeId null olur', () {
      expect(PeaceNotice.tryParse(_data(remove: ['notice_id']))!.noticeId, isNull);
      expect(PeaceNotice.tryParse(_data(override: {'notice_id': null}))!.noticeId, isNull);
    });

    test('action ve v alanları yoksa kabul edilir', () {
      expect(PeaceNotice.tryParse(_data(remove: ['action', 'v'])), isNotNull);
    });

    test('bilinmeyen ek alanlar yok sayılır', () {
      final notice = PeaceNotice.tryParse(_data(override: {'future_field': 'x', 'extra': '1'}));
      expect(notice, isNotNull);
    });

    test('yalnızca lamba ya da yalnızca panjur açıkken kabul edilir', () {
      expect(PeaceNotice.tryParse(_data(override: {'open_shutters': '0'}))!.openShutters, 0);
      expect(PeaceNotice.tryParse(_data(override: {'open_lights': '0'}))!.openLights, 0);
    });

    test('sayı üst sınırı 9999 kabul edilir', () {
      final notice = PeaceNotice.tryParse(_data(override: {'open_lights': '9999', 'open_shutters': '0'}));
      expect(notice!.openLights, 9999);
    });

    test('başlık/gövde yoksa null kalır', () {
      final notice = PeaceNotice.tryParse(_data())!;
      expect(notice.title, isNull);
      expect(notice.body, isNull);
    });

    test('dedupeKey: noticeId varsa ona, yoksa ev+başlık+gövdeye dayanır', () {
      final withId = PeaceNotice.tryParse(_data(), title: 'A', body: 'B')!;
      final withIdOther = PeaceNotice.tryParse(_data(), title: 'X', body: 'Y')!;
      expect(withId.dedupeKey, withIdOther.dedupeKey);

      final noId1 = PeaceNotice.tryParse(
        _data(remove: ['notice_id']),
        title: 'A',
        body: 'B',
      )!;
      final noId2 = PeaceNotice.tryParse(
        _data(remove: ['notice_id']),
        title: 'A',
        body: 'B',
      )!;
      final noId3 = PeaceNotice.tryParse(
        _data(remove: ['notice_id']),
        title: 'A',
        body: 'C',
      )!;
      expect(noId1.dedupeKey, noId2.dedupeKey);
      expect(noId1.dedupeKey, isNot(noId3.dedupeKey));
    });

    test('dedupeKey ayırıcı çakışması üretmez ("a|b","c" ile "a","b|c")', () {
      final first = PeaceNotice.tryParse(
        _data(remove: ['notice_id']),
        title: 'a|b',
        body: 'c',
      )!;
      final second = PeaceNotice.tryParse(
        _data(remove: ['notice_id']),
        title: 'a',
        body: 'b|c',
      )!;
      expect(first.dedupeKey, isNot(second.dedupeKey));
    });

    test('toString ev kimliği, başlık ve gövdeyi sızdırmaz', () {
      final text = PeaceNotice.tryParse(_data(), title: 'Gizli Ev', body: 'Gizli gövde')!.toString();
      expect(text.contains(_home), isFalse);
      expect(text.contains('Gizli'), isFalse);
    });
  });

  group('PeaceNotice.tryParse düşmanca girdi -> null (istisna yok)', () {
    final invalid = <String, Map<String, dynamic>>{
      'boş harita': <String, dynamic>{},
      'type yok': _data(remove: ['type']),
      'yanlış type': _data(override: {'type': 'chat_message'}),
      'type büyük harf': _data(override: {'type': 'PEACE_OPEN_DEVICES'}),
      'type metin değil': _data(override: {'type': 1}),
      'bilinmeyen sürüm': _data(override: {'v': '2'}),
      'sürüm metin değil': _data(override: {'v': 1}),
      'bilinmeyen eylem': _data(override: {'action': 'open_all'}),
      'home_id yok': _data(remove: ['home_id']),
      'home_id boş': _data(override: {'home_id': ''}),
      'home_id null': _data(override: {'home_id': null}),
      'home_id sayı': _data(override: {'home_id': 12345}),
      'home_id çok uzun': _data(override: {'home_id': 'a' * 65}),
      'home_id boşluk': _data(override: {'home_id': 'abc def'}),
      'home_id yol gezinmesi': _data(override: {'home_id': '../../etc/passwd'}),
      'home_id etiket': _data(override: {'home_id': '<script>alert(1)</script>'}),
      'home_id Unicode': _data(override: {'home_id': 'ev-ğüş'}),
      'home_id satır sonu': _data(override: {'home_id': '$_home\n'}),
      'notice_id sıfır': _data(override: {'notice_id': '0'}),
      'notice_id negatif': _data(override: {'notice_id': '-5'}),
      'notice_id ondalık': _data(override: {'notice_id': '1.5'}),
      'notice_id harf': _data(override: {'notice_id': 'abc'}),
      'notice_id boşluklu': _data(override: {'notice_id': ' 5'}),
      'notice_id sayı türünde': _data(override: {'notice_id': 5}),
      'notice_id çok hane': _data(override: {'notice_id': '9' * 19}),
      'notice_id Unicode rakam': _data(override: {'notice_id': _c(0x0663)}),
      'open_lights yok': _data(remove: ['open_lights']),
      'open_shutters yok': _data(remove: ['open_shutters']),
      'open_lights negatif': _data(override: {'open_lights': '-1'}),
      'open_lights üstel': _data(override: {'open_lights': '1e3'}),
      'open_lights ondalık': _data(override: {'open_lights': '2.0'}),
      'open_lights sayı türünde': _data(override: {'open_lights': 2}),
      'open_lights sınır aşımı': _data(override: {'open_lights': '10000'}),
      'open_lights çok hane': _data(override: {'open_lights': '00001'}),
      'open_shutters sınır aşımı': _data(override: {'open_shutters': '10000'}),
      'open_shutters Unicode rakam': _data(override: {'open_shutters': _c(0x0661)}),
      'ikisi de sıfır': _data(override: {'open_lights': '0', 'open_shutters': '0'}),
    };

    invalid.forEach((name, data) {
      test(name, () {
        expect(() => PeaceNotice.tryParse(data), returnsNormally);
        expect(PeaceNotice.tryParse(data), isNull);
      });
    });

    test('okurken fırlatan harita istisna sızdırmaz', () {
      expect(() => PeaceNotice.tryParse(_ThrowingMap()), returnsNormally);
      expect(PeaceNotice.tryParse(_ThrowingMap()), isNull);
    });
  });

  group('PeaceNotice başlık/gövde temizliği', () {
    test('denetim karakterleri boşluğa çevrilir, boşluklar sadeleşir', () {
      final notice = PeaceNotice.tryParse(_data(), title: '  Evim${_c(0)}\n\t Salon  ', body: 'a\r\nb${_c(7)}c')!;
      expect(notice.title, 'Evim Salon');
      expect(notice.body, 'a b c');
    });

    test('çift yönlü biçim ve sıfır genişlikli karakterler temizlenir', () {
      final notice = PeaceNotice.tryParse(
        _data(),
        title: 'ev${_c(0x202E)}gnirts${_c(0x202C)}${_c(0x200B)}x${_c(0xFEFF)}',
        body: '${_c(0x2066)}gizli${_c(0x2069)}',
      )!;
      expect(notice.title!.contains(_c(0x202E)), isFalse);
      expect(notice.title!.contains(_c(0x200B)), isFalse);
      expect(notice.title!.contains(_c(0xFEFF)), isFalse);
      expect(notice.body, 'gizli');
    });

    test('yalnızca boşluk/denetim karakteri içeren metin null olur', () {
      final notice = PeaceNotice.tryParse(_data(), title: ' ${_c(0)} \n ', body: '')!;
      expect(notice.title, isNull);
      expect(notice.body, isNull);
    });

    test('Türkçe karakterler korunur', () {
      final notice = PeaceNotice.tryParse(_data(), title: 'Şişli Evi', body: 'Yatak Odasında 1 lamba açık.')!;
      expect(notice.title, 'Şişli Evi');
      expect(notice.body, 'Yatak Odasında 1 lamba açık.');
    });

    test('uzun başlık 120, uzun gövde 300 kod noktasına kısaltılır', () {
      final notice = PeaceNotice.tryParse(_data(), title: 'a' * 500, body: 'b' * 500)!;
      expect(notice.title!.runes.length, 120);
      expect(notice.body!.runes.length, 300);
    });

    test('kısaltma vekil çifti (emoji) ortasından bölmez', () {
      // 119 harf + emoji (iki UTF-16 birimi, tek kod noktası) + fazlalık
      final emoji = _c(0x1F600);
      final title = '${'a' * 119}${emoji}bbbb';
      final notice = PeaceNotice.tryParse(_data(), title: title)!;
      expect(notice.title!.runes.length, 120);
      expect(notice.title!.endsWith(emoji), isTrue);
    });
  });

  group('PeaceNotice eşitlik', () {
    test('aynı alanlar eşit, farklı kaynak eşit değil', () {
      final a = PeaceNotice.tryParse(_data(), now: fixedNow)!;
      final b = PeaceNotice.tryParse(_data(), now: fixedNow)!;
      final c = PeaceNotice.tryParse(_data(), now: fixedNow, source: PeaceNoticeSource.initial)!;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}

void _emptyNoticeIdTests() {
  group('notice_id boş metin (sunucu kimliği bilmiyorsa yollar)', () {
    test('bildirim geçerli sayılır ve noticeId null olur', () {
      final notice = PeaceNotice.tryParse(_data(override: {'notice_id': ''}));
      expect(notice, isNotNull);
      expect(notice!.noticeId, isNull);
      expect(notice.openLights, 2);
    });

    test('boşluklu ya da sayı olmayan notice_id hâlâ reddedilir', () {
      expect(PeaceNotice.tryParse(_data(override: {'notice_id': ' '})), isNull);
      expect(PeaceNotice.tryParse(_data(override: {'notice_id': 'abc'})), isNull);
    });
  });
}

// ---------------------------------------------------------------------------------------------
// PeaceNotice.fromSettings: push gelmese de uygulama açılınca ayar yanıtından yedek afiş
// ---------------------------------------------------------------------------------------------

/// Ertesi sabah 08:00 (İstanbul) = 05:00 UTC; gece kaydı 23:30:25 (İstanbul) = 20:30:25 UTC, yani 8,5 saat önce.
final DateTime _morning = DateTime.utc(2026, 10, 2, 5, 0);

Map<String, dynamic> _settings({
  Map<String, dynamic>? override,
  Map<String, dynamic>? last,
  bool noLast = false,
  List<String> remove = const <String>[],
}) {
  final map = <String, dynamic>{
    'home_id': _home,
    'stale': false,
    'open_lights_count': 2,
    'open_shutters_count': 1,
    'summary_text': 'Salonda 2 lamba, 1 panjur açık.',
    'last_notice': noLast
        ? null
        : <String, dynamic>{
            'id': 41,
            'local_date': '2026-10-01',
            'status': 'sent',
            'summary_text': 'Salonda 2 lamba, 1 panjur açık.',
            'open_lights_count': 2,
            'open_shutters_count': 1,
            'created_at': '2026-10-01T20:30:25.000Z',
            'resolved_at': null,
            ...?last,
          },
    ...?override,
  };
  for (final key in remove) {
    map.remove(key);
  }
  return map;
}

void _fromSettingsTests() {
  group('PeaceNotice.fromSettings', () {
    test(
      'çözülmemiş yakın gece kaydı + canlı açık öğeler -> afiş (canlı sayılar, push ile aynı tekilleştirme anahtarı)',
      () {
        final notice = PeaceNotice.fromSettings(_settings(), homeName: 'Gül Apartmanı 5', now: _morning)!;
        expect(notice.homeId, _home);
        expect(notice.noticeId, 41);
        expect(notice.openLights, 2);
        expect(notice.openShutters, 1);
        expect(notice.source, PeaceNoticeSource.settings);
        expect(notice.title, 'Gül Apartmanı 5');
        expect(notice.body, 'Salonda 2 lamba, 1 panjur açık.');
        expect(notice.receivedAt, _morning);
        // aynı bildirimin push kopyasıyla aynı anahtar: ikisi birden afiş çıkarmaz
        expect(notice.dedupeKey, PeaceNotice.tryParse(_data(), now: _morning)!.dedupeKey);
      },
    );

    test('sayılar gece kaydından değil CANLI veriden gelir', () {
      final notice = PeaceNotice.fromSettings(
        _settings(
          override: {'open_lights_count': 1, 'open_shutters_count': 0, 'summary_text': 'Mutfakta 1 lamba açık.'},
        ),
        now: _morning,
      )!;
      expect(notice.openLights, 1);
      expect(notice.openShutters, 0);
      expect(notice.body, 'Mutfakta 1 lamba açık.');
    });

    test('no_recipients (push alıcısı yoktu) de çözülmemiş sayılır', () {
      expect(PeaceNotice.fromSettings(_settings(last: {'status': 'no_recipients'}), now: _morning), isNotNull);
    });

    test('çözülmüş ya da son durumda olmayan kayıtlar için afiş YOK', () {
      for (final status in <String>[
        'resolved',
        'claimed',
        'sending',
        'clear',
        'failed',
        'skipped_offline',
        'manual',
        '',
      ]) {
        expect(
          PeaceNotice.fromSettings(_settings(last: {'status': status}), now: _morning),
          isNull,
          reason: status,
        );
      }
      expect(
        PeaceNotice.fromSettings(_settings(last: {'resolved_at': '2026-10-01T20:40:00.000Z'}), now: _morning),
        isNull,
      );
      expect(PeaceNotice.fromSettings(_settings(noLast: true), now: _morning), isNull);
    });

    test('bayat (cihaz çevrimdışı) ya da stale alanı olmayan yanıt için afiş YOK', () {
      expect(PeaceNotice.fromSettings(_settings(override: {'stale': true}), now: _morning), isNull);
      expect(PeaceNotice.fromSettings(_settings(override: {'stale': null}), now: _morning), isNull);
      expect(PeaceNotice.fromSettings(_settings(override: {'stale': 'false'}), now: _morning), isNull);
      expect(PeaceNotice.fromSettings(_settings(remove: <String>['stale']), now: _morning), isNull);
    });

    test('lambalar bu arada kapatıldıysa (canlı sayılar 0) afiş YOK', () {
      expect(
        PeaceNotice.fromSettings(
          _settings(override: {'open_lights_count': 0, 'open_shutters_count': 0}),
          now: _morning,
        ),
        isNull,
      );
    });

    test('sayaçlar: rakam metni kabul, negatif/aşırı/ondalık/tür karışıklığı red', () {
      expect(PeaceNotice.fromSettings(_settings(override: {'open_lights_count': '2'}), now: _morning)!.openLights, 2);
      for (final bad in <Object?>[-1, 10000, 1.5, 'x', ' 2', null, true]) {
        expect(
          PeaceNotice.fromSettings(_settings(override: {'open_lights_count': bad}), now: _morning),
          isNull,
          reason: '$bad',
        );
      }
    });

    test('yaş sınırı: maxAge dahil, aşılırsa YOK; gelecekteki kayıt (2 dk payı dışında) YOK', () {
      final created = DateTime.utc(2026, 10, 1, 20, 30, 25);
      expect(PeaceNotice.fromSettings(_settings(), now: created.add(const Duration(hours: 14))), isNotNull);
      expect(PeaceNotice.fromSettings(_settings(), now: created.add(const Duration(hours: 14, seconds: 1))), isNull);
      expect(PeaceNotice.fromSettings(_settings(), now: created.add(const Duration(days: 3))), isNull);
      expect(
        PeaceNotice.fromSettings(_settings(), now: created.subtract(const Duration(minutes: 1))),
        isNotNull,
        reason: 'saat sapması payı',
      );
      expect(PeaceNotice.fromSettings(_settings(), now: created.subtract(const Duration(minutes: 3))), isNull);
      expect(
        PeaceNotice.fromSettings(
          _settings(),
          now: created.add(const Duration(hours: 20)),
          maxAge: const Duration(hours: 24),
        ),
        isNotNull,
      );
    });

    test('bozuk last_notice alanları ve ev kimliği için afiş YOK, istisna fırlatılmaz', () {
      for (final bad in <Object?>[0, -4, 'x', 1.5, true, null, '', '٤١']) {
        expect(
          PeaceNotice.fromSettings(_settings(last: {'id': bad}), now: _morning),
          isNull,
          reason: 'id=$bad',
        );
      }
      expect(PeaceNotice.fromSettings(_settings(last: {'id': '41'}), now: _morning)!.noticeId, 41);
      for (final bad in <Object?>[null, '', 'dün', 12345, '2026-13-45T99:99:99Z']) {
        expect(
          PeaceNotice.fromSettings(_settings(last: {'created_at': bad}), now: _morning),
          isNull,
          reason: 'created_at=$bad',
        );
      }
      expect(PeaceNotice.fromSettings(_settings(override: {'last_notice': 'x'}), now: _morning), isNull);
      expect(PeaceNotice.fromSettings(_settings(override: {'last_notice': <Object?>[]}), now: _morning), isNull);
      for (final bad in <Object?>[null, '', 'a b', 'a/b', 'x' * 65, 7]) {
        expect(
          PeaceNotice.fromSettings(_settings(override: {'home_id': bad}), now: _morning),
          isNull,
          reason: 'home_id=$bad',
        );
      }
    });

    test('düşmanca (okurken fırlatan) harita istisna üretmez', () {
      expect(PeaceNotice.fromSettings(_ThrowingMap(), now: _morning), isNull);
    });

    test('metinler temizlenir: denetim/çift yönlü karakterler, boş özet (afiş yine üretilir), uzunluk sınırı', () {
      final bidi = _c(0x202E);
      final zeroWidth = _c(0x200B);
      final dirty = PeaceNotice.fromSettings(
        _settings(override: {'summary_text': 'Salonda\n2 lamba$bidi açık.'}),
        homeName: 'Gül$zeroWidth Apt',
        now: _morning,
      )!;
      expect(dirty.body, 'Salonda 2 lamba açık.');
      expect(dirty.title, 'Gül Apt');

      final empty = PeaceNotice.fromSettings(
        _settings(override: {'summary_text': '   '}),
        homeName: '',
        now: _morning,
      )!;
      expect(empty.body, isNull);
      expect(empty.title, isNull);
      expect(PeaceNotice.fromSettings(_settings(override: {'summary_text': 42}), now: _morning)!.body, isNull);

      final long = PeaceNotice.fromSettings(_settings(override: {'summary_text': 'a' * 500}), now: _morning)!;
      expect(long.body!.runes.length, 300);
    });

    test('now verilmezse şimdiki zaman kullanılır', () {
      final created = DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String();
      expect(PeaceNotice.fromSettings(_settings(last: {'created_at': created})), isNotNull);
    });
  });
}
