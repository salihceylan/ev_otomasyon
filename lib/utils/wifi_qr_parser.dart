import 'dart:convert';

/// Modem etiketlerindeki ve telefonların "Wi-Fi paylaş" ekranındaki karekodların
/// standart biçimini çözer:
///
///   WIFI:T:WPA;S:Ev_Agi;P:sifre123;H:false;;
///
/// Alan sırası serbesttir. `\`, `;`, `,`, `:` ve `"` karakterleri ters bölü ile kaçışlanır;
/// değer çift tırnak içindeyse tırnaklar atılır (içteki `\"` kaçışı korunur).
///
/// Cihaz (firmware) sınırları uygulanır: SSID 1..32 bayt (UTF-8), WPA parolası 8..63 bayt, açık
/// ağda parola yok. **WEP ve kurumsal (EAP) ağlar desteklenmez** (açık hata nedeniyle reddedilir);
/// kontrol karakterleri reddedilir. Ham metin hiçbir zaman "ağ adı" olarak kullanılmaz.
class WifiQrCredentials {
  const WifiQrCredentials({
    required this.ssid,
    required this.password,
    this.security = 'WPA',
    this.hidden = false,
  });

  final String ssid;
  final String password;

  /// Normalleştirilmiş güvenlik: `WPA` (WPA/WPA2/WPA3-PSK/SAE) veya `nopass` (açık ağ).
  final String security;
  final bool hidden;

  bool get isOpen => security == 'nopass';
}

/// Wi-Fi karekodu çözümleme hatası.
enum WifiQrError {
  /// `WIFI:` ile başlamıyor.
  notWifi('Bu bir Wi-Fi karekodu değil.'),
  tooLong('Karekod çok uzun.'),
  malformed('Wi-Fi karekodu bozuk.'),
  missingSsid('Karekodda ağ adı yok.'),
  ssidTooLong('Ağ adı 32 baytı aşıyor; pano bu ağa bağlanamaz.'),
  controlCharacters('Karekodda geçersiz (kontrol) karakterler var.'),
  passwordLength('Wi-Fi şifresi 8 ile 63 karakter arasında olmalıdır.'),
  wepUnsupported('WEP şifreli ağlar desteklenmiyor. Lütfen WPA/WPA2 kullanın.'),
  eapUnsupported('Kurumsal (EAP) ağlar desteklenmiyor.'),
  unknownSecurity('Bu güvenlik türü desteklenmiyor.');

  const WifiQrError(this.message);

  /// Kullanıcıya gösterilebilir Türkçe mesaj.
  final String message;
}

/// [WifiQrParser.parseDetailed] sonucu: ya [credentials] ya da [error] doludur.
class WifiQrParseResult {
  const WifiQrParseResult.ok(WifiQrCredentials this.credentials) : error = null;
  const WifiQrParseResult.failed(WifiQrError this.error) : credentials = null;

  final WifiQrCredentials? credentials;
  final WifiQrError? error;

  bool get isOk => credentials != null;
}

class WifiQrParser {
  WifiQrParser._();

  /// Karekod geçerli ve desteklenen bir Wi-Fi karekodu değilse `null` döner.
  static WifiQrCredentials? parse(String? raw) => parseDetailed(raw).credentials;

  /// Neden reddedildiğini de döndürür (arayüzde "WEP desteklenmiyor" gibi mesajlar için).
  static WifiQrParseResult parseDetailed(String? raw) {
    if (raw == null) return const WifiQrParseResult.failed(WifiQrError.notWifi);
    final text = raw.trim();
    if (text.length < 5 || text.substring(0, 5).toUpperCase() != 'WIFI:') {
      return const WifiQrParseResult.failed(WifiQrError.notWifi);
    }
    if (text.length > 512) return const WifiQrParseResult.failed(WifiQrError.tooLong);

    // 1) Kaçışlı ayırıcılara göre ham alanları böl.
    final rawFields = <String, String>{};
    final body = text.substring(5);
    final key = StringBuffer();
    final value = StringBuffer();
    var readingKey = true;
    var pendingEscape = false;

    void flush() {
      final k = key.toString().trim().toUpperCase();
      if (k.isNotEmpty && !rawFields.containsKey(k)) {
        rawFields[k] = value.toString();
      }
      key.clear();
      value.clear();
      readingKey = true;
    }

    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      final sink = readingKey ? key : value;
      if (pendingEscape) {
        // Kaçışlı karakter olduğu gibi (ters bölüsüyle) saklanır; çözme sonraki adımda.
        sink
          ..write('\\')
          ..write(ch);
        pendingEscape = false;
      } else if (ch == '\\') {
        pendingEscape = true;
      } else if (ch == ';') {
        flush();
      } else if (ch == ':' && readingKey) {
        readingKey = false;
      } else {
        sink.write(ch);
      }
    }
    if (pendingEscape) return const WifiQrParseResult.failed(WifiQrError.malformed);
    flush();

    String decode(String rawValue) {
      var inner = rawValue;
      if (inner.length >= 2 && inner.startsWith('"') && _endsWithUnescapedQuote(inner)) {
        inner = inner.substring(1, inner.length - 1);
      }
      final out = StringBuffer();
      for (var i = 0; i < inner.length; i++) {
        final ch = inner[i];
        if (ch == '\\' && i + 1 < inner.length) {
          out.write(inner[++i]);
        } else {
          out.write(ch);
        }
      }
      return out.toString();
    }

    final ssid = decode(rawFields['S'] ?? '');
    final security = decode(rawFields['T'] ?? '').trim().toUpperCase();
    final password = decode(rawFields['P'] ?? '');
    final hidden = decode(rawFields['H'] ?? '').trim().toLowerCase() == 'true';

    // 2) Kurumsal (EAP) ve WEP açıkça reddedilir.
    if (rawFields.containsKey('E') ||
        rawFields.containsKey('A') ||
        rawFields.containsKey('I') ||
        rawFields.containsKey('PH2') ||
        security.contains('EAP')) {
      return const WifiQrParseResult.failed(WifiQrError.eapUnsupported);
    }
    if (security == 'WEP') return const WifiQrParseResult.failed(WifiQrError.wepUnsupported);

    bool? open;
    if (security.isEmpty) {
      open = password.isEmpty;
    } else if (security == 'NOPASS') {
      open = true;
    } else if (security.startsWith('WPA') || security == 'SAE') {
      open = false;
    } else {
      return const WifiQrParseResult.failed(WifiQrError.unknownSecurity);
    }

    // 3) SSID doğrulaması.
    if (ssid.isEmpty) return const WifiQrParseResult.failed(WifiQrError.missingSsid);
    if (utf8.encode(ssid).length > 32) {
      return const WifiQrParseResult.failed(WifiQrError.ssidTooLong);
    }
    if (_hasControlCharacters(ssid)) {
      return const WifiQrParseResult.failed(WifiQrError.controlCharacters);
    }

    // 4) Parola doğrulaması.
    if (open) {
      return WifiQrParseResult.ok(
        WifiQrCredentials(ssid: ssid, password: '', security: 'nopass', hidden: hidden),
      );
    }
    if (_hasControlCharacters(password)) {
      return const WifiQrParseResult.failed(WifiQrError.controlCharacters);
    }
    final passwordBytes = utf8.encode(password).length;
    if (passwordBytes < 8 || passwordBytes > 63) {
      return const WifiQrParseResult.failed(WifiQrError.passwordLength);
    }
    return WifiQrParseResult.ok(
      WifiQrCredentials(ssid: ssid, password: password, security: 'WPA', hidden: hidden),
    );
  }

  /// Son çift tırnak kaçışsız mı? (`\"` ile biten değer tırnaklı sayılmaz.)
  static bool _endsWithUnescapedQuote(String value) {
    if (!value.endsWith('"')) return false;
    var backslashes = 0;
    for (var i = value.length - 2; i >= 0 && value[i] == '\\'; i--) {
      backslashes++;
    }
    return backslashes.isEven;
  }

  static bool _hasControlCharacters(String value) {
    for (final unit in value.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return true;
    }
    return false;
  }
}
