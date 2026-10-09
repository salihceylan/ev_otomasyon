import 'dart:convert';

import 'package:flutter/services.dart';

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

  /// Ayırıcıları (`boşluk`, `-`, `(`, `)`, `.`) atar. TR cep numarası görünümündeyse (karar 11) kanonik
  /// `+905XXXXXXXXX` döner ([canonicalTrPhone]); değilse `^\+?\d{10,15}$` (başka ülke) ya da `null`.
  static String? normalizePhone(String? raw) {
    if (raw == null) return null;
    final tr = canonicalTrPhone(raw);
    if (tr != null) return tr;
    final s = raw.trim().replaceAll(RegExp(r'[\s\-().]'), '');
    return _phone.hasMatch(s) ? s : null;
  }

  static final RegExp _trMobile = RegExp(r'^(?:(?:00|\+)?90|0)?(5\d{9})$');

  /// TR cep numarası (`5XX XXX XX XX`, önünde isteğe bağlı `0` / `90` / `+90` / `0090`, ayırıcılı olabilir) ->
  /// kanonik `+905XXXXXXXXX`; TR cep biçiminde değilse `null`.
  static String? canonicalTrPhone(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().replaceAll(RegExp(r'[\s\-().]'), '');
    final m = _trMobile.firstMatch(s);
    return m == null ? null : '+90${m.group(1)}';
  }

  /// Sabit "+90" önekli telefon alanı ([TrPhoneInputFormatter]): 10 hane, 5 ile başlar. [required] false ise boş geçerli.
  static String? trMobileError(String? value, {bool required = false}) {
    final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return required ? 'Lütfen telefon numaranızı girin' : null;
    if (canonicalTrPhone(value) != null) return null;
    if (!digits.startsWith('5')) return 'Cep numarası 5 ile başlamalıdır (5XX XXX XX XX)';
    return 'Numarayı +90 sonrası 10 hane olarak girin (5XX XXX XX XX)';
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

/// Sabit "+90" önekli telefon alanları için ortak görünüm değerleri (karar 11).
const String kTrPhonePrefix = '+90 ';
const String kTrPhoneHint = '5XX XXX XX XX';

/// Sabit "+90" önekli telefon alanı biçimleyicisi (karar 11): yalnız 10 ulusal hane (5XX XXX XX XX) tutar ve yazarken
/// 3-3-2-2 gruplar. Yapıştırılan `0555…`, `90555…`, `+90555…`, `0090555…` öneki ayıklanır; harf/ayırıcı atılır.
/// Gönderimde [AuthValidators.canonicalTrPhone] `+905XXXXXXXXX` verir.
class TrPhoneInputFormatter extends TextInputFormatter {
  const TrPhoneInputFormatter();

  static const List<int> _gaps = <int>[3, 6, 8];

  /// `raw` içindeki rakamlardan ulusal 10 haneyi çıkarır; `stripped`: baştan atılan önek rakamı sayısı.
  static ({String digits, int stripped}) _national(String raw) {
    final all = raw.replaceAll(RegExp(r'\D'), '');
    var d = all;
    if (d.startsWith('0090')) {
      d = d.substring(4);
    } else if (d.length > 10 && d.startsWith('90')) {
      d = d.substring(2);
    }
    while (d.startsWith('0')) {
      d = d.substring(1);
    }
    final stripped = all.length - d.length;
    return (digits: d.length > 10 ? d.substring(0, 10) : d, stripped: stripped);
  }

  /// 10 haneyi `5XX XXX XX XX` biçiminde gruplar (eksik hanelerle de çalışır).
  static String group(String digits) {
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (_gaps.contains(i)) b.write(' ');
      b.write(digits[i]);
    }
    return b.toString();
  }

  /// Kayıtlı bir numarayı (ör. `+905551234567`, `05551234567`) alanın gösterimine çevirir; TR değilse olduğu gibi.
  static String display(String? stored) {
    final canonical = AuthValidators.canonicalTrPhone(stored);
    if (canonical == null) return stored ?? '';
    return group(canonical.substring(3));
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final n = _national(newValue.text);
    final text = group(n.digits);
    final end = newValue.selection.isValid ? newValue.selection.end.clamp(0, newValue.text.length) : newValue.text.length;
    final rawBefore = newValue.text.substring(0, end).replaceAll(RegExp(r'\D'), '').length;
    final digitsBefore = (rawBefore - n.stripped).clamp(0, n.digits.length);
    final offset = digitsBefore + _gaps.where((g) => g < digitsBefore).length;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset.clamp(0, text.length)));
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
