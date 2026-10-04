import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/logic/shutter_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// DAIRE-03 (D17, istemci): `PUT /homes/:id/endpoints/:id {shutter_duration_sec}` pano süreyi UYGULAMAZSA (panjur hareket
/// halinde / ölü zamanda) sunucu `409 CONFLICT` + "Pano panjur süresini uygulamadı (panjur hareket halinde olabilir).
/// Panjuru durdurup yeniden deneyin." döner ve veritabanını DEĞİŞTİRMEZ.
///
/// Kod, kanal yerleşimi çakışmasıyla ("Kanal tipi değişti; listeyi yenileyin.") aynıdır; ama bu bir yerleşim çakışması
/// DEĞİLDİR: liste yenileyip aynı anda yinelemek düzeltmez. Sihirbazın 8. adımı bu yanıtı kullanıcıya SUNUCU MESAJIYLA
/// göstermeli, "Kanal yerleşimi değişti" / "Kanal tipi değişti" metni göstermemeli; yerleşim çakışmasındaki "yenile +
/// BİR kez yinele" mantığı ise aynen sürmeli.
void main() {
  const notApplied = ApiException(
    statusCode: 409,
    code: 'CONFLICT',
    message: 'Pano panjur süresini uygulamadı (panjur hareket halinde olabilir). Panjuru durdurup yeniden deneyin.',
  );
  const typeChanged = ApiException(
    statusCode: 409,
    code: 'CONFLICT',
    message: 'Kanal tipi değişti; listeyi yenileyin.',
  );

  String shown(SetupProblem p) => '${p.title} ${p.why} ${p.todo}';

  group('8. adım: süre yazımında sunucu "uygulamadı" (409 CONFLICT)', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.shutters);
      await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
    });
    tearDown(() => env.dispose());

    List<String> updates(int from) => env.cloud.calls.sublist(from).where((x) => x.startsWith('updateEndpoint:')).toList();
    int fetches(int from) => env.cloud.calls.sublist(from).where((x) => x == 'fetchEndpoints:$kClaimedHome').length;

    test('sunucu mesajı aynen gösterilir; liste yenilenmez, PUT yinelenmez, yerleşim çakışması metni yok', () async {
      env.cloud.updateEndpointError = notApplied;
      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

      final problem = c.shutters.problem!;
      expect(problem.why, notApplied.message, reason: 'sunucunun açıklaması aynen');
      expect(problem.title, 'Süre panoda uygulanmadı');
      expect(problem.title, isNot('Kanal yerleşimi değişti'));
      expect(shown(problem), isNot(contains('Kanal tipi')));
      expect(shown(problem), isNot(contains('Listeyi yenileyip')));
      expect(problem.retryable, isTrue, reason: '"Tekrar dene" panjuru önce durdurup yeniden yazar');
      expect(updates(from), hasLength(1), reason: 'uygulanmama yenilemeyle düzelmez: tek istek');
      expect(fetches(from), 0, reason: 'uç nokta listesi yenilenmedi');
      expect(c.shutters.byPair(1)!.savedSeconds, isNull, reason: 'süre kaydedilmiş sayılmaz');
    });

    test('ilk PUT yerleşim çakışması, tek yeniden deneme "uygulamadı": yenile + tek yineleme sürer, sunucunun "uygulamadı" '
        'mesajı gösterilir', () async {
      env.cloud.updateEndpointErrorQueue
        ..add(typeChanged)
        ..add(notApplied);
      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

      final problem = c.shutters.problem!;
      expect(updates(from), hasLength(2), reason: 'yerleşim çakışmasında tek yeniden deneme korunur');
      expect(fetches(from), 1);
      expect(problem.why, notApplied.message);
      expect(problem.title, isNot('Kanal yerleşimi değişti'));
      expect(shown(problem), isNot(contains('Kanal tipi')));
    });

    test('"uygulamadı" sonrası "Tekrar dene" panjuru durdurup yeniden yazar; sunucu kabul edince kayıt tamamlanır', () async {
      env.cloud.updateEndpointErrorQueue.add(notApplied);
      c.shutters.setManualSeconds(1, 31);
      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);
      expect(c.shutters.problem!.why, notApplied.message);

      await drive(env, c.shutters.retry());

      expect(c.shutters.problem, isNull);
      expect(c.shutters.byPair(1)!.savedSeconds, 31);
      expect(env.device.shutterRuntime(1), 31, reason: 'pano geri okunarak doğrulandı');
    });

    test('ölçüm hazırlığında (300 sn) da aynı: sunucu mesajı gösterilir, pano geçici süreye geçmez', () async {
      env.cloud.updateEndpointError = notApplied;

      expect(await drive(env, c.shutters.prepareMeasure(1)), isFalse);

      expect(c.shutters.problem!.why, notApplied.message);
      expect(c.shutters.problem!.title, isNot('Kanal yerleşimi değişti'));
      expect(c.shutters.byPair(1)!.phase, isNot(MeasurePhase.prepared));
      expect(env.device.shutterRuntime(1), 20, reason: 'sunucu uygulanmadı dedi: pano varsayılan süresinde');
    });

    test('yerleşim çakışması (iki kez "Kanal tipi değişti") eskisi gibi "Kanal yerleşimi değişti" der', () async {
      env.cloud.updateEndpointError = typeChanged;
      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

      expect(c.shutters.problem!.title, 'Kanal yerleşimi değişti');
      expect(updates(from), hasLength(2));
      expect(fetches(from), 1);
    });
  });

  // Sunucu 409 gövdesinde makine okunur `reason` taşır ('NOT_APPLIED' | 'TYPE_CHANGED'); ayrım önce ona bakar, metin
  // eşlemesi yalnız `reason` göndermeyen ESKİ sunucu için yedektir.
  group('8. adım: 409 ayrımı önce gövdedeki reason alanına bakar', () {
    late ServiceHarness env;
    late ServiceSetupController c;

    setUp(() async {
      env = await serviceHarness();
      c = await reachStep(env, SetupSteps.shutters);
      await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
    });
    tearDown(() => env.dispose());

    List<String> updates(int from) => env.cloud.calls.sublist(from).where((x) => x.startsWith('updateEndpoint:')).toList();
    int fetches(int from) => env.cloud.calls.sublist(from).where((x) => x == 'fetchEndpoints:$kClaimedHome').length;

    test('reason NOT_APPLIED (mesajda "uygulamadı" geçmese de): uygulanmadı yolu, yenileme/yineleme yok', () async {
      const e = ApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'Pano panjur süresini kabul etmedi.',
        details: <String, dynamic>{'success': false, 'code': 'CONFLICT', 'reason': 'NOT_APPLIED'},
      );
      env.cloud.updateEndpointError = e;
      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

      expect(c.shutters.problem!.title, 'Süre panoda uygulanmadı');
      expect(c.shutters.problem!.why, e.message);
      expect(updates(from), hasLength(1));
      expect(fetches(from), 0);
    });

    test('reason TYPE_CHANGED (mesajda "uygulanmadı" geçse de): yerleşim yolu, yenile + tek yineleme', () async {
      const e = ApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'Kanal tipi değişti; süre uygulanmadı, listeyi yenileyin.',
        details: <String, dynamic>{'success': false, 'code': 'CONFLICT', 'reason': 'TYPE_CHANGED'},
      );
      env.cloud.updateEndpointError = e;
      final from = env.cloud.calls.length;
      c.shutters.setManualSeconds(1, 31);

      expect(await drive(env, c.shutters.saveRuntime(1)), isFalse);

      expect(c.shutters.problem!.title, 'Kanal yerleşimi değişti');
      expect(updates(from), hasLength(2));
      expect(fetches(from), 1);
    });
  });

  group('ApiException.reason', () {
    test('409 gövdesindeki reason okunur; yoksa / boşsa / metin değilse null', () {
      expect(
        const ApiException(statusCode: 409, code: 'CONFLICT', message: 'x', details: <String, dynamic>{'reason': 'NOT_APPLIED'})
            .reason,
        'NOT_APPLIED',
      );
      expect(const ApiException(statusCode: 409, code: 'CONFLICT', message: 'x').reason, isNull);
      expect(
        const ApiException(statusCode: 409, code: 'CONFLICT', message: 'x', details: <String, dynamic>{'reason': ''}).reason,
        isNull,
      );
      expect(
        const ApiException(statusCode: 409, code: 'CONFLICT', message: 'x', details: <String, dynamic>{'reason': 3}).reason,
        isNull,
      );
    });
  });

  group('8. adım (arayüz): "uygulamadı"', () {
    testWidgets('hata kutusu sunucu mesajını ve "Tekrar dene"yi gösterir; yerleşim/genel çakışma metni yok', (tester) async {
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

      env.cloud.updateEndpointError = notApplied;
      await tapKey(tester, 'btn_prepare_1');
      await pumpUntil(tester, env, () => present('setup_retry'), reason: 'hata kutusu çıkmadı');

      expect(find.text(notApplied.message), findsOneWidget, reason: 'sunucunun açıklaması "Neden?" altında');
      expect(find.text('Süre panoda uygulanmadı'), findsOneWidget);
      expect(find.text('Kanal yerleşimi değişti'), findsNothing);
      expect(find.textContaining('Kanal tipi'), findsNothing);
      expect(find.textContaining('İşlem çakıştı'), findsNothing, reason: 'genel (yönetici çağıran) 409 metni gösterilmez');
      expect(find.text('Tekrar dene'), findsOneWidget);
      expect(env.device.shutterRuntime(1), 20, reason: 'pano geçici süreye geçmedi');
    });
  });
}
