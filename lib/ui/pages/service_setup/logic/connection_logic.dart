import '../../../../services/automation_api_service.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';
import 'wifi_logic.dart';

/// 6-9. adımların ortak "panoya yerel ağdan bağlan" işlemi (adres düzenleme + bağlan).
///
/// Pano kimliği (anahtarsız `status`) ve cihaz anahtarı doğrulanmadan hiçbir anahtarlı istek
/// gönderilmez; yanlış panoya bağlanılırsa bağlantı reddedilir ([WrongDeviceException]). Anahtar yoksa
/// sunucudan (ev ağında internetle) alınır; pano anahtarı **reddederse** reddedilen anahtar bırakılır ve
/// yeniden alınır (aynı anahtarı tekrar tekrar göndermek panoyu kilitler).
///
/// Pano **ev ağındaki bir adresten** (kurulum ağı adresi değil) kimlik + anahtarla doğrulandıysa ve ev
/// Wi-Fi ağına bağlı olduğunu bildiriyorsa 5. adım da kanıtlanmış sayılır ([SetupContext.onLanVerified];
/// mevcut cihazda "Testleri yap").
class ConnectionLogic extends SetupLogic {
  ConnectionLogic(super.ctx);

  @override
  int get number => SetupSteps.cloud;

  /// Pano ile doğrulanmış (kimlik + anahtar) bir yerel bağlantı var mı.
  bool get ready {
    final t = ctx.target;
    return t != null && ctx.link.isReadyFor(t.ip);
  }

  @override
  bool get isComplete => ready;

  /// Adres verilirse hedefte güncellenir; sonra panoya bağlanılır.
  Future<bool> connect({String? ip}) {
    if (ip != null) {
      final error = WifiLogic.validateHost(ip);
      if (error != null) {
        fail(SetupProblem(
          kind: SetupProblemKind.validation,
          title: 'Pano adresi geçersiz',
          why: error,
          todo: 'Modem arayüzündeki cihaz listesinden panonun IP adresine bakın.',
          retryable: false,
        ));
        return Future<bool>.value(false);
      }
    }
    return run('Panoya bağlanılıyor', () async {
      if (ip != null) ctx.target = ctx.requireTarget.copyWith(ip: ip.trim());
      await ctx.ensureDeviceReady();
    });
  }

  /// Cihaz anahtarı elle girildi (8-32 görünür ASCII); kullanılıp bağlantı yeniden denenir.
  Future<bool> useManualKey(String key) {
    if (!AutomationApiService.isValidLocalKey(key)) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Cihaz anahtarı geçersiz',
        why: 'Anahtar 8-32 karakter olmalı; boşluk içeremez.',
        todo: 'Anahtarı fabrika/servis kaydından aynen kopyalayın.',
        retryable: false,
      ));
      return Future<bool>.value(false);
    }
    ctx.useManualKey(key);
    return connect();
  }
}
