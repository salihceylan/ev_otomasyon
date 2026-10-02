import '../setup_context.dart';
import '../setup_steps.dart';

/// Adım 1 - Hazırlık: oturum ve sunucu **gerçekten** doğrulanır.
///
/// Geçiş koşulu: sunucu, kimlik doğrulamalı `GET /homes` isteğine başarıyla yanıt verdi (oturum geçerli,
/// internet var). Gerekenler listesi bilgilendiricidir; "tamam" işaretiyle geçilmez.
///
/// [onVerified]: doğrulama **hangi yoldan olursa olsun** (sayfa açılışı, "Bağlantıyı Doğrula", "Tekrar dene")
/// başarıyla bitince çağrılır; mevcut cihaz kipinde bekleyen başlangıç adımına (ör. 7. adım) atlamak için
/// kullanılır (ilk doğrulama başarısız olup elle yeniden denenirse başlangıç adımı kaybolmasın).
class PreparationLogic extends SetupLogic {
  PreparationLogic(super.ctx, {this.onVerified});

  final void Function()? onVerified;

  @override
  int get number => SetupSteps.preparation;

  bool _verified = false;
  DateTime? _verifiedAt;

  bool get verified => _verified;
  DateTime? get verifiedAt => _verifiedAt;

  @override
  bool get isComplete => _verified && !ctx.isSessionOver;

  /// Oturumu ve sunucuyu doğrular.
  Future<bool> verify() async {
    final ok = await run('Oturum ve sunucu bağlantısı doğrulanıyor', () async {
      await ctx.cloud.fetchHomes();
      _verified = true;
      _verifiedAt = ctx.clock.now();
    });
    if (ok) onVerified?.call();
    return ok;
  }
}
