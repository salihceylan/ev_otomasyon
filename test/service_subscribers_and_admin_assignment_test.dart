import 'dart:async';

import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/subscriber_models.dart';
import 'package:ev_otomasyon/ui/pages/service_subscribers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// Servis aboneleri sayfası ve Home Admin atama/devretme: tip güvenli ayrıştırma, sayfalama, gecikmeli
/// arama, görünür hatalar, ikinci onay penceresi, mevcut sahibin onay kodu ve çift tıklama koruması.

/// Sunucunun (B2) abone satırı biçimi: `device_uuids[]` + sayaçlar.
Map<String, dynamic> sub(
  Object homeId,
  String name, {
  String uid = '',
  List<String>? uids,
  int? deviceCount,
  int online = 0,
  int commissioned = 0,
  Map<String, dynamic>? owner,
}) {
  final list = uids ?? (uid.isEmpty ? <String>[] : <String>[uid]);
  return <String, dynamic>{
    'home_id': homeId,
    'home_name': name,
    'home_address': 'Atatürk Cad. No:5',
    'owner': owner,
    'device_count': deviceCount ?? list.length,
    'online_count': online,
    'commissioned_count': commissioned,
    'device_uuids': list,
  };
}

Map<String, dynamic> ownerOf(String name, {String email = 'eski@ornek.test', String phone = '05550001122'}) =>
    <String, dynamic>{'full_name': name, 'email': email, 'phone': phone};

Future<ServiceHarness> envWith(String role, List<Map<String, dynamic>> subscribers) async {
  final env = await serviceHarness(role: role, flush: () async {});
  env.cloud.subscribers = subscribers;
  return env;
}

Future<void> openSubscribers(WidgetTester tester, ServiceHarness env, {int pageSize = 30}) async {
  await pumpPage(tester, env, ServiceSubscribersPage(pageSize: pageSize), size: const Size(900, 3000));
  await settle(tester);
}

void main() {
  group('tip güvenli ayrıştırma (Subscriber.tryParse)', () {
    test('home_id sayı, UUID ya da metin olabilir; kimliği olmayan kayıt atlanır', () {
      final list = parseSubscribers(<Map<String, dynamic>>[
        <String, dynamic>{'home_id': 101, 'home_name': 'Daire 101'},
        <String, dynamic>{'home_id': '33333333-3333-4333-8333-333333333333', 'home_name': 'Villa'},
        <String, dynamic>{'home_name': 'Kimliksiz'},
        <String, dynamic>{'home_id': '', 'home_name': 'Boş kimlik'},
      ]);
      expect(list.map((s) => s.homeId), <String>['101', '33333333-3333-4333-8333-333333333333']);
      expect(list.first.shortId, '101');
      expect(list.last.shortId, '33333333');
    });

    test('sahip adı yoksa sahip yok sayılır; iletişim e-posta, yoksa telefondur', () {
      final withOwner = Subscriber.tryParse(sub('1', 'A', owner: ownerOf('Ali Veli')))!;
      expect(withOwner.hasOwner, isTrue);
      expect(withOwner.owner!.contact, 'eski@ornek.test');
      final phoneOnly = Subscriber.tryParse(sub('2', 'B', owner: <String, dynamic>{'full_name': 'Ayşe', 'phone': '0555'}))!;
      expect(phoneOnly.owner!.contact, '0555');
      final noName = Subscriber.tryParse(sub('3', 'C', owner: <String, dynamic>{'email': 'x@y.z'}))!;
      expect(noName.hasOwner, isFalse);
    });

    test('sunucu biçimi: pano listesi, sayaçlar ve devrede bilgisi okunur', () {
      final s = Subscriber.tryParse(sub('h1', 'Daire', uids: <String>['AHBU-S3-AAA111', 'AHBU-S3-BBB222'], deviceCount: 5, online: 2, commissioned: 1))!;
      expect(s.deviceUuids, <String>['AHBU-S3-AAA111', 'AHBU-S3-BBB222']);
      expect(s.deviceUuid, 'AHBU-S3-AAA111');
      expect(s.deviceCount, 5);
      expect(s.hiddenDeviceCount, 3);
      expect(s.onlineCount, 2);
      expect(s.isCommissioned, isTrue);
      final none = Subscriber.tryParse(sub('h2', 'Boş daire'))!;
      expect(none.deviceUuids, isEmpty);
      expect(none.isCommissioned, isFalse);
    });

    test('eski/yalın biçimler de okunur: tek device_uuid, commissioning_status, commissioned_at', () {
      expect(Subscriber.tryParse(<String, dynamic>{'home_id': 9, 'device_uuid': 'AHBU-S3-AAA111'})!.deviceUuids, <String>['AHBU-S3-AAA111']);
      final legacy = Subscriber.tryParse(<String, dynamic>{'home_id': 9, 'commissioning_status': 'APPROVED_WORKING'})!;
      expect(legacy.isCommissioned, isTrue);
      expect(legacy.homeName, 'İsimsiz Daire');
      expect(Subscriber.tryParse(<String, dynamic>{'home_id': 9, 'commissioned_at': '2026-09-01T10:00:00Z'})!.isCommissioned, isTrue);
    });

    test('sahibin hesap durumu okunur (davet bekleyen sahip)', () {
      final s = Subscriber.tryParse(sub(1, 'A', owner: <String, dynamic>{'full_name': 'Ali', 'account_status': 'pending_invite'}))!;
      expect(s.owner!.isPendingInvite, isTrue);
    });
  });

  group('liste', () {
    testWidgets('sunucu hiç yanıt vermezse sonsuz dönmez: 25 sn sonra zaman aşımı hatası ve Tekrar Dene çıkar', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(1, 'Daire 1')]);
      addTearDown(env.dispose);
      env.cloud.subscribersGate = Completer<void>();
      await openSubscribers(tester, env);
      expect(find.byKey(const Key('subscribers_loading')), findsOneWidget);

      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(find.byKey(const Key('subscribers_loading')), findsNothing);
      expect(find.byKey(const Key('subscribers_error')), findsOneWidget);
      expect(find.textContaining('zaman aşımına uğradı'), findsOneWidget);

      env.cloud.subscribersGate!.complete();
      await tapKey(tester, 'btn_retry');
      await settle(tester);
      expect(find.byKey(const Key('card_subscriber_1')), findsOneWidget);
    });

    testWidgets('sayı ve metin kimlikli daireler çizilir; bozuk kayıt listeyi bozmaz', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[
        sub(101, 'Daire 101', uid: 'AHBU-S3-AAA111'),
        sub('33333333-3333-4333-8333-333333333333', 'Villa Mavi'),
        <String, dynamic>{'home_name': 'Kimliksiz kayıt'},
      ]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      expect(find.byKey(const Key('card_subscriber_101')), findsOneWidget);
      expect(find.byKey(const Key('card_subscriber_33333333-3333-4333-8333-333333333333')), findsOneWidget);
      expect(find.textContaining('Kimliksiz kayıt'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('çok panolu daire kartı panoları, toplam sayıyı ve çevrimiçi sayısını gösterir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[
        sub('h-1', 'Villa', uids: <String>['AHBU-S3-AAA111', 'AHBU-S3-BBB222'], deviceCount: 4, online: 3, commissioned: 2),
      ]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);
      expect(find.text('AHBU-S3-AAA111'), findsOneWidget);
      expect(find.text('AHBU-S3-BBB222'), findsOneWidget);
      expect(find.text('+2 pano daha'), findsOneWidget);
      expect(find.text('4 pano • 3 çevrimiçi'), findsOneWidget);
      expect(find.text('Devrede'), findsOneWidget);
    });

    testWidgets('sunucu hatasında boş liste yerine hata ve Tekrar Dene gösterilir; tekrar denenince liste gelir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(1, 'Daire 1')]);
      addTearDown(env.dispose);
      env.cloud.subscribersErrorOnce =
          const ApiException(statusCode: 500, code: 'INTERNAL', message: 'Sunucu şu anda yanıt veremiyor.');
      await openSubscribers(tester, env);

      expect(find.byKey(const Key('subscribers_error')), findsOneWidget);
      expect(find.text('Sunucu şu anda yanıt veremiyor.'), findsOneWidget);
      expect(find.byKey(const Key('subscribers_empty')), findsNothing);

      await tapKey(tester, 'btn_retry');
      await settle(tester);
      expect(find.byKey(const Key('subscribers_error')), findsNothing);
      expect(find.byKey(const Key('card_subscriber_1')), findsOneWidget);
    });

    testWidgets('yenileme başarısız olursa eski liste uyarıyla birlikte gösterilir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(1, 'Daire 1')]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      env.cloud.subscribersError = const ApiException(statusCode: 0, code: 'NETWORK', message: 'Sunucuya ulaşılamadı.');
      await tapKey(tester, 'btn_refresh');
      await settle(tester);
      expect(find.byKey(const Key('subscribers_stale')), findsOneWidget);
      expect(find.byKey(const Key('card_subscriber_1')), findsOneWidget);
    });

    testWidgets('sonsuz yükleme dönmez: yanıt gecikirse yükleniyor göstergesi, yanıt gelince liste', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(1, 'Daire 1')]);
      addTearDown(env.dispose);
      env.cloud.subscribersGate = Completer<void>();
      await openSubscribers(tester, env);
      expect(find.byKey(const Key('subscribers_loading')), findsOneWidget);

      env.cloud.subscribersGate!.complete();
      await settle(tester);
      expect(find.byKey(const Key('subscribers_loading')), findsNothing);
      expect(find.byKey(const Key('card_subscriber_1')), findsOneWidget);
    });

    testWidgets('boş sonuçta yönlendirici mesaj, aramada sonuç yoksa arama mesajı gösterilir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);
      expect(find.byKey(const Key('subscribers_empty')), findsOneWidget);
      expect(find.textContaining('Henüz kayıtlı bir daire'), findsOneWidget);
    });

    testWidgets('arama 300 ms sessiz kalınca tek istek atar ve sonucu süzer', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[
        sub(1, 'Daire Nilüfer', uid: 'AHBU-S3-AAA111'),
        sub(2, 'Daire Çınar', uid: 'AHBU-S3-BBB222'),
      ]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);
      env.cloud.subscriberQueries.clear();

      await tester.enterText(find.byKey(const Key('field_search')), 'Çı');
      await tester.pump();
      await tester.enterText(find.byKey(const Key('field_search')), 'Çınar');
      await tester.pump();
      env.clock.advance(const Duration(milliseconds: 299));
      await settle(tester, frames: 2);
      expect(env.cloud.subscriberQueries, isEmpty, reason: '300 ms dolmadan istek atılmamalı');

      env.clock.advance(const Duration(milliseconds: 2));
      await settle(tester);
      expect(env.cloud.subscriberQueries, <String>['0|Çınar']);
      expect(find.byKey(const Key('card_subscriber_2')), findsOneWidget);
      expect(find.byKey(const Key('card_subscriber_1')), findsNothing);
    });

    testWidgets('liste sayfalıdır: Daha fazla yükle ikinci sayfayı ekler', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[
        for (var i = 1; i <= 5; i++) sub(i, 'Daire $i'),
      ]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env, pageSize: 2);
      expect(find.byKey(const Key('card_subscriber_3')), findsNothing);

      await tapKey(tester, 'btn_load_more');
      await settle(tester);
      expect(env.cloud.subscriberQueries, <String>['0|', '2|']);
      expect(find.byKey(const Key('card_subscriber_1')), findsOneWidget, reason: 'ilk sayfa korunur');
      expect(find.byKey(const Key('card_subscriber_3')), findsOneWidget);
    });

    testWidgets('sayfalı listede sayaçlar tutarlıdır: toplam sunucu toplamı, diğerleri yüklenenler için "en az" (N+); hepsi yüklenince kesin',
        (tester) async {
      // 5 daire: 1, 3, 5 numaralıların sahibi var; sayfa boyutu 2.
      final env = await envWith('staff', <Map<String, dynamic>>[
        for (var i = 1; i <= 5; i++) sub(i, 'Daire $i', owner: i.isOdd ? ownerOf('Sahip $i') : null),
      ]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env, pageSize: 2);

      String statText(String key) =>
          tester.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text))).data!;
      // Yalnızca 1. ve 2. daire yüklendi (sahipli: 1, sahipsiz: 1); 3 kayıt daha var.
      expect(statText('stat_total'), '5', reason: 'toplam sunucu toplamıdır');
      expect(statText('stat_assigned'), '1+', reason: 'yüklenen satırlardan sayıldı: kesin değil, "en az"');
      expect(statText('stat_pending'), '1+');

      await tapKey(tester, 'btn_load_more');
      await settle(tester);
      expect(statText('stat_assigned'), '2+', reason: 'hâlâ 1 kayıt yüklenmedi');
      expect(statText('stat_pending'), '2+');

      await tapKey(tester, 'btn_load_more');
      await settle(tester);
      expect(find.byKey(const Key('btn_load_more')), findsNothing, reason: 'hepsi yüklendi');
      expect(statText('stat_total'), '5');
      expect(statText('stat_assigned'), '3', reason: 'tüm kayıtlar yüklenince kesin sayı (artı işareti yok)');
      expect(statText('stat_pending'), '2');
    });
  });

  group('erişim (rol matrisi)', () {
    testWidgets('geçici servis oturumu abonelere erişemez ve sunucuya istek atılmaz', (tester) async {
      final env = await envWith('pin', <Map<String, dynamic>>[sub(1, 'Daire 1')]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);
      expect(find.textContaining('yalnızca servis personeli ve süper yönetici'), findsOneWidget);
      expect(env.cloud.subscriberQueries, isEmpty);
    });

    testWidgets('süper yönetici ve servis personeli listeyi görür', (tester) async {
      for (final role in ['super', 'staff']) {
        final env = await envWith(role, <Map<String, dynamic>>[sub(1, 'Daire 1')]);
        addTearDown(env.dispose);
        await openSubscribers(tester, env);
        expect(find.byKey(const Key('card_subscriber_1')), findsOneWidget, reason: role);
      }
    });
  });

  group('Home Admin atama (sahibi olmayan daire)', () {
    testWidgets('form doğrulanır, ikinci onay penceresi çıkar, onayla atama yapılır ve liste yenilenir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(7, 'Daire 7', uid: 'AHBU-S3-AAA111')]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_assign_admin_7');
      await settle(tester);
      // Boş form: ad ve iletişim hatası, istek yok.
      await tapKey(tester, 'btn_assign_next');
      expect(find.text('Ad soyad en az 2 karakter olmalı.'), findsOneWidget);
      expect(find.text('E-posta veya telefondan en az birini girin.'), findsOneWidget);
      expect(env.cloud.assignments, isEmpty);

      await typeKey(tester, 'field_admin_name', '  Ayşe Yılmaz  ');
      await typeKey(tester, 'field_admin_email', 'AYSE@Ornek.Test');
      await tapKey(tester, 'btn_assign_next');
      await settle(tester);
      // İkinci onay penceresi
      expect(find.text('Yönetici değişikliğini onaylıyor musunuz?'), findsOneWidget);
      expect(find.textContaining('Ayşe Yılmaz, "Daire 7" dairesinin Home Admin'), findsOneWidget);
      expect(env.cloud.assignments, isEmpty, reason: 'onay verilmeden atama yapılmaz');
      await tapKey(tester, 'btn_assign_confirm');
      await settle(tester);

      expect(env.cloud.adminOtpRequests, 0, reason: 'sahibi olmayan dairede onay kodu istenmez');
      expect(env.cloud.assignments, hasLength(1));
      expect(env.cloud.assignments.single['full_name'], 'Ayşe Yılmaz');
      expect(env.cloud.assignments.single['email'], 'ayse@ornek.test', reason: 'e-posta normalleştirilir');
      expect(find.text('Ayşe Yılmaz Home Admin olarak atandı.'), findsOneWidget);
      expect(find.textContaining('Home Admin: Ayşe Yılmaz'), findsOneWidget, reason: 'liste yenilendi');
    });

    testWidgets('geçersiz e-posta ve telefon alan hatası verir; istek atılmaz', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(7, 'Daire 7')]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_assign_admin_7');
      await settle(tester);
      await typeKey(tester, 'field_admin_name', 'Ayşe Yılmaz');
      await typeKey(tester, 'field_admin_email', 'bu-bir-eposta-degil');
      await tapKey(tester, 'btn_assign_next');
      expect(find.textContaining('E-posta adresi geçersiz'), findsOneWidget);

      await typeKey(tester, 'field_admin_email', '');
      await typeKey(tester, 'field_admin_phone', '123');
      await tapKey(tester, 'btn_assign_next');
      expect(find.textContaining('5 ile başlamalıdır'), findsOneWidget);
      expect(find.text('Yönetici değişikliğini onaylıyor musunuz?'), findsNothing);
      expect(env.cloud.assignments, isEmpty);
    });

    testWidgets('telefon ayırıcıları atılarak gönderilir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(7, 'Daire 7')]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_assign_admin_7');
      await settle(tester);
      await typeKey(tester, 'field_admin_name', 'Ayşe Yılmaz');
      await typeKey(tester, 'field_admin_phone', '0555 123 45-67');
      await tapKey(tester, 'btn_assign_next');
      await settle(tester);
      await tapKey(tester, 'btn_assign_confirm');
      await settle(tester);
      expect(env.cloud.assignments.single['phone'], '+905551234567');
      expect(env.cloud.assignments.single['email'], isNull);
    });

    testWidgets('onay penceresinden vazgeçilirse atama yapılmaz ve form açık kalır', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(7, 'Daire 7')]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_assign_admin_7');
      await settle(tester);
      await typeKey(tester, 'field_admin_name', 'Ayşe Yılmaz');
      await typeKey(tester, 'field_admin_email', 'ayse@ornek.test');
      await tapKey(tester, 'btn_assign_next');
      await settle(tester);
      await tapKey(tester, 'btn_assign_cancel_confirm');
      await settle(tester);
      expect(env.cloud.assignments, isEmpty);
      expect(find.byKey(const Key('field_admin_name')), findsOneWidget);
    });

    testWidgets('sunucu atamayı reddederse hata diyalogda görünür, diyalog açık kalır ve çift dokunuş tek istek atar',
        (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(7, 'Daire 7')]);
      addTearDown(env.dispose);
      env.cloud.assignGate = Completer<void>();
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_assign_admin_7');
      await settle(tester);
      await typeKey(tester, 'field_admin_name', 'Ayşe Yılmaz');
      await typeKey(tester, 'field_admin_email', 'ayse@ornek.test');
      await tapKey(tester, 'btn_assign_next');
      await settle(tester);
      await tapKey(tester, 'btn_assign_confirm');
      await tester.pump();
      // Gönderim sürerken düğme pasif: ikinci dokunuş etkisiz.
      expect(buttonEnabled(tester, 'btn_assign_next'), isFalse);
      await tester.tap(find.byKey(const Key('btn_assign_next')), warnIfMissed: false);
      await tester.pump();

      env.cloud.assignError = const ApiException(statusCode: 409, code: 'CONFLICT', message: 'Bu daire için işlem sürüyor.');
      env.cloud.assignGate!.complete();
      await settle(tester);
      expect(find.byKey(const Key('assign_error')), findsOneWidget);
      expect(find.text('Bu daire için işlem sürüyor.'), findsOneWidget);
      expect(find.byKey(const Key('field_admin_name')), findsOneWidget, reason: 'hata sonrası diyalog kapanmaz');
      expect(env.cloud.calls.where((c) => c.startsWith('assignHomeAdmin')).length, 1, reason: 'çift dokunuş tek istek');
    });
  });

  group('Home Admin devri (mevcut sahibi olan daire)', () {
    Future<void> fillAndConfirm(WidgetTester tester) async {
      await tapKey(tester, 'btn_assign_admin_9');
      await settle(tester);
      await typeKey(tester, 'field_admin_name', 'Yeni Yönetici');
      await typeKey(tester, 'field_admin_email', 'yeni@ornek.test');
      await tapKey(tester, 'btn_assign_next');
      await settle(tester);
    }

    testWidgets('onay penceresi eski yöneticinin yetkisinin kalkacağını söyler; vazgeçilirse kod istenmez', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await fillAndConfirm(tester);
      expect(find.textContaining('Eski Sahip kişisinin "Daire 9" dairesi üzerindeki yetkisi kalkacak'), findsOneWidget);
      expect(find.textContaining('Yeni Yönetici yeni Home Admin olarak atanacak'), findsOneWidget);
      await tapKey(tester, 'btn_assign_cancel_confirm');
      await settle(tester);
      expect(env.cloud.adminOtpRequests, 0);
      expect(env.cloud.assignments, isEmpty);
    });

    testWidgets('onay sonrası mevcut sahibe kod gider; yanlış kodda kalan deneme gösterilir; doğru kodla devir tamamlanır',
        (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await fillAndConfirm(tester);
      await tapKey(tester, 'btn_assign_confirm');
      await settle(tester);
      expect(env.cloud.adminOtpRequests, 1, reason: 'mevcut sahibe onay kodu istenmeli');
      expect(find.byKey(const Key('field_assign_otp')), findsOneWidget);
      expect(env.cloud.assignments, isEmpty, reason: 'kod girilmeden devir yapılmaz');

      // Eksik kod
      await typeKey(tester, 'field_assign_otp', '123');
      await tapKey(tester, 'btn_assign_submit');
      expect(find.text('Mevcut yöneticiye giden 6 haneli kodu yazın.'), findsOneWidget);
      // Yanlış kod
      await typeKey(tester, 'field_assign_otp', '000000');
      await tapKey(tester, 'btn_assign_submit');
      await settle(tester);
      expect(find.textContaining('Hatalı onay kodu'), findsOneWidget);
      expect(find.textContaining('Kalan deneme hakkı: 4'), findsOneWidget);
      expect(env.cloud.assignments, isEmpty);
      // Doğru kod
      await typeKey(tester, 'field_assign_otp', kOwnerConsentOtp);
      await tapKey(tester, 'btn_assign_submit');
      await settle(tester);
      expect(env.cloud.assignments, hasLength(1));
      expect(env.cloud.assignments.single['with_otp'], isTrue);
      expect(find.textContaining('Home Admin: Yeni Yönetici'), findsOneWidget);
    });

    testWidgets('kodu yeniden gönder düğmesi geri sayım bitene kadar kapalıdır', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);
      await fillAndConfirm(tester);
      await tapKey(tester, 'btn_assign_confirm');
      await settle(tester);

      expect(buttonEnabled(tester, 'btn_assign_resend'), isFalse);
      expect(find.textContaining('sn sonra'), findsOneWidget);
      env.clock.advance(const Duration(seconds: 61));
      await settle(tester);
      expect(buttonEnabled(tester, 'btn_assign_resend'), isTrue);
      await tapKey(tester, 'btn_assign_resend');
      await settle(tester);
      expect(env.cloud.adminOtpRequests, 2);
    });

    testWidgets('onay kodu gönderilemezse hata görünür ve devir yapılmaz', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      env.cloud.adminOtpError =
          const ApiException(statusCode: 503, code: 'DELIVERY_FAILED', message: 'E-posta gönderilemedi. Lütfen daha sonra tekrar deneyin.');
      await openSubscribers(tester, env);
      await fillAndConfirm(tester);
      await tapKey(tester, 'btn_assign_confirm');
      await settle(tester);
      expect(find.textContaining('E-posta gönderilemedi. Lütfen daha sonra tekrar deneyin.'), findsOneWidget);
      expect(find.textContaining('Süper yöneticiye başvurun'), findsOneWidget, reason: 'personel zorla atama yapamaz');
      expect(env.cloud.assignments, isEmpty);
    });

    testWidgets('mevcut yönetici yeni yönetici olarak yazılırsa engellenir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);

      await tapKey(tester, 'btn_assign_admin_9');
      await settle(tester);
      await typeKey(tester, 'field_admin_name', 'Eski Sahip');
      await typeKey(tester, 'field_admin_email', 'ESKI@ornek.test');
      await tapKey(tester, 'btn_assign_next');
      expect(find.text('Bu kişi zaten dairenin mevcut yöneticisi.'), findsOneWidget);
      expect(env.cloud.adminOtpRequests, 0);
    });
  });

  group('Home Admin atama: sunucu sözleşmesi ayrıntıları', () {
    Future<void> fillTarget(WidgetTester tester, String homeId) async {
      await tapKey(tester, 'btn_assign_admin_$homeId');
      await settle(tester);
      await typeKey(tester, 'field_admin_name', 'Yeni Yönetici');
      await typeKey(tester, 'field_admin_email', 'Yeni@Ornek.Test');
      await tapKey(tester, 'btn_assign_next');
      await settle(tester);
      await tapKey(tester, 'btn_assign_confirm');
      await settle(tester);
    }

    testWidgets('onay kodu isteği atanacak kişinin bilgisini taşır (sunucu kodu bu kişiye bağlar)', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);
      await fillTarget(tester, '9');
      expect(env.cloud.otpTargets.single, <String, dynamic>{'full_name': 'Yeni Yönetici', 'email': 'yeni@ornek.test', 'phone': null});
    });

    testWidgets('kısmi başarı: sunucu uyarı döndürürse atama sonrası uyarılar kullanıcıya gösterilir', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(7, 'Daire 7')]);
      addTearDown(env.dispose);
      env.cloud.assignWarnings = true;
      await openSubscribers(tester, env);
      await fillTarget(tester, '7');

      expect(find.byKey(const Key('assign_warnings')), findsOneWidget);
      expect(find.text('Hesap etkinleştirme e-postası gönderilemedi.'), findsOneWidget);
      expect(find.text('Atama tamamlandı, ancak uyarılar var'), findsOneWidget);
      await tapKey(tester, 'btn_assign_warnings_close');
      await settle(tester);
      expect(find.byKey(const Key('assign_warnings')), findsNothing);
      expect(env.cloud.assignments, hasLength(1));
    });

    testWidgets('sahibe ulaşılamazsa servis personeline süper yöneticiye başvurması söylenir; zorla atama seçeneği yoktur', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      env.cloud.ownerUnreachable = true;
      await openSubscribers(tester, env);
      await fillTarget(tester, '9');

      expect(find.textContaining('Süper yöneticiye başvurun'), findsOneWidget);
      expect(find.byKey(const Key('assign_force_card')), findsNothing);
      expect(find.byKey(const Key('btn_assign_force_toggle')), findsNothing);
      expect(env.cloud.assignments, isEmpty);
    });

    testWidgets('süper yönetici: sahibe ulaşılamazsa zorla atama açılır; gerekçe ve ZORLA yazmadan gönderilmez', (tester) async {
      final env = await envWith('super', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(env.dispose);
      env.cloud.ownerUnreachable = true;
      await openSubscribers(tester, env);
      await fillTarget(tester, '9');

      expect(find.byKey(const Key('assign_force_card')), findsOneWidget);
      // Kısa gerekçe
      await typeKey(tester, 'field_force_reason', 'kısa');
      await tapKey(tester, 'btn_assign_force');
      await settle(tester);
      expect(find.textContaining('en az 15 karakter'), findsWidgets);
      expect(env.cloud.assignments, isEmpty);
      // Yeterli gerekçe -> ZORLA yazdırılır
      await typeKey(tester, 'field_force_reason', 'Ev sahibi ulaşılamıyor, tapu ibraz edildi.');
      await tapKey(tester, 'btn_assign_force');
      await settle(tester);
      expect(find.text('Sahibin onayı olmadan atansın mı?'), findsOneWidget);
      expect(buttonEnabled(tester, 'btn_confirm_destructive'), isFalse);
      await typeKey(tester, 'field_confirm_phrase', 'zorla');
      await tapKey(tester, 'btn_confirm_destructive');
      await settle(tester);

      expect(env.cloud.assignments, hasLength(1));
      expect(env.cloud.assignments.single['force'], isTrue);
      expect(env.cloud.assignments.single['reason'], 'Ev sahibi ulaşılamıyor, tapu ibraz edildi.');
      expect(env.cloud.assignments.single['with_otp'], isFalse, reason: 'zorla atamada sahip onay kodu istenmez');
      expect(find.byKey(const Key('assign_force_card')), findsNothing, reason: 'diyalog kapandı');
    });

    testWidgets('servis personeli zorla atama düğmesini hiç görmez; süper yönetici sahibi olan dairede bağlantıyı görür', (tester) async {
      final staffEnv = await envWith('staff', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(staffEnv.dispose);
      await openSubscribers(tester, staffEnv);
      await tapKey(tester, 'btn_assign_admin_9');
      await settle(tester);
      expect(find.byKey(const Key('btn_assign_force_toggle')), findsNothing);

      final superEnv = await envWith('super', <Map<String, dynamic>>[sub(9, 'Daire 9', owner: ownerOf('Eski Sahip'))]);
      addTearDown(superEnv.dispose);
      await openSubscribers(tester, superEnv);
      await tapKey(tester, 'btn_assign_admin_9');
      await settle(tester);
      expect(find.byKey(const Key('btn_assign_force_toggle')), findsOneWidget);
    });

    testWidgets('sahibi olmayan dairede kod istenmez ve sunucuya yalnızca atama gider', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(7, 'Daire 7')]);
      addTearDown(env.dispose);
      await openSubscribers(tester, env);
      await fillTarget(tester, '7');
      expect(env.cloud.otpTargets, isEmpty);
      expect(env.cloud.assignments.single['force'], isFalse);
    });
  });

  group('yaşam döngüsü', () {
    testWidgets('sayfa kapandıktan sonra gelen yanıt hata üretmez (mounted denetimi)', (tester) async {
      final env = await envWith('staff', <Map<String, dynamic>>[sub(1, 'Daire 1')]);
      addTearDown(env.dispose);
      env.cloud.subscribersGate = Completer<void>();
      await openSubscribers(tester, env);

      await tester.pumpWidget(const SizedBox.shrink());
      env.cloud.subscribersGate!.complete();
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
