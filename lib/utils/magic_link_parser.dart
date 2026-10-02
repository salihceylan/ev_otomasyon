import 'qr_claim_parser.dart';

/// Sihirli (tek kullanımlık) bağlantının türü.
enum MagicLinkKind {
  /// `https://<izinli>/reset-password#token=<opak>`: sıfırlama e-postasındaki bağlantı. Arayüz
  /// yeni parola ister (`AutomationState.resetPassword(token: ...)`) ya da doğrudan giriş yaptırır
  /// (`AutomationState.loginWithMagicLink`).
  resetPassword,

  /// `https://<izinli>/magic-login#token=<opak>` (veya `/auth/magic-login`): tek seferlik giriş.
  magicLogin,
}

/// Sihirli bağlantıdan çıkan **gizli** belirteç. [toString] belirteci gizler (loglara sızmasın).
class MagicLink {
  const MagicLink({required this.kind, required this.token});

  final MagicLinkKind kind;

  /// Opak, tek kullanımlık belirteç (base64url). Loglanmaz, saklanmaz.
  final String token;

  @override
  String toString() => 'MagicLink(kind: $kind, token: ******)';
}

/// Sihirli bağlantı reddedilme nedeni.
enum MagicLinkError {
  empty('Bağlantı boş.'),
  tooLong('Bağlantı çok uzun.'),
  malformed('Bağlantı okunamadı veya bozuk.'),
  notHttps('Bağlantı güvenli (https) bir adres içermiyor.'),
  hostNotAllowed('Bu bağlantı tanınan bir sunucuya ait değil.'),
  badPath('Bu bağlantı bir giriş/şifre sıfırlama bağlantısı değil.'),
  missingToken('Bağlantıda doğrulama kodu yok.'),
  tokenInQuery('Bağlantı geçersiz biçimde.'),
  badToken('Bağlantıdaki doğrulama kodu geçersiz.');

  const MagicLinkError(this.message);

  /// Kullanıcıya gösterilebilir Türkçe mesaj.
  final String message;
}

class MagicLinkParseResult {
  const MagicLinkParseResult.ok(MagicLink this.link) : error = null;
  const MagicLinkParseResult.failed(MagicLinkError this.error) : link = null;

  final MagicLink? link;
  final MagicLinkError? error;

  bool get isOk => link != null;
}

/// Sihirli bağlantı çözücü (CONTRACTS §1.1b).
///
/// Biçim: `https://<izinli ana makine>/reset-password#token=<opak>` (ya da `/magic-login`,
/// `/auth/magic-login`). Kurallar:
///
/// * Yalnızca `https`, kullanıcı bilgisi yok, varsayılan port, izinli ana makine
///   ([QrClaimParser.defaultAllowedHosts]).
/// * Belirteç **yalnızca URL parçasında** (`#token=`) kabul edilir: sorgu dizgisindeki (`?token=`)
///   belirteç sunucu/proxy loglarına düşeceği için **reddedilir**.
/// * Belirteç `^[A-Za-z0-9_-]{16,512}$` (base64url); tam bir `token` parametresi olmalıdır.
/// * Metin 1024 karakteri ve kontrol karakterlerini aşamaz.
///
/// Belirteç **GET ile gönderilmez**: sunucu `GET /auth/magic-login` için `405` döndürür; belirteç
/// `POST /auth/magic-login` gövdesiyle gönderilir.
class MagicLinkParser {
  MagicLinkParser._();

  static const int maxLength = 1024;

  static final RegExp tokenPattern = RegExp(r'^[A-Za-z0-9_-]{16,512}$');

  static const Map<String, MagicLinkKind> _paths = <String, MagicLinkKind>{
    '/reset-password': MagicLinkKind.resetPassword,
    '/magic-login': MagicLinkKind.magicLogin,
    '/auth/magic-login': MagicLinkKind.magicLogin,
  };

  /// Geçerli sihirli bağlantı değilse `null`.
  static MagicLink? parse(String? raw, {Set<String>? allowedHosts}) =>
      parseDetailed(raw, allowedHosts: allowedHosts).link;

  /// Neden reddedildiğini de döndürür.
  static MagicLinkParseResult parseDetailed(String? raw, {Set<String>? allowedHosts}) {
    if (raw == null) return const MagicLinkParseResult.failed(MagicLinkError.empty);
    final text = raw.trim();
    if (text.isEmpty) return const MagicLinkParseResult.failed(MagicLinkError.empty);
    if (text.length > maxLength) return const MagicLinkParseResult.failed(MagicLinkError.tooLong);
    if (_hasControlCharacters(text)) {
      return const MagicLinkParseResult.failed(MagicLinkError.malformed);
    }

    final Uri? uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      return const MagicLinkParseResult.failed(MagicLinkError.malformed);
    }
    if (uri.scheme != 'https') return const MagicLinkParseResult.failed(MagicLinkError.notHttps);
    if (uri.userInfo.isNotEmpty) {
      return const MagicLinkParseResult.failed(MagicLinkError.hostNotAllowed);
    }
    final hosts = (allowedHosts ?? QrClaimParser.defaultAllowedHosts)
        .map((h) => h.toLowerCase())
        .toSet();
    final host = uri.host.toLowerCase();
    if (host.isEmpty || !hosts.contains(host)) {
      return const MagicLinkParseResult.failed(MagicLinkError.hostNotAllowed);
    }
    if (uri.hasPort && uri.port != 443) {
      return const MagicLinkParseResult.failed(MagicLinkError.hostNotAllowed);
    }

    var path = uri.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final kind = _paths[path];
    if (kind == null) return const MagicLinkParseResult.failed(MagicLinkError.badPath);

    // Belirteç yalnızca parçada; sorguda olması reddedilir (loglara sızma riski).
    if (uri.hasQuery && _queryHasToken(uri.query)) {
      return const MagicLinkParseResult.failed(MagicLinkError.tokenInQuery);
    }
    final fragment = uri.fragment;
    if (fragment.isEmpty) return const MagicLinkParseResult.failed(MagicLinkError.missingToken);

    String? token;
    try {
      for (final part in fragment.split('&')) {
        if (part.isEmpty) continue;
        final eq = part.indexOf('=');
        final key = Uri.decodeQueryComponent(eq < 0 ? part : part.substring(0, eq));
        if (key != 'token') continue;
        if (token != null) return const MagicLinkParseResult.failed(MagicLinkError.badToken);
        token = eq < 0 ? '' : Uri.decodeQueryComponent(part.substring(eq + 1));
      }
    } on FormatException {
      return const MagicLinkParseResult.failed(MagicLinkError.malformed);
    }
    if (token == null) return const MagicLinkParseResult.failed(MagicLinkError.missingToken);
    if (!tokenPattern.hasMatch(token)) {
      return const MagicLinkParseResult.failed(MagicLinkError.badToken);
    }
    return MagicLinkParseResult.ok(MagicLink(kind: kind, token: token));
  }

  static bool _queryHasToken(String query) {
    for (final part in query.split('&')) {
      final eq = part.indexOf('=');
      final key = eq < 0 ? part : part.substring(0, eq);
      try {
        if (Uri.decodeQueryComponent(key) == 'token') return true;
      } on FormatException {
        return true; // bozuk kodlama: güvenli taraf
      }
    }
    return false;
  }

  static bool _hasControlCharacters(String value) {
    for (final unit in value.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return true;
    }
    return false;
  }
}
