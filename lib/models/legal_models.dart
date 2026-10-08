import 'json_utils.dart';

/// Yasal metin modelleri (CONTRACTS: sunucu `server/legal/<slug>.md`; `GET /legal`, `GET /legal/:id`,
/// `POST /legal/accept`, kullanıcıdaki `legal` nesnesi).
///
/// Metnin gövdesini sunucu bloklara ayırır ([LegalBlock]); uygulama bunları kendisi çizer (markdown paketi yoktur).
/// Satır içi biçim yalnız `**kalın**`tır ([parseLegalInline]).

/// Uygulamanın bildiği yasal metinler. [label] ayarlar listesindeki ad, [title] sunucu başlığının yedeğidir (metin
/// yüklenemeden gösterilen ad).
enum LegalDocumentKind {
  /// Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları (onay gerektirir).
  terms(
    id: 'terms',
    slug: 'kullanici-sozlesmesi',
    title: 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları',
    label: 'Kullanıcı Sözleşmesi',
    shortLabel: 'Kullanıcı Sözleşmesi',
  ),

  /// Gizlilik Politikası ve KVKK Aydınlatma Metni (bilgilendirmedir; onay/rıza ile BİRLEŞTİRİLMEZ).
  privacy(
    id: 'privacy',
    slug: 'gizlilik-politikasi',
    title: 'Gizlilik Politikası ve KVKK Aydınlatma Metni',
    label: 'Gizlilik Politikası ve KVKK Aydınlatma Metni',
    shortLabel: 'Gizlilik ve KVKK',
  );

  const LegalDocumentKind({
    required this.id,
    required this.slug,
    required this.title,
    required this.label,
    required this.shortLabel,
  });

  /// Sunucu kimliği (`terms` | `privacy`).
  final String id;

  /// Herkese açık sayfanın kısa adı (`/yasal/<slug>`).
  final String slug;
  final String title;
  final String label;

  /// Üst çubuk / dar alan için kısa ad.
  final String shortLabel;

  /// Herkese açık sayfanın yolu (sunucu kökü altında).
  String get publicPath => '/yasal/$slug';

  /// Kimlik ya da kısa addan bulur; tanınmıyorsa `null`.
  static LegalDocumentKind? fromId(String? raw) {
    final value = raw?.trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    for (final kind in values) {
      if (kind.id == value || kind.slug == value) return kind;
    }
    return null;
  }
}

/// Oturumdaki kullanıcının yasal metin durumu (sunucu `publicUser().legal`).
///
/// Nesne yoksa (eski sunucu, eski uygulamanın sakladığı kullanıcı kaydı) [none]: onay GEREKMEZ. Onay gereksinimini
/// ([needsAcceptance]) sunucu hesaplar (yalnız kesinleşmiş metin, personel dışı hesap); istemci yeniden türetmez.
class UserLegalStatus {
  const UserLegalStatus({
    this.termsAcceptedVersion,
    this.termsCurrentVersion,
    this.termsStatus,
    this.needsAcceptance = false,
  });

  /// Yasal durum bilgisi yok: onay gerekmez.
  static const UserLegalStatus none = UserLegalStatus();

  /// Kullanıcının onayladığı son Kullanıcı Sözleşmesi sürümü (hiç onaylamadıysa `null`).
  final int? termsAcceptedVersion;

  /// Sunucudaki güncel Kullanıcı Sözleşmesi sürümü (metin yüklenmemişse `null`).
  final int? termsCurrentVersion;

  /// Güncel metnin durumu: `draft` | `final`; bilinmiyorsa `null`.
  final String? termsStatus;

  /// Kullanıcı devam etmeden önce güncel sözleşmeyi onaylamalı mı (sunucu kararı).
  final bool needsAcceptance;

  /// [raw] `legal` nesnesi; Map değilse [none]. Anlaşılmayan `needs_acceptance` onay İSTEMEZ (sunucu kararı açık olmalı).
  factory UserLegalStatus.fromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return none;
    final status = asNonEmptyString(json['terms_status'] ?? json['termsStatus'])?.toLowerCase();
    return UserLegalStatus(
      termsAcceptedVersion: _positive(json['terms_accepted_version'] ?? json['termsAcceptedVersion']),
      termsCurrentVersion: _positive(json['terms_current_version'] ?? json['termsCurrentVersion']),
      termsStatus: (status == 'draft' || status == 'final') ? status : null,
      needsAcceptance: asBool(json['needs_acceptance'] ?? json['needsAcceptance']) ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'terms_accepted_version': termsAcceptedVersion,
        'terms_current_version': termsCurrentVersion,
        'terms_status': termsStatus,
        'needs_acceptance': needsAcceptance,
      };

  /// [version] sürümü onaylandıktan sonraki durum (sunucu onayı yalnız GÜNCEL sürüm için kaydeder; eski sürüm 409 alır).
  UserLegalStatus withAcceptedTerms(int version) => UserLegalStatus(
        termsAcceptedVersion: version,
        termsCurrentVersion: termsCurrentVersion ?? version,
        termsStatus: termsStatus,
        needsAcceptance: false,
      );

  @override
  bool operator ==(Object other) =>
      other is UserLegalStatus &&
      other.termsAcceptedVersion == termsAcceptedVersion &&
      other.termsCurrentVersion == termsCurrentVersion &&
      other.termsStatus == termsStatus &&
      other.needsAcceptance == needsAcceptance;

  @override
  int get hashCode => Object.hash(termsAcceptedVersion, termsCurrentVersion, termsStatus, needsAcceptance);

  @override
  String toString() => 'UserLegalStatus(accepted: $termsAcceptedVersion, current: $termsCurrentVersion, '
      'status: $termsStatus, needsAcceptance: $needsAcceptance)';
}

int? _positive(Object? raw) {
  final value = asInt(raw);
  return (value != null && value > 0) ? value : null;
}

/// `YYYY-MM-DD` -> `GG.AA.YYYY` (takvim tarihi; saat dilimi çevrilmez). Biçimsiz değer olduğu gibi döner.
String formatLegalDate(String raw) {
  final text = raw.trim();
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(text);
  if (match == null) return text;
  return '${match[3]}.${match[2]}.${match[1]}';
}

/// Yasal metnin herkese açık adresi: API kök adresinin (`.../api`) sunucu kökü + [path] (`/yasal/<slug>`).
/// [path] zaten tam adresse (`http...`) olduğu gibi döner.
String legalPublicUrl(String apiBaseUrl, String path) {
  final trimmedPath = path.trim();
  if (trimmedPath.startsWith('http://') || trimmedPath.startsWith('https://')) return trimmedPath;
  final cleanPath = trimmedPath.startsWith('/') ? trimmedPath : '/$trimmedPath';
  final uri = Uri.tryParse(apiBaseUrl.trim());
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return cleanPath;
  var prefix = uri.path;
  while (prefix.endsWith('/')) {
    prefix = prefix.substring(0, prefix.length - 1);
  }
  if (prefix.endsWith('/api')) prefix = prefix.substring(0, prefix.length - 4);
  return '${uri.scheme}://${uri.authority}$prefix$cleanPath';
}

/// Yasal metin özeti (`GET /legal` listesinin öğesi; tek metin yanıtının üst bilgisi).
class LegalDocumentInfo {
  const LegalDocumentInfo({
    required this.id,
    required this.slug,
    required this.title,
    required this.version,
    required this.effectiveDate,
    required this.status,
    required this.requiresAcceptance,
    required this.url,
  });

  final String id;
  final String slug;
  final String title;

  /// Sürüm (pozitif tam sayı).
  final int version;

  /// Yürürlük tarihi (`YYYY-MM-DD`, ham).
  final String effectiveDate;

  /// `draft` | `final` (açıkça `final` olmayan her değer `draft` sayılır).
  final String status;

  /// Metin onay gerektirir mi (yalnız Kullanıcı Sözleşmesi; aydınlatma metni onaya bağlanmaz).
  final bool requiresAcceptance;

  /// Herkese açık sayfanın yolu (`/yasal/<slug>`).
  final String url;

  /// Kesinleşmemiş (TASLAK) metin.
  bool get isDraft => status != 'final';

  LegalDocumentKind? get kind => LegalDocumentKind.fromId(id);

  /// Yürürlük tarihi `GG.AA.YYYY`.
  String get effectiveDateLabel => formatLegalDate(effectiveDate);

  /// "Sürüm N · Yürürlük: GG.AA.YYYY" (tarih yoksa yalnız sürüm).
  String get metaLine {
    final date = effectiveDateLabel;
    return date.isEmpty ? 'Sürüm $version' : 'Sürüm $version · Yürürlük: $date';
  }

  /// Kimlik, kısa ad ya da geçerli (pozitif) sürüm yoksa [FormatException].
  factory LegalDocumentInfo.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id'])?.toLowerCase();
    final slug = asNonEmptyString(json['slug']);
    final version = _positive(json['version']);
    if (id == null || slug == null || version == null) {
      throw const FormatException('Yasal metin özeti eksik');
    }
    final status = asNonEmptyString(json['status'])?.toLowerCase();
    return LegalDocumentInfo(
      id: id,
      slug: slug,
      title: asNonEmptyString(json['title']) ?? LegalDocumentKind.fromId(id)?.title ?? slug,
      version: version,
      effectiveDate: asNonEmptyString(json['effective_date'] ?? json['effectiveDate']) ?? '',
      status: status == 'final' ? 'final' : 'draft',
      requiresAcceptance: asBool(json['requires_acceptance'] ?? json['requiresAcceptance']) ?? false,
      url: asNonEmptyString(json['url']) ?? '/yasal/$slug',
    );
  }
}

/// Blok türleri (sunucunun izin verdiği markdown alt kümesi).
enum LegalBlockType {
  h1,
  h2,
  h3,

  /// Paragraf.
  p,

  /// Madde işaretli öğe (`- `).
  li,

  /// Numaralı öğe (`1. `); numara [LegalBlock.n].
  oli;

  /// Tanınmayan tür paragraf sayılır (yeni sunucunun metni kaybolmaz, düz metin olarak görünür).
  static LegalBlockType parse(String? raw) {
    final value = raw?.trim().toLowerCase();
    for (final type in values) {
      if (type.name == value) return type;
    }
    return LegalBlockType.p;
  }
}

/// Metin bloğu: `{type, text, n?}`; [text] `**kalın**` parçalar içerebilir.
class LegalBlock {
  const LegalBlock({required this.type, required this.text, this.n});

  final LegalBlockType type;
  final String text;

  /// Numaralı öğenin numarası (yalnız [LegalBlockType.oli]).
  final int? n;

  factory LegalBlock.fromJson(Map<String, dynamic> json) {
    final type = LegalBlockType.parse(asNonEmptyString(json['type']));
    return LegalBlock(
      type: type,
      text: asString(json['text']) ?? '',
      n: type == LegalBlockType.oli ? asInt(json['n']) : null,
    );
  }
}

/// Tam yasal metin (`GET /legal/:id`): üst bilgi + bloklar.
class LegalDocument {
  const LegalDocument({required this.info, required this.blocks});

  final LegalDocumentInfo info;
  final List<LegalBlock> blocks;

  String get id => info.id;
  String get slug => info.slug;
  String get title => info.title;
  int get version => info.version;
  bool get isDraft => info.isDraft;
  String get url => info.url;
  String get metaLine => info.metaLine;

  /// Ekranda gösterilecek bloklar: gövdenin ilk `h1` başlığı metin başlığıyla AYNIYSA atlanır (başlık zaten üstte).
  List<LegalBlock> get bodyBlocks {
    if (blocks.isNotEmpty && blocks.first.type == LegalBlockType.h1 && blocks.first.text.trim() == title.trim()) {
      return blocks.sublist(1);
    }
    return blocks;
  }

  /// Üst bilgi eksikse [FormatException] (bkz. [LegalDocumentInfo.fromJson]); bozuk blok kaydı atlanır.
  factory LegalDocument.fromJson(Map<String, dynamic> json) => LegalDocument(
        info: LegalDocumentInfo.fromJson(json),
        blocks: parseList(json['blocks'], LegalBlock.fromJson, label: 'LegalBlock'),
      );
}

/// Satır içi parça: [text] ve kalın mı.
class LegalInlineSpan {
  const LegalInlineSpan(this.text, {this.bold = false});

  final String text;
  final bool bold;

  @override
  String toString() => bold ? '**$text**' : text;
}

/// Blok metnini `**kalın**` parçalara ayırır. Kapanmayan son `**` işareti düz metin olarak kalır; boş parçalar atlanır.
List<LegalInlineSpan> parseLegalInline(String text) {
  final parts = text.split('**');
  // Tek sayıda işaret (çift sayıda parça): son işaret kapanmamıştır, düz metne katılır.
  if (parts.length.isEven) {
    final tail = parts.removeLast();
    parts[parts.length - 1] = '${parts.last}**$tail';
  }
  return <LegalInlineSpan>[
    for (var i = 0; i < parts.length; i++)
      if (parts[i].isNotEmpty) LegalInlineSpan(parts[i], bold: i.isOdd),
  ];
}

/// `POST /legal/accept` yanıtı: `{document, version, accepted_at}`.
class LegalAcceptance {
  const LegalAcceptance({required this.document, required this.version, this.acceptedAt});

  final String document;
  final int version;
  final DateTime? acceptedAt;

  /// Eksik alanlar istekteki [document] / [version] ile tamamlanır.
  factory LegalAcceptance.fromJson(Map<String, dynamic> json, {required String document, required int version}) =>
      LegalAcceptance(
        document: asNonEmptyString(json['document']) ?? document,
        version: _positive(json['version']) ?? version,
        acceptedAt: asDate(json['accepted_at'] ?? json['acceptedAt']),
      );
}
