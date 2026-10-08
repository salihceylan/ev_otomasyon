import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/legal_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Yasal metin modelleri (CONTRACTS: `GET /legal`, `GET /legal/:id`, `user.legal`): savunmacı çözümleme, blok modeli,
/// satır içi **kalın** parçalar ve kullanıcıdaki yasal durum (yoksa onay GEREKMEZ).
void main() {
  group('UserModel.legal (sunucu publicUser.legal)', () {
    test('legal nesnesi çözülür: kabul edilen / güncel sürüm, durum, onay gereksinimi', () {
      final user = UserModel.fromJson(<String, dynamic>{
        'id': 'u-1',
        'email': 'a@b.c',
        'full_name': 'Ayşe',
        'legal': <String, dynamic>{
          'terms_accepted_version': 1,
          'terms_current_version': 2,
          'terms_status': 'final',
          'needs_acceptance': true,
        },
      });

      expect(user.legal.termsAcceptedVersion, 1);
      expect(user.legal.termsCurrentVersion, 2);
      expect(user.legal.termsStatus, 'final');
      expect(user.legal.needsAcceptance, isTrue);
    });

    test('legal nesnesi YOKSA (eski sunucu / eski kayıt) onay gerekmez', () {
      final user = UserModel.fromJson(<String, dynamic>{'id': 'u-1', 'email': 'a@b.c', 'full_name': 'Ayşe'});

      expect(user.legal.needsAcceptance, isFalse);
      expect(user.legal.termsAcceptedVersion, isNull);
      expect(user.legal.termsCurrentVersion, isNull);
      expect(user.legal.termsStatus, isNull);
      expect(user.legal, UserLegalStatus.none);
    });

    test('bozuk / tanınmayan değerler güvenle karşılanır (kabul edilmemiş sürüm null, tanınmayan durum null)', () {
      final legal = UserLegalStatus.fromJson(<String, dynamic>{
        'terms_accepted_version': null,
        'terms_current_version': '3',
        'terms_status': 'yayinda',
        'needs_acceptance': 'evet-belki',
      });

      expect(legal.termsAcceptedVersion, isNull);
      expect(legal.termsCurrentVersion, 3);
      expect(legal.termsStatus, isNull);
      expect(legal.needsAcceptance, isFalse, reason: 'anlaşılmayan değer onay İSTEMEZ (sunucu kararı açık olmalı)');
      expect(UserLegalStatus.fromJson('metin'), UserLegalStatus.none);
      expect(UserLegalStatus.fromJson(<String, dynamic>{'terms_current_version': 0}).termsCurrentVersion, isNull);
    });

    test('toJson / fromJson gidiş-dönüşte legal korunur (uygulama yeniden açılınca kapı atlanamaz)', () {
      const user = UserModel(
        id: 'u-1',
        email: 'a@b.c',
        fullName: 'Ayşe',
        legal: UserLegalStatus(termsAcceptedVersion: 1, termsCurrentVersion: 2, termsStatus: 'final', needsAcceptance: true),
      );

      final restored = UserModel.fromJson(user.toJson());

      expect(restored.legal, user.legal);
      expect(restored.legal.needsAcceptance, isTrue);
    });

    test('copyWith(legal) yalnız yasal durumu değiştirir; withAcceptedTerms onay gereksinimini kaldırır', () {
      const user = UserModel(
        id: 'u-1',
        email: 'a@b.c',
        fullName: 'Ayşe',
        legal: UserLegalStatus(termsCurrentVersion: 2, termsStatus: 'final', needsAcceptance: true),
      );

      final accepted = user.copyWith(legal: user.legal.withAcceptedTerms(2));

      expect(accepted.legal.termsAcceptedVersion, 2);
      expect(accepted.legal.termsCurrentVersion, 2);
      expect(accepted.legal.termsStatus, 'final');
      expect(accepted.legal.needsAcceptance, isFalse);
      expect(accepted.fullName, 'Ayşe');
      expect(user.copyWith(fullName: 'Ali').legal, user.legal, reason: 'diğer alanlar değişince yasal durum korunur');
    });
  });

  group('LegalDocumentInfo / LegalDocument', () {
    Map<String, dynamic> termsJson({String status = 'draft', Object? blocks}) => <String, dynamic>{
          'id': 'terms',
          'slug': 'kullanici-sozlesmesi',
          'title': 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları',
          'version': 1,
          'effective_date': '2026-10-08',
          'status': status,
          'requires_acceptance': true,
          'url': '/yasal/kullanici-sozlesmesi',
          'blocks': ?blocks,
        };

    test('özet alanları çözülür; yürürlük tarihi GG.AA.YYYY, üst satır "Sürüm N · Yürürlük: ..."', () {
      final info = LegalDocumentInfo.fromJson(termsJson());

      expect(info.id, 'terms');
      expect(info.slug, 'kullanici-sozlesmesi');
      expect(info.title, 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları');
      expect(info.version, 1);
      expect(info.effectiveDate, '2026-10-08');
      expect(info.effectiveDateLabel, '08.10.2026');
      expect(info.metaLine, 'Sürüm 1 · Yürürlük: 08.10.2026');
      expect(info.requiresAcceptance, isTrue);
      expect(info.url, '/yasal/kullanici-sozlesmesi');
      expect(info.kind, LegalDocumentKind.terms);
    });

    test('durum: yalnız açıkça "final" kesinleşmiştir; diğer her değer TASLAK sayılır', () {
      expect(LegalDocumentInfo.fromJson(termsJson()).isDraft, isTrue);
      expect(LegalDocumentInfo.fromJson(termsJson(status: 'final')).isDraft, isFalse);
      expect(LegalDocumentInfo.fromJson(termsJson(status: 'FINAL')).isDraft, isFalse);
      expect(LegalDocumentInfo.fromJson(termsJson(status: 'bilinmiyor')).isDraft, isTrue);
    });

    test('kimlik, kısa ad ya da geçerli sürüm yoksa FormatException (bozuk kayıt metin gibi gösterilmez)', () {
      expect(() => LegalDocumentInfo.fromJson(<String, dynamic>{'slug': 'x', 'version': 1}), throwsFormatException);
      expect(() => LegalDocumentInfo.fromJson(<String, dynamic>{'id': 'terms', 'version': 1}), throwsFormatException);
      expect(() => LegalDocumentInfo.fromJson(termsJson()..['version'] = 0), throwsFormatException);
      expect(() => LegalDocumentInfo.fromJson(termsJson()..['version'] = 'abc'), throwsFormatException);
    });

    test('url yoksa /yasal/<slug> türetilir; tarih biçimsizse olduğu gibi gösterilir', () {
      final info = LegalDocumentInfo.fromJson(termsJson()
        ..remove('url')
        ..['effective_date'] = 'yakında');
      expect(info.url, '/yasal/kullanici-sozlesmesi');
      expect(info.effectiveDateLabel, 'yakında');
      expect(formatLegalDate('2026-01-31'), '31.01.2026');
    });

    test('bloklar çözülür: başlıklar, paragraf, madde, numaralı madde (n); tanınmayan tür paragraf olur', () {
      final doc = LegalDocument.fromJson(termsJson(blocks: <dynamic>[
        <String, dynamic>{'type': 'h1', 'text': 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları'},
        <String, dynamic>{'type': 'h2', 'text': '1. Taraflar'},
        <String, dynamic>{'type': 'h3', 'text': '1.1 Hizmet sağlayıcı'},
        <String, dynamic>{'type': 'p', 'text': 'Bu metin **önemlidir**.'},
        <String, dynamic>{'type': 'li', 'text': 'Birinci madde'},
        <String, dynamic>{'type': 'oli', 'text': 'Numaralı madde', 'n': 3},
        <String, dynamic>{'type': 'table', 'text': 'Yeni tür'},
        'bozuk kayıt',
      ]));

      expect(doc.version, 1);
      expect(doc.blocks.map((b) => b.type), <LegalBlockType>[
        LegalBlockType.h1,
        LegalBlockType.h2,
        LegalBlockType.h3,
        LegalBlockType.p,
        LegalBlockType.li,
        LegalBlockType.oli,
        LegalBlockType.p,
      ]);
      expect(doc.blocks[5].n, 3);
      expect(doc.blocks[4].n, isNull);
      expect(doc.blocks[3].text, 'Bu metin **önemlidir**.');
    });

    test('gövdenin ilk h1 başlığı metin başlığıyla aynıysa ekranda İKİNCİ KEZ gösterilmez', () {
      final doc = LegalDocument.fromJson(termsJson(blocks: <dynamic>[
        <String, dynamic>{'type': 'h1', 'text': 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları'},
        <String, dynamic>{'type': 'p', 'text': 'Giriş'},
      ]));
      expect(doc.bodyBlocks.map((b) => b.text), <String>['Giriş']);

      final other = LegalDocument.fromJson(termsJson(blocks: <dynamic>[
        <String, dynamic>{'type': 'h1', 'text': 'Başka Başlık'},
      ]));
      expect(other.bodyBlocks, hasLength(1));
    });
  });

  group('parseLegalInline (yalnız **kalın**)', () {
    List<(String, bool)> parts(String text) => [for (final s in parseLegalInline(text)) (s.text, s.bold)];

    test('düz metin tek parçadır', () {
      expect(parts('Sade metin.'), <(String, bool)>[('Sade metin.', false)]);
    });

    test('kalın parçalar ayrılır (baş, orta, son)', () {
      expect(parts('Bu **çok önemli** bir madde.'), <(String, bool)>[
        ('Bu ', false),
        ('çok önemli', true),
        (' bir madde.', false),
      ]);
      expect(parts('**Başta** ve **sonda**'), <(String, bool)>[
        ('Başta', true),
        (' ve ', false),
        ('sonda', true),
      ]);
    });

    test('kapanmayan ** işareti olduğu gibi (düz) kalır; boş kalın parça atlanır', () {
      expect(parts('Kapanmayan **işaret'), <(String, bool)>[('Kapanmayan **işaret', false)]);
      expect(parts('**a** ve **b'), <(String, bool)>[('a', true), (' ve **b', false)]);
      expect(parts('****'), isEmpty);
      expect(parts(''), isEmpty);
    });
  });

  group('legalPublicUrl (herkese açık adres API kök adresinden)', () {
    test('/api kökü atılır, yol eklenir', () {
      expect(
        legalPublicUrl('https://evotomasyon.gudeteknoloji.com.tr/api', '/yasal/kullanici-sozlesmesi'),
        'https://evotomasyon.gudeteknoloji.com.tr/yasal/kullanici-sozlesmesi',
      );
      expect(legalPublicUrl('http://10.0.2.2:5000/api', '/yasal/gizlilik-politikasi'), 'http://10.0.2.2:5000/yasal/gizlilik-politikasi');
      expect(legalPublicUrl('https://ornek.test/ev/api/', 'yasal/x'), 'https://ornek.test/ev/yasal/x');
    });

    test('tam adres verilirse olduğu gibi döner', () {
      expect(legalPublicUrl('https://a.test/api', 'https://b.test/yasal/x'), 'https://b.test/yasal/x');
    });
  });

  group('LegalDocumentKind', () {
    test('kimlik ve kısa addan bulunur; adlar sözleşmeyle aynı', () {
      expect(LegalDocumentKind.fromId('terms'), LegalDocumentKind.terms);
      expect(LegalDocumentKind.fromId('gizlilik-politikasi'), LegalDocumentKind.privacy);
      expect(LegalDocumentKind.fromId('yok'), isNull);
      expect(LegalDocumentKind.terms.slug, 'kullanici-sozlesmesi');
      expect(LegalDocumentKind.privacy.slug, 'gizlilik-politikasi');
      expect(LegalDocumentKind.terms.label, 'Kullanıcı Sözleşmesi');
      expect(LegalDocumentKind.privacy.label, 'Gizlilik Politikası ve KVKK Aydınlatma Metni');
      expect(LegalDocumentKind.terms.publicPath, '/yasal/kullanici-sozlesmesi');
    });
  });

  group('LegalAcceptance', () {
    test('yanıt çözülür; eksik alanlar istekteki değerlerle tamamlanır', () {
      final full = LegalAcceptance.fromJson(<String, dynamic>{
        'document': 'terms',
        'version': 2,
        'accepted_at': '2026-10-08T09:00:00Z',
      }, document: 'terms', version: 2);
      expect(full.document, 'terms');
      expect(full.version, 2);
      expect(full.acceptedAt, DateTime.utc(2026, 10, 8, 9));

      final empty = LegalAcceptance.fromJson(const <String, dynamic>{}, document: 'terms', version: 4);
      expect(empty.document, 'terms');
      expect(empty.version, 4);
      expect(empty.acceptedAt, isNull);
    });
  });
}
