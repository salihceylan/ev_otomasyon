import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/shutter_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// Sunucu inceleme düzeltmesi (WP-L, CONTRACTS §2.4b): `PUT /homes/:id/endpoints/:id` pano yerleşimi eşitlemesi
/// satırı bu arada değiştirdiyse `409 CONFLICT` "Kanal tipi değişti; listeyi yenileyin." döner (panjur süresi
/// yazımında sunucu `set_runtime`'ı önce yayınlar, çift artık panjur değilse veritabanına yazmaz).
///
/// Servis sihirbazı 8. adım süre kaydı (`ShutterLogic._writeRuntime`) bunu görebilir. Beklenen davranış:
///
/// * uç nokta listesini sunucudan yeniler (`_endpointFor` bu listeden beslenir) ve yazımı BİR KEZ yeniden dener;
/// * yine 409 ise anlaşılır bir [SetupProblem] ("Kanal yerleşimi değişti", "Tekrar dene");
/// * çakışma OLMAYAN hatalar (500, 409 `DEVICE_OFFLINE`, 400) yenileme/yeniden deneme tetiklemez.
void main() {
  const typeChanged = ApiException(
    statusCode: 409,
    code: 'CONFLICT',
    message: 'Kanal tipi değişti; listeyi yenileyin.',
  );

  group('8. adım: süre yazımında sunucu 409 CONFLICT', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.shutters);
      await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
    });
    tearDown(() => env.dispose());

    /// Bu testin başından beri sunucuya giden istekler (yalnızca ilgili ikisi).
    List<String> updates(int from) => env.cloud.calls.sublist(from).where((x) => x.startsWith('updateEndpoint:')).toList();
    int fetches(int from) => env.cloud.calls.sublist(from).where((x) => x == 'fetchEndpoints:$kClaimedHome').length;

    /// Sunucuda eşitleme, sihirbaz listeyi okuduktan SONRA 1. panjurun YUKARI satırını yeniden oluşturdu (yeni kimlik).
    void serverRecreatesPairOneRow() {
      env.cloud.endpoints[kClaimedHome] = <EndpointModel>[
        for (final e in env.cloud.endpoints[kClaimedHome]!)
          e.id == 'ep-up-1' ? EndpointModel.fromJson(<String, dynamic>{...e.toJson(), 'id': 'v2-ep-up-1'}) : e,
      ];
    }

    test('ilk istek 409: uç noktalar yenilenir, YENİ listedeki kimlikle bir kez yeniden denenir ve süre kaydedilir', () async {
      serverRecreatesPairOneRow();
      env.cloud.updateEndpointErrorQueue.add(typeChanged); // yalnızca ilk PUT çakışır
      final from = env.cloud.calls.length;
      final writesBefore = env.cloud.endpointUpdates.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isTrue, reason: 'ikinci deneme başarılı: kayıt tamam');

      expect(updates(from), <String>['updateEndpoint:ep-up-1', 'updateEndpoint:v2-ep-up-1'],
          reason: 'eski kimlikle çakıştı, yenilenen listedeki kimlikle yeniden denendi');
      expect(fetches(from), 1, reason: 'tam bir yenileme');
      final order = env.cloud.calls.sublist(from);
      expect(order.indexOf('updateEndpoint:ep-up-1'), lessThan(order.indexOf('fetchEndpoints:$kClaimedHome')));
      expect(order.indexOf('fetchEndpoints:$kClaimedHome'), lessThan(order.indexOf('updateEndpoint:v2-ep-up-1')),
          reason: 'sıra: PUT (409) → listeyi yenile → PUT');
      expect(env.cloud.endpointUpdates.length, writesBefore + 1, reason: 'sunucuya tek başarılı yazım');
      expect(env.cloud.endpointUpdates.last['endpoint_id'], 'v2-ep-up-1');
      expect(env.cloud.endpointUpdates.last['sec'], 31);
      expect(env.cloud.endpointUpdates.last['home_id'], kClaimedHome, reason: 'aktif ev değil, hedef ev');
      expect(env.device.shutterRuntime(1), 31, reason: 'pano geri okunarak doğrulandı');
      expect(c.shutters.problem, isNull);
      expect(c.shutters.byPair(1)!.savedSeconds, 31);
    });

    test('yeniden deneme sonraki işlemlerde de yenilenen listeyi kullanır (kimlik haritası güncellenmiştir)', () async {
      serverRecreatesPairOneRow();
      env.cloud.updateEndpointErrorQueue.add(typeChanged);
      c.shutters.setManualSeconds(1, 31);
      expect(await drive(env, c.shutters.saveRuntime(1)), isTrue);

      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 27);
      expect(await drive(env, c.shutters.saveRuntime(1)), isTrue);

      expect(updates(from), <String>['updateEndpoint:v2-ep-up-1'], reason: 'çakışma yok: yeniden yenileme/deneme yok');
      expect(fetches(from), 0);
    });

    test('ikinci istek de 409: "Kanal yerleşimi değişti" sorunu ("Tekrar dene"), tam bir yeniden deneme, kayıt başarılı sayılmaz',
        () async {
      env.cloud.updateEndpointError = typeChanged; // kalıcı: her PUT çakışır
      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

      final problem = c.shutters.problem!;
      expect(problem.kind, SetupProblemKind.conflict);
      expect(problem.title, 'Kanal yerleşimi değişti');
      expect(problem.why, typeChanged.message, reason: 'sunucunun açıklaması aynen');
      expect(problem.todo, contains('Tekrar dene'));
      expect(problem.todo, contains('Listeyi yenileyip'));
      expect(problem.retryable, isTrue);
      expect(c.shutters.canRetry, isTrue, reason: '"Tekrar dene" düğmesi çıkar');
      expect(updates(from), hasLength(2), reason: 'ilk istek + TAM BİR yeniden deneme (sonsuz döngü yok)');
      expect(fetches(from), 1);
      expect(c.shutters.byPair(1)!.savedSeconds, isNull, reason: 'süre kaydedilmiş sayılmaz');
      expect(c.shutters.isComplete, isFalse);
    });

    test('"Tekrar dene" yeniden okuyup yeniden dener ve sunucu uyuşunca kayıt tamamlanır', () async {
      env.cloud.updateEndpointError = typeChanged;
      c.shutters.setManualSeconds(1, 31);
      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);
      expect(c.shutters.problem!.title, 'Kanal yerleşimi değişti');

      env.cloud.updateEndpointError = null; // eşitleme tamamlandı
      final from = env.cloud.calls.length;
      await drive(env, c.shutters.retry());

      expect(c.shutters.problem, isNull);
      expect(c.shutters.byPair(1)!.savedSeconds, 31);
      expect(updates(from), <String>['updateEndpoint:ep-up-1']);
    });

    test('çakışma sonrası yenilenen listede panjur yoksa ikinci istek atılmaz: "kayıt yok" sorunu', () async {
      env.cloud.updateEndpointErrorQueue.add(typeChanged);
      // 1. çift artık panjur değil: iki satırı da lamba oldu.
      env.cloud.endpoints[kClaimedHome] = <EndpointModel>[
        for (final e in env.cloud.endpoints[kClaimedHome]!)
          if (e.isShutter && e.pair == 1)
            EndpointModel.fromJson(<String, dynamic>{...e.toJson(), 'type': 'light', 'shutter_pair_index': null})
          else
            e,
      ];
      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

      expect(c.shutters.problem!.kind, SetupProblemKind.notFound);
      expect(c.shutters.problem!.title, 'Sunucuda bu panjur için kayıt yok');
      expect(updates(from), <String>['updateEndpoint:ep-up-1'], reason: 'olmayan kayda ikinci yazım denenmez');
      expect(fetches(from), 1);
      expect(c.shutters.byPair(1)!.savedSeconds, isNull);
    });

    group('çakışma OLMAYAN hatalar yenileme ya da yeniden deneme tetiklemez', () {
      final cases = <String, ApiException>{
        '500 sunucu hatası': const ApiException(statusCode: 500, code: 'INTERNAL', message: 'x'),
        '409 DEVICE_OFFLINE (pano çevrimdışı)':
            const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'Cihaz çevrimdışı; panjur süresi cihaza iletilemedi.'),
        '400 VALIDATION': const ApiException(statusCode: 400, code: 'VALIDATION', message: 'Süre geçersiz.'),
        '409 kodsuz': const ApiException(statusCode: 409, message: 'İşlem çakıştı.'),
      };
      for (final entry in cases.entries) {
        test(entry.key, () async {
          env.cloud.updateEndpointError = entry.value;
          final from = env.cloud.calls.length;
          c.shutters.setManualSeconds(1, 31);

          expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

          expect(updates(from), hasLength(1), reason: 'tek istek');
          expect(fetches(from), 0, reason: 'liste yenilenmedi');
          expect(c.shutters.problem!.title, isNot('Kanal yerleşimi değişti'));
        });
      }

      test('409 DEVICE_OFFLINE hâlâ "cihaz çevrimdışı" sorunu olarak gösterilir', () async {
        env.cloud.updateEndpointError =
            const ApiException(statusCode: 409, code: 'DEVICE_OFFLINE', message: 'Cihaz çevrimdışı.');
        c.shutters.setManualSeconds(1, 31);
        expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);
        expect(c.shutters.problem!.kind, SetupProblemKind.deviceNetwork);
      });
    });

    group('ölçüm hazırlığı (300 sn yazımı) aynı yolu kullanır', () {
      test('ilk PUT 409: yenilenir, yeniden denenir, hazırlık tamamlanır ve pano 300 sn uygular', () async {
        env.cloud.updateEndpointErrorQueue.add(typeChanged);
        final from = env.cloud.calls.length;

        expect(await drive(env, c.shutters.prepareMeasure(1)), isTrue);

        expect(updates(from), hasLength(2));
        expect(fetches(from), 1);
        expect(env.device.shutterRuntime(1), ShutterLogic.measureRuntimeSec);
        expect(c.shutters.byPair(1)!.phase, MeasurePhase.prepared);
        expect(c.shutters.problem, isNull);
      });

      test('hep 409: hazırlık başarısız ("Kanal yerleşimi değişti"); pano geçici süreye geçmez', () async {
        env.cloud.updateEndpointError = typeChanged;

        expect(await drive(env, c.shutters.prepareMeasure(1)), isFalse);

        expect(c.shutters.problem!.title, 'Kanal yerleşimi değişti');
        expect(c.shutters.byPair(1)!.phase, isNot(MeasurePhase.prepared));
        expect(env.device.shutterRuntime(1), 20, reason: 'sunucu kabul etmedi: pano varsayılan süresinde kaldı');
      });
    });
  });

  group('8. adım (arayüz): iki kez 409', () {
    testWidgets('hata kutusu başlığı, sunucu mesajı ve "Tekrar dene" gösterir; sunucu uyuşunca "Tekrar dene" işlemi tamamlar',
        (tester) async {
      final env = await serviceHarness(flush: () async {});
      addTearDown(env.dispose);
      await openWizardResumedAt(
        tester,
        env,
        SetupSteps.shutters,
        data: <String, dynamic>{
          '8': <String, dynamic>{
            'shutters': <String, dynamic>{
              '1': <String, dynamic>{'dir': true},
            },
          },
        },
      );
      await pumpUntil(tester, env, () => present('btn_prepare_1'), reason: 'panjur listesi yüklenmedi');

      env.cloud.updateEndpointError = typeChanged; // her PUT çakışır
      await tapKey(tester, 'btn_prepare_1');
      await pumpUntil(tester, env, () => present('setup_retry'), reason: 'hata kutusu çıkmadı');

      expect(find.text('Kanal yerleşimi değişti'), findsOneWidget);
      expect(find.text(typeChanged.message), findsOneWidget, reason: 'sunucunun açıklaması "Neden?" altında');
      expect(find.text('Listeyi yenileyip "Tekrar dene"ye basın.'), findsOneWidget);
      expect(find.text('Tekrar dene'), findsOneWidget, reason: 'düğme');
      expect(find.textContaining('İşlem çakıştı'), findsNothing, reason: 'genel (yönetici çağıran) 409 metni gösterilmez');
      expect(env.device.shutterRuntime(1), 20, reason: 'pano geçici süreye geçmedi');

      env.cloud.updateEndpointError = null; // eşitleme tamamlandı
      await tapKey(tester, 'setup_retry');
      await pumpUntil(tester, env, () => env.device.shutterRuntime(1) == 300 && !present('setup_retry'),
          reason: 'yeniden deneme tamamlanmadı');
      expect(find.text('Kanal yerleşimi değişti'), findsNothing, reason: 'hata kutusu kalktı');
    });
  });
}
