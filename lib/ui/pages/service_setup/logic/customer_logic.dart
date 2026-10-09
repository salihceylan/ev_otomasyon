import '../../../../models/api_models.dart';
import '../../../../models/cloud_models.dart';
import '../../../../services/api_exception.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';
import 'identify_logic.dart';
import '../../../common/validators.dart';

enum CustomerKind { email, phone }

/// Müşteri iletişim bilgisi (sunucunun `normalizeIdentifier` kuralıyla aynı biçimde normalleştirilir).
class CustomerIdentifier {
  const CustomerIdentifier(this.kind, this.value);

  final CustomerKind kind;

  /// Normalleştirilmiş değer: e-posta küçük harf; telefon boşluk/()/./- atılmış (`+` korunur).
  final String value;

  /// Gösterim için maskeli biçim ("m***@g***.com", "***1234").
  String get masked {
    if (kind == CustomerKind.email) {
      final at = value.indexOf('@');
      if (at < 1) return '***';
      final domain = value.substring(at + 1);
      final dot = domain.lastIndexOf('.');
      return '${value[0]}***@${domain.isEmpty ? '' : domain[0]}***${dot > 0 ? domain.substring(dot) : ''}';
    }
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length <= 4 ? '***' : '***${digits.substring(digits.length - 4)}';
  }

  @override
  String toString() => 'CustomerIdentifier($kind, $masked)';
}

final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final RegExp _phonePattern = RegExp(r'^\+?\d{7,15}$');

/// E-posta veya telefonu doğrular + normalleştirir; geçersizse `null`.
CustomerIdentifier? parseCustomerIdentifier(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text.length > 255) return null;
  if (text.contains('@')) {
    final email = text.toLowerCase();
    return _emailPattern.hasMatch(email) ? CustomerIdentifier(CustomerKind.email, email) : null;
  }
  final phone = text.replaceAll(RegExp(r'[\s().\-]'), '');
  // Karar 11: TR cep görünümlüyse (0555…, 90555…, +90555…) kanonik +905XXXXXXXXX; değilse eski kural.
  final tr = AuthValidators.canonicalTrPhone(phone);
  if (tr != null) return CustomerIdentifier(CustomerKind.phone, tr);
  return _phonePattern.hasMatch(phone) ? CustomerIdentifier(CustomerKind.phone, phone) : null;
}

/// [id], oturum açmış teknisyenin kendi e-postası/telefonu mu? ("kendi adına kurulum" engeli)
bool isOwnIdentifier(CustomerIdentifier id, UserModel? user) {
  if (user == null) return false;
  if (id.kind == CustomerKind.email) {
    return user.email.trim().isNotEmpty && user.email.trim().toLowerCase() == id.value;
  }
  String tail(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  final own = tail(user.phone);
  return own.length >= 7 && own == tail(id.value);
}

/// Adım 3 - Müşteri: iletişim bilgisi + müşteriye giden 6 haneli onay kodu.
///
/// Sunucuda kodu **tek başına doğrulayan** bir uç yoktur: kod, müşteri adına cihaz eşlenirken
/// (claim, 4. adım) tüketilir ve orada doğrulanır. Bu adımın gerçek koşulu: sunucu kodu müşteriye
/// gönderdi (cihaz envanterde uygun + müşteri kendisi değil) ve teknisyen 6 haneli kodu girdi.
/// Yanlış/süresi dolmuş kod 4. adımda sunucu yanıtıyla bu adıma geri döndürür.
class CustomerLogic extends SetupLogic {
  CustomerLogic(super.ctx, this.identify);

  final IdentifyLogic identify;

  @override
  int get number => SetupSteps.customer;

  CustomerIdentifier? _identifier;
  String? _code;
  bool _codeSent = false;
  String? _sentMessage;
  DateTime? _resendAt;
  DateTime? _expiresAt;
  String _hint = '';

  /// Kodun gönderildiği cihaz: sunucu kodu cihaza bağlar. Teknisyen 2. adımda başka cihaza geçerse eski
  /// cihaz için gönderilmiş kod bu cihaz için **geçerli sayılmaz** (yeni kod istenir).
  String? _codeUid;

  /// Yeniden gönderme beklemesinin ait olduğu cihaz (429 sonrası da dahil).
  String? _resendUid;

  bool get _boundToCurrentDevice => _codeUid != null && _codeUid == identify.uid;
  bool get _cooldownForCurrentDevice => _resendUid != null && _resendUid == identify.uid;

  CustomerIdentifier? get identifier => _identifier;

  /// Bu cihaz için müşteriye kod gönderildi mi.
  bool get codeSent => _codeSent && _boundToCurrentDevice;
  String? get sentMessage => _sentMessage;
  DateTime? get resendAvailableAt => _resendAt;
  DateTime? get codeExpiresAt => _expiresAt;

  /// Maskeli müşteri bilgisi (kalıcı kayıt ve rapor için).
  String get hint => _identifier?.masked ?? _hint;

  /// Claim için 6 haneli kod (yalnızca [ClaimLogic] okur); yalnızca **bu cihaz** için gönderilmiş kodsa.
  String? get codeForClaim => _boundToCurrentDevice ? _code : null;

  bool get hasCode => _code != null && _boundToCurrentDevice;

  bool isCodeExpired(DateTime now) => _expiresAt != null && !now.isBefore(_expiresAt!);

  /// Yeni kod isteme bekleme süresi bitti mi (sunucu bekleme süresi cihaz+hedef çiftine özeldir).
  bool canResend(DateTime now) => !_cooldownForCurrentDevice || _resendAt == null || !now.isBefore(_resendAt!);

  Duration resendRemaining(DateTime now) {
    final at = _resendAt;
    if (at == null || !_cooldownForCurrentDevice) return Duration.zero;
    final left = at.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  @override
  bool get isComplete =>
      codeSent && _code != null && !isCodeExpired(ctx.clock.now()) && identify.uid != null;

  /// Alan değerini yalnızca doğrular (anlık hata metni); geçerliyse `null`.
  String? validateIdentifier(String raw) {
    if (raw.trim().isEmpty) return 'Müşterinin e-posta adresini veya telefonunu yazın.';
    final id = parseCustomerIdentifier(raw);
    if (id == null) {
      return raw.contains('@')
          ? 'E-posta adresi geçersiz görünüyor (ör. ad@ornek.com).'
          : 'Telefon numarası geçersiz (7-15 rakam; ör. 05551234567).';
    }
    if (isOwnIdentifier(id, ctx.state.currentUser)) {
      return 'Kendi hesabınız adına kurulum yapamazsınız. Müşterinin bilgisini yazın.';
    }
    return null;
  }

  /// Müşteriye onay kodu gönderir (ilk gönderim ve yeniden gönderim).
  Future<bool> sendCode(String raw) {
    final error = validateIdentifier(raw);
    final uid = identify.uid;
    if (error != null || uid == null) {
      fail(
        SetupProblem(
          kind: SetupProblemKind.validation,
          title: uid == null ? 'Önce cihazı tanıyın' : 'Müşteri bilgisi geçersiz',
          why: error ?? 'Cihaz seri numarası henüz okunmadı.',
          todo: uid == null
              ? '2. adımda etiketi okutun.'
              : 'Bilgiyi düzeltip "Kod Gönder"e tekrar basın.',
          retryable: false,
          fixStep: uid == null ? SetupSteps.identify : null,
        ),
      );
      return Future<bool>.value(false);
    }
    final id = parseCustomerIdentifier(raw)!;
    return run('Müşteriye kod gönderiliyor', () async {
      try {
        final res = await ctx.state.requestClaimOtp(deviceUuid: uid, targetOwner: id.value);
        final challenge = CodeChallenge.fromJson(res);
        final now = ctx.clock.now();
        _identifier = id;
        _hint = id.masked;
        _codeSent = true;
        _codeUid = uid;
        _resendUid = uid;
        _code = null;
        _sentMessage = challenge.message.isEmpty ? null : challenge.message;
        _resendAt = now.add(challenge.resendAfter);
        _expiresAt = challenge.expiresIn == null ? null : now.add(challenge.expiresIn!);
      } on SetupCancelled {
        rethrow;
      } catch (error) {
        throw _mapSendError(error);
      }
    });
  }

  /// Gönderim hatası: bekleme süresini yansıtır; cihaz uygunsuzluğunu "etiketi yeniden okutun" ile açıklar.
  Object _mapSendError(Object error) {
    if (error is! ApiException) return error;
    if (error.isRateLimited) {
      final wait = error.retryAfter ?? error.resendAfter ?? CodeChallenge.defaultResendAfter;
      _resendAt = ctx.clock.now().add(wait);
      _resendUid = identify.uid;
      return error;
    }
    if (error.code == 'MAIL_UNAVAILABLE' || error.isDeliveryFailed) {
      return const SetupProblemException(SetupProblem(
        kind: SetupProblemKind.server,
        title: 'Kod e-postası gönderilemedi',
        why: 'Sunucu doğrulama e-postasını şu anda gönderemedi.',
        todo: 'Müşterinin e-posta adresinin doğru olduğundan emin olup birkaç dakika sonra tekrar deneyin.',
      ));
    }
    if (error.reason == 'CUSTOMER_EMAIL_REQUIRED') {
      // Telefonla giren müşterinin hesabında e-posta yok: onay kodu gönderilemez (sözleşme C8); ileti sunucudandır.
      return SetupProblemException(SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Müşteriye onay kodu gönderilemiyor',
        why: error.message,
        todo: 'Müşteriden panoyu kendi uygulamasında etiketteki karekodla sahiplenmesini isteyin; ardından ev sahibinin '
            "oluşturduğu servis PIN'iyle kuruluma devam edin.",
        retryable: false,
      ));
    }
    if (error.isForbidden && error.message.contains('kendi adına')) {
      return SetupProblemException(SetupProblem(
        kind: SetupProblemKind.forbidden,
        title: 'Kendi adınıza kurulum yapılamaz',
        why: error.message,
        todo: 'Cihazın bağlanacağı müşterinin e-posta adresini veya telefonunu yazın.',
        retryable: false,
      ));
    }
    if (error.isNotFound || error.isForbidden || error.statusCode == 409) {
      return SetupProblemException(SetupProblem(
        kind: error.statusCode == 409 ? SetupProblemKind.conflict : SetupProblemKind.forbidden,
        title: 'Cihaz kuruluma uygun değil',
        why: error.message,
        todo: 'Etiketi yeniden okutun. Cihaz envanterde yoksa, askıdaysa veya zaten bir daireye bağlıysa '
            'kurulum yapılamaz; yöneticiye başvurun.',
        retryable: false,
        fixStep: SetupSteps.identify,
      ));
    }
    return error;
  }

  /// Teknisyenin yazdığı 6 haneli kod (yalnızca rakamlar; 6 hane değilse kod yok sayılır).
  void setCode(String raw) {
    if (!_boundToCurrentDevice) return; // bu cihaz için kod gönderilmeden yazılan değer geçersizdir
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    final next = digits.length == 6 ? digits : null;
    if (next == _code) return;
    _code = next;
    ctx.notify();
  }

  /// Claim yanlış kodu bildirdi: kod silinir, yeniden girilmeli.
  void clearCode() {
    _code = null;
    ctx.notify();
  }

  /// Claim kodun süresi dolduğunu bildirdi: yeni kod istenmeli.
  void expireCode() {
    _code = null;
    _codeSent = false;
    _codeUid = null;
    _resendAt = null;
    _resendUid = null;
    _expiresAt = null;
    ctx.notify();
  }

  /// Claim başarılı: kod bellekten silinir.
  void clearSecrets() {
    _code = null;
  }

  /// Müşteriyi değiştirmek için: gönderim durumu ve kod sıfırlanır.
  void resetCustomer() {
    _identifier = null;
    _codeSent = false;
    _codeUid = null;
    _code = null;
    _sentMessage = null;
    _resendAt = null;
    _resendUid = null;
    _expiresAt = null;
    _hint = '';
    clearProblem();
    ctx.notify();
  }

  @override
  Map<String, dynamic> snapshot() => <String, dynamic>{'hint': hint};

  @override
  void restore(Map<String, dynamic> json) {
    _hint = (json['hint'] as String?) ?? '';
  }
}
