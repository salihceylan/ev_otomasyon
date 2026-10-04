import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../models/api_models.dart';
import '../../../../models/capabilities.dart';
import '../../../../models/cloud_models.dart';
import '../../../../services/api_exception.dart';
import '../../../../utils/qr_claim_parser.dart';
import '../panel/uncertain_outcome_card.dart';
import '../service_target.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';
import 'customer_logic.dart';
import 'identify_logic.dart';

/// Claim sonucunun kullanıcıya gösterilen özeti (gizli bulut kimliği YOK).
@immutable
class ClaimSummary {
  const ClaimSummary({
    required this.homeId,
    required this.homeName,
    required this.deviceUuid,
    this.warnings = const <String>[],
    this.customerAccountCreated = false,
    this.inviteSent,
    this.technicianAccessExpiresAt,
    this.credentialReceived = false,
    this.localKeyReady = false,
  });

  final String homeId;
  final String homeName;
  final String deviceUuid;

  /// Kısmi başarı uyarıları (ör. davet e-postası gönderilemedi): kullanıcıya MUTLAKA gösterilir.
  final List<String> warnings;
  final bool customerAccountCreated;
  final bool? inviteSent;
  final DateTime? technicianAccessExpiresAt;

  /// Sunucu cihaz bulut kimliğini bu yanıtta verdi mi (kimliğin kendisi tutulmaz/gösterilmez).
  final bool credentialReceived;

  /// Cihaz yerel anahtarı claim sırasında (internet varken) **bellekte** hazırlandı mı. Hazırlanamadıysa
  /// sorun değildir: Wi-Fi adımı anahtarsızdır; anahtar 6. adımda (ev ağında, internet geri gelince) alınır.
  final bool localKeyReady;

  bool get hasWarnings => warnings.isNotEmpty;

  ClaimSummary withLocalKeyReady() => ClaimSummary(
        homeId: homeId,
        homeName: homeName,
        deviceUuid: deviceUuid,
        warnings: warnings,
        customerAccountCreated: customerAccountCreated,
        inviteSent: inviteSent,
        technicianAccessExpiresAt: technicianAccessExpiresAt,
        credentialReceived: credentialReceived,
        localKeyReady: true,
      );
}

/// Adım 4 - Daireye Bağla (claim).
///
/// Geçiş koşulu: sunucu claim'i başarıyla kabul etti ve `home_id` döndü. Bundan sonra **her adım bu
/// eve** işlem yapar ([ServiceTarget]); claim edilen ev aktif ev değildir.
///
/// Gizlilik: kurulum PIN'i ve müşteri kodu claim sonrası bellekten silinir; claim yanıtındaki tek
/// seferlik bulut kimliği yalnızca bellekte ([SetupContext.pendingCredential]) tutulur (uygulama
/// kapanırsa 6. adımda sunucudan yeniden üretilir). Cihaz anahtarı **en iyi çabayla** ve yalnızca
/// bellekte (güvenli depoya YAZILMADAN) hazırlanır: yalnızca hazırlanmamış (anahtarsız) pano için
/// kurulum ağında (internet yok) gerekebilir; normal akışta 5. adım anahtarsızdır ve anahtar 6. adımda alınır.
///
/// **Yanıtı kaybolan claim:** claim POST'u sunucuda tamamlanıp yanıt telefona ulaşmayabilir (bağlantı koptu / zaman
/// aşımı: [UncertainOutcomeCard.isUncertain]). Sunucu idempotent DEĞİLDİR ve PIN/OTP tek kullanımlıktır: aynı isteği
/// körlemesine yinelemek `409` verir ve kurulum hedefsiz kalırdı. Bu yüzden sonucu belirsiz kalan bir claim'den sonraki
/// her deneme (tekrar dene ya da yeniden "Daireye Bağla") ÖNCE cihazın bu hesaba açık bir dairede kayıtlı olup
/// olmadığını sunucudan doğrular; bulursa POST göndermeden hedefi o daireye atar.
class ClaimLogic extends SetupLogic {
  ClaimLogic(super.ctx, this.identify, this.customer);

  final IdentifyLogic identify;
  final CustomerLogic customer;

  @override
  int get number => SetupSteps.claim;

  ClaimSummary? _summary;
  String _homeNameInput = '';

  /// Son claim isteğinin sonucu belirsiz kalan cihazın kimliği (istek sunucuda tamamlanmış olabilir); `null` = yok.
  String? _uncertainFor;

  /// Doğrulama için en çok bu kadar daire sorgulanır (servis personeline claim sonrası verilen üyelikli evler önce).
  static const int _maxHomesToCheck = 30;

  ClaimSummary? get summary => _summary;
  String get homeNameInput => _homeNameInput;

  @override
  bool get isComplete => _summary != null && ctx.target != null;

  void setHomeName(String value) => _homeNameInput = value;

  /// Cihazı müşterinin dairesine bağlar.
  Future<bool> claim({String? homeName}) {
    final name = (homeName ?? _homeNameInput).trim();
    if (name.length > 100) {
      fail(const SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Daire adı çok uzun',
        why: 'Daire adı en fazla 100 karakter olabilir.',
        todo: 'Adı kısaltıp tekrar deneyin.',
        retryable: false,
      ));
      return Future<bool>.value(false);
    }
    return run('Cihaz müşterinin dairesine bağlanıyor', () async {
      if (!ctx.access.canClaim) {
        throw ApiException.forbidden('Geçici servis oturumuyla cihaz eşlenemez.');
      }
      final uid = identify.uid;
      final pin = identify.pinForClaim;
      final id = customer.identifier;
      final code = customer.codeForClaim;
      if (uid == null || pin == null) {
        throw const SetupProblemException(SetupProblem(
          kind: SetupProblemKind.validation,
          title: 'Kurulum PIN\'i eksik',
          why: 'Cihaz etiketi okunmadı veya PIN bellekten silindi.',
          todo: '2. adımda etiketi yeniden okutun.',
          retryable: false,
          fixStep: SetupSteps.identify,
        ));
      }
      if (id == null || code == null) {
        throw const SetupProblemException(SetupProblem(
          kind: SetupProblemKind.validation,
          title: 'Müşteri onay kodu eksik',
          why: 'Müşteriye kod gönderilmedi ya da kod girilmedi.',
          todo: '3. adımda kodu gönderin ve müşterinin söylediği 6 haneli kodu yazın.',
          retryable: false,
          fixStep: SetupSteps.customer,
        ));
      }

      // Önceki isteğin sonucu belirsiz kaldıysa (yanıt kaybolmuş olabilir) ikinci POST göndermeden önce cihazın bu
      // hesaba açık bir dairede kayıtlı olup olmadığına bakılır. Bulunamazsa istek hiç ulaşmamış demektir: normal claim.
      if (_uncertainFor == uid) {
        final home = await _findClaimedHome(uid);
        if (home != null) {
          await _adoptRecovered(uid, home, name);
          return;
        }
      }

      final result = await _claimMapped(uid, pin, id, code, name);
      _uncertainFor = null;
      final deviceUuid = QrClaimParser.normalizeUid(result.deviceUuid) ?? uid;
      final homeName = result.homeName.isNotEmpty ? result.homeName : name;
      ctx.target = ServiceTarget(
        homeId: result.homeId,
        deviceUuid: deviceUuid,
        homeName: homeName,
        ip: IdentifyLogic.apHost,
      );
      ctx.pendingCredential = result.deviceCredential;
      final account = result.customerAccount;
      _summary = ClaimSummary(
        homeId: result.homeId,
        homeName: homeName,
        deviceUuid: deviceUuid,
        warnings: result.warnings,
        customerAccountCreated: account?.created ?? false,
        inviteSent: account?.inviteSent,
        technicianAccessExpiresAt: result.technicianAccessExpiresAt,
        credentialReceived: result.deviceCredential != null,
      );
      // Gizli girdiler bellekten silinir.
      identify.clearSecrets();
      customer.clearSecrets();
      await _prepareLocalKey();
    });
  }

  /// Cihaz anahtarını (yalnızca bellekte) internet varken hazırla: hazırlanmamış pano kurulum ağında
  /// (internet yok) ilk hazırlık için buna ihtiyaç duyabilir. Başarısızlık claim'i bozmaz.
  Future<void> _prepareLocalKey() async {
    try {
      final key = await ctx.fetchLocalKey();
      if (key != null && key.isNotEmpty) {
        ctx.target = ctx.target!.copyWith(localKey: key);
        _summary = _summary!.withLocalKeyReady();
      }
    } on SetupCancelled {
      rethrow;
    } catch (_) {
      // Anahtar 6. adımda (ev ağında, internet geri gelince) alınır; claim başarısını bozmaz.
    }
  }

  /// Sonucu belirsiz kalan önceki claim isteğinin sunucuda tamamlanıp tamamlanmadığını doğrular: cihaz bu hesabın
  /// görebildiği bir dairede kayıtlıysa o daire döner. Servis personeline claim sonrası 72 saatlik üyelik verilir
  /// (CONTRACTS §1.5b); bu evler önce sorgulanır. Cihaz hiçbirinde yoksa `null` (istek sunucuya ulaşmamıştı ya da hesap
  /// evi göremiyor). Ağ/oturum hatasında "yok" DENMEZ: hata yukarı verilir (durum doğrulanamadan ikinci claim gönderilmez).
  Future<HomeModel?> _findClaimedHome(String uid) async {
    final homes = await ctx.cloud.fetchHomes();
    bool usable(HomeModel h) => !h.serverMarkedExpired;
    final candidates = <HomeModel>[
      ...homes.where((h) => usable(h) && h.homeRole == HomeRole.serviceUser),
      ...homes.where((h) => usable(h) && h.homeRole != HomeRole.serviceUser),
    ].take(_maxHomesToCheck);
    final wanted = uid.toUpperCase();
    for (final home in candidates) {
      ctx.ensureActive();
      try {
        final devices = await ctx.cloud.devices(home.id);
        if (devices.any((d) => d.deviceUuid.toUpperCase() == wanted)) return home;
      } on ApiException catch (e) {
        if (e.isForbidden || e.isNotFound) continue; // bu eve erişim yok: cihaz burada değil
        rethrow;
      }
    }
    return null;
  }

  /// Yanıtı kaybolan claim'in sunucuda tamamlandığı doğrulandı: hedef [home]'a atanır. Tek seferlik bulut kimliği ve
  /// müşteri hesabı bilgisi yanıtla birlikte kayboldu: kimlik 6. adımda sunucudan yeniden üretilir, kullanıcıya uyarı gösterilir.
  Future<void> _adoptRecovered(String uid, HomeModel home, String typedName) async {
    final homeName = home.name.isNotEmpty ? home.name : typedName;
    ctx.target = ServiceTarget(
      homeId: home.id,
      deviceUuid: uid,
      homeName: homeName,
      ip: IdentifyLogic.apHost,
    );
    ctx.pendingCredential = null;
    _summary = ClaimSummary(
      homeId: home.id,
      homeName: homeName,
      deviceUuid: uid,
      warnings: <String>[
        'Önceki isteğin yanıtı alınamadı; cihazın "$homeName" dairesine bağlandığı sunucudan doğrulandı. '
            'Müşteri hesabı ve davet e-postası bilgisi alınamadı: müşteriye e-postasını kontrol etmesini söyleyin.',
      ],
    );
    _uncertainFor = null;
    identify.clearSecrets();
    customer.clearSecrets();
    // Normal claim yolunda (`AutomationState.claimDevice`) olduğu gibi uygulamanın daire listesi de tazelenir (hata fırlatmaz).
    await ctx.state.fetchHomes(autoSelect: false);
    await _prepareLocalKey();
  }

  Future<ClaimResult> _claimMapped(
    String uid,
    String pin,
    CustomerIdentifier id,
    String code,
    String homeName,
  ) async {
    try {
      return await ctx.state.claimDevice(
        uid,
        pin,
        homeName: homeName.isEmpty ? null : homeName,
        targetOwner: id.value,
        otpCode: code,
      );
    } on ApiException catch (e) {
      if (UncertainOutcomeCard.isUncertain(e)) {
        _uncertainFor = uid;
        throw _uncertainProblem(e);
      }
      throw _mapClaimError(e);
    } on TimeoutException catch (e) {
      _uncertainFor = uid;
      throw _uncertainProblem(e);
    }
  }

  /// Bağlantı koptu / zaman aşımı: isteğin sunucuya ulaşıp ulaşmadığı bilinmiyor. Mevcut ağ hatası açıklaması
  /// korunur, belirsizlik ve "tekrar dene"nin ne yapacağı eklenir.
  SetupProblemException _uncertainProblem(Object error) {
    final base = SetupProblems.fromError(error, step: number);
    return SetupProblemException(SetupProblem(
      kind: base.kind,
      title: base.title,
      why: '${base.why} Bağlantı koptuğu için isteğin sunucuya ulaşıp ulaşmadığı bilinmiyor; '
          'cihaz daireye bağlanmış olabilir.',
      todo: '${base.todo} "Tekrar dene"ye basınca önce cihazın daireye bağlanıp bağlanmadığı sunucudan kontrol edilir; '
          'aynı istek körlemesine yinelenmez.',
    ));
  }

  /// Claim hatalarını doğru adıma yönlendirir (PIN -> 2, müşteri kodu -> 3).
  Object _mapClaimError(ApiException e) {
    if (e.isForbidden && e.remainingAttempts != null) {
      identify.clearPin();
      return SetupProblemException(SetupProblem(
        kind: SetupProblemKind.forbidden,
        title: 'Kurulum PIN\'i hatalı',
        why: e.message,
        todo: 'Etiketteki 6 haneli "KURULUM PIN" değerini kontrol edip 2. adımda yeniden yazın. '
            'Kalan deneme hakkı: ${e.remainingAttempts}.',
        retryable: false,
        fixStep: SetupSteps.identify,
        remainingAttempts: e.remainingAttempts,
      ));
    }
    if (e.isPinLocked) {
      identify.clearPin();
      return SetupProblemException(SetupProblem(
        kind: SetupProblemKind.locked,
        title: 'Cihaz geçici olarak kilitlendi',
        why: e.message,
        todo: 'Çok sayıda hatalı PIN denendi. Yaklaşık ${SetupProblems.waitText(e.retryAfter)} bekleyin; '
            'ardından PIN\'i etiketten dikkatle okuyup yeniden deneyin.',
        retryable: false,
        fixStep: SetupSteps.identify,
        retryAfter: e.retryAfter,
      ));
    }
    if (e.isValidation && e.remainingAttempts != null) {
      customer.clearCode();
      return SetupProblemException(SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Müşteri kodu hatalı',
        why: e.message,
        todo: 'Müşteriden kodu tekrar öğrenip 3. adımda yeniden yazın. Kalan deneme hakkı: ${e.remainingAttempts}.',
        retryable: false,
        fixStep: SetupSteps.customer,
        remainingAttempts: e.remainingAttempts,
      ));
    }
    if (e.isValidation && e.message.toLowerCase().contains('doğrulama kodu')) {
      customer.expireCode();
      return SetupProblemException(SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Müşteri kodunun süresi doldu',
        why: e.message,
        todo: '3. adıma dönüp müşteriye yeni bir kod gönderin.',
        retryable: false,
        fixStep: SetupSteps.customer,
      ));
    }
    if (e.isRateLimited) {
      return SetupProblemException(SetupProblem(
        kind: SetupProblemKind.rateLimited,
        title: 'Çok fazla hatalı kod denendi',
        why: e.message,
        todo: 'Güvenlik için bir süre beklemeniz gerekiyor: yaklaşık ${SetupProblems.waitText(e.retryAfter)}. '
            'Sonra 3. adımda yeni kod isteyin.',
        retryable: false,
        fixStep: SetupSteps.customer,
        retryAfter: e.retryAfter,
      ));
    }
    if (e.statusCode == 409 && _uncertainFor != null && _uncertainFor == identify.uid) {
      // Önceki isteğin yanıtı alınamamıştı ve cihaz şimdi "zaten bağlı": önceki istek sunucuda tamamlanmış, ama bu
      // hesap o daireyi doğrulayamadı (ör. süper yönetici: evin üyesi değil). Kör "başka daireye bağlı" demek yanıltır.
      return const SetupProblemException(SetupProblem(
        kind: SetupProblemKind.conflict,
        title: 'Cihaz önceki denemede daireye bağlanmış olabilir',
        why: 'Önceki isteğin yanıtı alınamamıştı ve sunucu şimdi cihazın zaten bir daireye bağlı olduğunu bildiriyor. '
            'Önceki istek sunucuda tamamlanmış olabilir; ancak bu hesapla o daire doğrulanamadı.',
        todo: 'Sihirbazdan çıkıp servis panelinde ilgili daireyi seçin ve "Mevcut cihazlarım" listesinden cihazın '
            '"Bağlantıyı yeniden kur" ya da "Testleri yap" düğmesiyle kuruluma devam edin. Cihaz listede yoksa '
            'yöneticiye başvurun.',
        retryable: false,
      ));
    }
    if (e.statusCode == 409 || e.isNotFound) {
      return SetupProblemException(SetupProblem(
        kind: e.statusCode == 409 ? SetupProblemKind.conflict : SetupProblemKind.notFound,
        title: 'Cihaz eşlenemedi',
        why: e.message,
        todo: 'Cihaz başka bir daireye bağlı veya envanterde yok olabilir. Etiketi kontrol edin; '
            'sorun sürerse yöneticiye başvurun.',
        retryable: false,
        fixStep: SetupSteps.identify,
      ));
    }
    return e;
  }

  /// Kayıttan: claim daha önce yapıldı (hedef `ServiceTarget` olarak verilir).
  void adopt(ServiceTarget target, {String homeName = ''}) {
    _summary = ClaimSummary(
      homeId: target.homeId,
      homeName: homeName.isNotEmpty ? homeName : target.homeName,
      deviceUuid: target.deviceUuid,
    );
  }
}
