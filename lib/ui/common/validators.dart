import 'dart:convert';

/// Kimlik doğrulama formları için **ortak (tek)** doğrulayıcılar (WP-E2).
///
/// Sunucu kuralları (`server/src/services/auth_service.js`) istemciye birebir yansıtılır:
/// e-posta deseni, parola en az 10 karakter / en çok 72 bayt, telefon `^\+?\d{10,15}$`
/// (boşluk, `-`, `(`, `)`, `.` ayırıcıları atılır). **Parolalar hiçbir yerde kırpılmaz.**
class AuthValidators {
  AuthValidators._();

  /// Parola politikası (sunucu: `PASSWORD_MIN_LENGTH`).
  static const int passwordMinLength = 10;

  /// Sunucu: `PASSWORD_MAX_BYTES` (bcrypt 72 bayttan sonrasını yok sayar).
  static const int passwordMaxBytes = 72;

  /// Gevşek ve basit: boşluk, ikinci `@` ve köşeli/yuvarlak parantez, virgül, noktalı virgül, iki
  /// nokta, tırnak ve ters bölü yok; alan adında en az bir nokta ve en az 2 karakterli son etiket.
  /// Sunucudaki desenle aynıdır (geçerli adresleri reddetmez: `+etiket`, uzun TLD, alt alan adı).
  static final RegExp _email = RegExp(r'^[^\s@<>()\[\]\\,;:"]+@[^\s@<>()\[\]\\,;:"]+\.[^\s@<>()\[\]\\,;:"]{2,}$');
  static final RegExp _phone = RegExp(r'^\+?\d{10,15}$');

  /// Geçerli bir e-posta adresi mi (kırpılmış değer üzerinden)?
  static bool isValidEmail(String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty || v.length > 254) return false;
    return _email.hasMatch(v);
  }

  /// Form doğrulayıcısı: boş / geçersiz ise Türkçe mesaj, geçerli ise `null`.
  static String? emailError(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Lütfen e-posta adresinizi girin';
    if (!isValidEmail(v)) return 'Geçerli bir e-posta adresi girin';
    return null;
  }

  /// Giriş formu: **yalnızca boş mu** kontrolü (min uzunluk politikası kayıtta; eski/yönetici
  /// verdiği parolalar kısa olabilir). Değer kırpılmaz.
  static String? loginPasswordError(String? value) {
    if (value == null || value.isEmpty) return 'Lütfen şifrenizi girin';
    return null;
  }

  /// Kayıt / sıfırlama / parola değiştirme politikası (kırpma YOK). Boşluk içeren parolalar geçerlidir.
  static String? passwordPolicyError(String? value, {String emptyMessage = 'Lütfen bir şifre belirleyin'}) {
    if (value == null || value.isEmpty) return emptyMessage;
    if (value.length < passwordMinLength) {
      return 'Şifre en az $passwordMinLength karakter olmalıdır';
    }
    if (utf8.encode(value).length > passwordMaxBytes) {
      return 'Şifre en fazla $passwordMaxBytes bayt (yaklaşık $passwordMaxBytes karakter) olabilir';
    }
    if (value.trim().isEmpty) return 'Şifre yalnızca boşluktan oluşamaz';
    return null;
  }

  /// Ayırıcıları (`boşluk`, `-`, `(`, `)`, `.`) atar; `^\+?\d{10,15}$` değilse `null`.
  /// Ülke kodu eklenmez/çevrilmez: sunucu da yalnızca ayırıcıları atar.
  static String? normalizePhone(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().replaceAll(RegExp(r'[\s\-().]'), '');
    return _phone.hasMatch(s) ? s : null;
  }

  /// Telefon alanı: [required] false ise boş değer geçerlidir.
  static String? phoneError(String? value, {bool required = false}) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return required ? 'Lütfen telefon numaranızı girin' : null;
    if (normalizePhone(v) == null) {
      return 'Geçerli bir telefon numarası girin (örn: 0555 123 45 67)';
    }
    return null;
  }

  /// E-posta **veya** telefon (şifre sıfırlama / devir hedefi). Geçersizse `null`.
  static ParsedIdentifier? parseIdentifier(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s.contains('@')) {
      return isValidEmail(s) ? ParsedIdentifier(IdentifierKind.email, s.toLowerCase()) : null;
    }
    final phone = normalizePhone(s);
    return phone == null ? null : ParsedIdentifier(IdentifierKind.phone, phone);
  }

  /// E-posta/telefon alanı doğrulayıcısı (boş / geçersiz ise Türkçe mesaj).
  static String? identifierError(String? value, {String emptyMessage = 'Lütfen e-posta veya telefon numaranızı girin'}) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return emptyMessage;
    if (parseIdentifier(v) == null) return 'Geçerli bir e-posta adresi veya telefon numarası girin';
    return null;
  }

  /// Altı haneli kod (OTP / sıfırlama / PIN) alanı.
  static String? sixDigitCodeError(String? value, {String emptyMessage = 'Lütfen 6 haneli kodu girin'}) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return emptyMessage;
    if (!RegExp(r'^\d{6}$').hasMatch(v)) return 'Kod tam 6 rakam olmalıdır';
    return null;
  }
}

/// [AuthValidators.parseIdentifier] sonucu.
enum IdentifierKind { email, phone }

class ParsedIdentifier {
  const ParsedIdentifier(this.kind, this.value);

  final IdentifierKind kind;

  /// Normalleştirilmiş değer (e-posta küçük harf; telefon yalnızca rakam ve en başta `+`).
  final String value;

  bool get isEmail => kind == IdentifierKind.email;
  bool get isPhone => kind == IdentifierKind.phone;
}

/// Wi-Fi (cihaz) alan doğrulayıcıları: SSID en çok 32 bayt (UTF-8), WPA parolası 8–63 bayt ya da
/// açık ağ (boş). **Kırpma yapılmaz** (baş/son boşluk geçerli karakterdir).
class WifiValidators {
  WifiValidators._();

  static int byteLength(String value) => utf8.encode(value).length;

  static final RegExp _boardSetupSsid = RegExp(r'^AHBU-[0-9A-F]{6}$');

  /// Panonun **kendi** kurulum/kurtarma ağı adı mı (`AHBU-<MAC son 6 hex büyük harf>`)? Bu ağ modem
  /// bilgisi olamaz: etiketteki ikinci karekod (telefon kamerasıyla okutulacak kurulum ağı) yanlışlıkla
  /// "ev Wi-Fi bilgisi" olarak panoya yüklenirse pano kendi ağına bağlanmaya çalışırdı.
  static bool isBoardSetupNetwork(String ssid) => _boardSetupSsid.hasMatch(ssid);

  static String? ssidError(String ssid) {
    if (ssid.isEmpty) return 'Lütfen Wi-Fi ağ adını (SSID) girin.';
    if (byteLength(ssid) > 32) return 'Ağ adı en fazla 32 bayt olabilir; pano bu ağa bağlanamaz.';
    if (isBoardSetupNetwork(ssid)) {
      return 'Bu ağ panonun KENDİ kurulum ağıdır (AHBU-...). Panonun bağlanacağı modemin (ev) Wi-Fi ağını seçin veya yazın.';
    }
    return null;
  }

  /// [networkSecured]: tarama sonucundan ağın şifreli olduğu biliniyorsa `true` (boş parola reddedilir).
  static String? passwordError(String password, {bool? networkSecured}) {
    if (password.isEmpty) {
      return networkSecured == true ? 'Bu ağ şifreli görünüyor; Wi-Fi şifresini girin.' : null;
    }
    final bytes = byteLength(password);
    if (bytes < 8 || bytes > 63) return 'Wi-Fi şifresi 8 ile 63 karakter arasında olmalıdır.';
    return null;
  }

  /// Baş/son boşluk uyarısı (değer **değiştirilmez**, yalnızca kullanıcı bilgilendirilir).
  static bool hasEdgeWhitespace(String value) => value.isNotEmpty && value != value.trim();
}
