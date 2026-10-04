import '../config/app_config.dart';
import 'capabilities.dart';
import 'json_utils.dart';

/// Oturum açmış kullanıcı (`/auth/login` -> `user`).
///
/// Kimlik **UUID string**'tir (CONTRACTS §0). Erişim belirteci (token) bu modelde tutulmaz
/// ve diske yazılmaz; yalnızca `SecureStorageService` token anahtarlarında durur.
class UserModel {
  const UserModel({
    required this.id,
    required this.email,
    required this.fullName,
    this.phone = '',
    this.role = 'user',
    this.adminNotes,
    this.mustChangePassword = false,
    this.emailVerified = false,
  });

  /// Kullanıcı UUID'si (servis PIN oturumunda boş: kullanıcı satırı yoktur).
  final String id;
  final String email;
  final String fullName;
  final String phone;

  /// **Küresel** rol: `user` | `service_user` | `super_user` | `service_session`.
  /// Ev yetkisi bu alandan değil `HomeModel.role`'den gelir (bkz. `Capabilities`).
  final String role;
  final String? adminNotes;

  /// Sunucu parola değiştirmeyi zorunlu kıldı (`must_change_password`; ör. teknisyenin açtığı ya da
  /// yöneticinin parola verdiği hesap). Arayüz parola değiştirme ekranına **zorlamalıdır**
  /// (`AutomationState.mustChangePassword`); başarılı `changePassword` sonrası `false` olur.
  final bool mustChangePassword;

  /// E-posta doğrulanmış mı (`email_verified`).
  final bool emailVerified;

  GlobalRole get globalRole => GlobalRole.parse(role);
  bool get isSuperUser => globalRole == GlobalRole.superUser;
  bool get isServiceUser => globalRole == GlobalRole.serviceUser;
  bool get isServiceSession => globalRole == GlobalRole.serviceSession;
  bool get isServiceManagerOrSuper => isSuperUser || isServiceUser;

  /// Sunucunun TEKNİK yer tutucu e-posta alan adları (UYELIK-07): telefonla açılmış hesap
  /// (`phone_<no>@ahbu.local`), e-postasını gizleyen Apple hesabı (`apple.<özet>@users.noreply.invalid`) ve
  /// silinmiş hesap (`deleted+<id>@deleted.invalid`). Gerçek posta kutusu değildir; kullanıcıya gösterilmez.
  static const List<String> _placeholderEmailDomains = <String>[
    '@ahbu.local',
    '@users.noreply.invalid',
    '@deleted.invalid',
  ];

  /// [email] sunucunun teknik yer tutucusu mu? (Büyük/küçük harf ve baş/son boşluk duyarsız.) Yeni sunucu bu
  /// hesaplarda `email:null` döndürür; eski sunucuya karşı istemci de aynı kuralı uygular (savunma).
  static bool isPlaceholderEmail(String? email) {
    final value = email?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return false;
    for (final domain in _placeholderEmailDomains) {
      if (value.endsWith(domain)) return true;
    }
    return false;
  }

  /// Sunucu e-posta alanını uygulamanın tuttuğu biçime çevirir: `null` / metin dışı / yer tutucu -> boş metin
  /// ("e-posta yok"; profil "Belirtilmedi" gösterir).
  static String contactEmailFrom(Object? raw) {
    final value = asString(raw) ?? '';
    return isPlaceholderEmail(value) ? '' : value;
  }

  /// Gösterilebilir e-posta (kırpılmış): yoksa ya da yer tutucuysa boş metin.
  String get contactEmail => isPlaceholderEmail(email) ? '' : email.trim();

  factory UserModel.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id'] ?? json['user_id']);
    if (id == null) throw const FormatException('Kullanıcı kimliği yok');
    final rawRole = asNonEmptyString(json['role']);
    final parsed = GlobalRole.parse(rawRole);
    return UserModel(
      id: id,
      // Yeni sunucu yer tutucu yerine `null` döner; eski sunucunun yer tutucusu da (ve eski sürümün sakladığı kayıt
      // geri yüklenirken) boş sayılır: karşılama adı, ayarlar ve profil teknik adresi göstermez.
      email: contactEmailFrom(json['email']),
      fullName: asString(json['full_name'] ?? json['fullName'] ?? json['name']) ?? '',
      phone: asString(json['phone']) ?? '',
      // Tanınan rol normalleştirilir; tanınmayan rol olduğu gibi (küçük harf) tutulur ve
      // `GlobalRole.unknown` olarak değerlendirilir (hiçbir yetki vermez).
      role: rawRole == null
          ? 'user'
          : (parsed == GlobalRole.unknown ? rawRole.toLowerCase() : parsed.wire),
      adminNotes: asNonEmptyString(json['admin_notes']),
      mustChangePassword:
          asBool(json['must_change_password'] ?? json['mustChangePassword']) ?? false,
      emailVerified: asBool(json['email_verified'] ?? json['emailVerified']) ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'email': email,
        'full_name': fullName,
        'phone': phone,
        'role': role,
        if (adminNotes != null) 'admin_notes': adminNotes,
        'must_change_password': mustChangePassword,
        'email_verified': emailVerified,
      };

  UserModel copyWith({
    String? fullName,
    String? phone,
    String? role,
    bool? mustChangePassword,
    bool? emailVerified,
  }) =>
      UserModel(
        id: id,
        email: email,
        fullName: fullName ?? this.fullName,
        phone: phone ?? this.phone,
        role: role ?? this.role,
        adminNotes: adminNotes,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
        emailVerified: emailVerified ?? this.emailVerified,
      );
}

/// Sunucunun giriş yöntemi yetenekleri (`GET /auth/capabilities`, kimliksiz; UYELIK-04).
///
/// Eksik / tanınmayan alan `false`'tur (fail-closed). Uç olmayan eski sunucu (404) ve ağ hatası çağıranda
/// [none] sayılır: giriş ekranı sunucunun desteklemediği bir yolu (ör. SMS göndericisi bağlı olmayan sunucuda
/// telefonla giriş) sunmaz.
class AuthCapabilities {
  const AuthCapabilities({this.smsOtp = false, this.google = false, this.apple = false});

  /// Hiçbir isteğe bağlı yöntem yok (uç yok / hata).
  static const AuthCapabilities none = AuthCapabilities();

  /// Telefon numarasıyla SMS kodu (OTP) girişi.
  final bool smsOtp;
  final bool google;
  final bool apple;

  factory AuthCapabilities.fromJson(Map<String, dynamic> json) => AuthCapabilities(
        smsOtp: asBool(json['sms_otp']) ?? false,
        google: asBool(json['google']) ?? false,
        apple: asBool(json['apple']) ?? false,
      );

  @override
  String toString() => 'AuthCapabilities(smsOtp: $smsOtp, google: $google, apple: $apple)';
}

/// `DELETE /auth/account` başarı yanıtı (UYELIK-03).
class AccountDeletionResult {
  const AccountDeletionResult({this.releasedHomes = 0});

  /// Hesapla birlikte silinen, başka üyesi ve panosu olmayan (tek sahipli) daire sayısı (`released_homes`).
  /// Eski sunucu bu alanı vermez: 0.
  final int releasedHomes;
}

/// `GET /homes` → `access_state`: eve erişimin **o anki** durumu (sunucu saatiyle).
///
/// Sunucu `active` | `not_started` | `expired` döndürür; sözleşme metni `guest_expired` yazdığı için o
/// da [expired] sayılır. Tanınmayan değer [unknown]'dır (süre penceresi alanlarıyla karar verilir).
enum HomeAccessState {
  /// Erişim açık.
  active('active'),

  /// Misafir penceresi henüz başlamadı.
  notStarted('not_started'),

  /// Misafir / süreli erişim bitti.
  expired('expired'),

  /// Sunucu söylemedi ya da tanınmayan değer.
  unknown('unknown');

  const HomeAccessState(this.wire);

  final String wire;

  /// Erişim şu an kapalı mı (`not_started` veya `expired`).
  bool get isBlocked => this == notStarted || this == expired;

  static HomeAccessState parse(String? raw) {
    switch (raw?.trim().toLowerCase().replaceAll('-', '_')) {
      case 'active':
        return HomeAccessState.active;
      case 'not_started':
      case 'notstarted':
      case 'pending':
        return HomeAccessState.notStarted;
      case 'expired':
      case 'guest_expired':
        return HomeAccessState.expired;
    }
    return HomeAccessState.unknown;
  }
}

/// Ev / daire (`GET /homes`: `{ id, name, role, timezone, mqtt_topic_id }`).
class HomeModel {
  const HomeModel({
    required this.id,
    required this.name,
    this.address,
    this.mqttTopicId = '',
    this.role,
    this.timezone = 'Europe/Istanbul',
    this.guestValidFrom,
    this.guestValidUntil,
    this.serverMarkedExpired = false,
    this.accessState = HomeAccessState.unknown,
  });

  /// Ev UUID'si (**String**; `int` ev kimliği yoktur).
  final String id;
  final String name;
  final String? address;

  /// `ev/{topicId}/state|status` konu kimliği (rastgele `h_` + 16 hex). Sır gibi ele alınır:
  /// loglanmaz. Boş olabilir; gerçek değer `mqtt-credentials` yanıtındaki `topic_id`'dir.
  final String mqttTopicId;

  /// **Ev bazlı** rol (normalleştirilmiş): `owner` | `resident` | `guest` | `service_user`
  /// | `service_session`. Eski adlar eşlenir (`member` -> `resident`).
  final String? role;

  /// IANA saat dilimi (zamanlı kurallar bu dilimde değerlendirilir).
  final String timezone;

  /// Misafir penceresi (yalnızca `guest` rolünde dolu).
  final DateTime? guestValidFrom;
  final DateTime? guestValidUntil;

  /// Sunucu bu evi "süresi dolmuş" işaretledi (`is_expired` **veya** engelleyici `access_state`).
  final bool serverMarkedExpired;

  /// Sunucunun bildirdiği erişim durumu (`access_state`); bildirmediyse [HomeAccessState.unknown].
  final HomeAccessState accessState;

  HomeRole get homeRole => HomeRole.parse(role);
  bool get isOwnerRole => homeRole == HomeRole.owner;
  bool get isGuestRole => homeRole == HomeRole.guest;

  /// Misafir penceresi [now] için geçerli değil mi? (Misafir olmayan roller için `false`.)
  bool isGuestExpiredAt(DateTime now) {
    if (!isGuestRole) return false;
    if (serverMarkedExpired) return true;
    final until = guestValidUntil;
    if (until == null) return true; // pencere bilinmiyor -> kapalı (fail-closed)
    if (now.isAfter(until)) return true;
    final from = guestValidFrom;
    return from != null && now.isBefore(from);
  }

  factory HomeModel.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id'] ?? json['home_id']);
    if (id == null) throw const FormatException('Ev kimliği yok');
    final rawRole = asNonEmptyString(json['role']);
    String? role;
    if (rawRole != null) {
      final parsed = HomeRole.parse(rawRole);
      role = parsed == HomeRole.unknown ? rawRole.toLowerCase() : parsed.wire;
    }
    final accessState = HomeAccessState.parse(asNonEmptyString(json['access_state']));
    return HomeModel(
      id: id,
      name: asNonEmptyString(json['name']) ?? 'Evim',
      address: asNonEmptyString(json['address']),
      mqttTopicId:
          asNonEmptyString(json['mqtt_topic_id'] ?? json['mqttTopicId'] ?? json['mqtt_username']) ??
              '',
      role: role,
      timezone: asNonEmptyString(json['timezone']) ?? 'Europe/Istanbul',
      guestValidFrom: asDate(json['valid_from'] ?? json['guest_valid_from']),
      guestValidUntil: asDate(json['valid_until'] ?? json['guest_valid_until']),
      // `is_expired` ile engelleyici `access_state` çelişirse güvenli taraf: erişim kapalı.
      serverMarkedExpired: (asBool(json['is_expired']) ?? false) || accessState.isBlocked,
      accessState: accessState,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        if (address != null) 'address': address,
        'mqtt_topic_id': mqttTopicId,
        if (role != null) 'role': role,
        'timezone': timezone,
        if (guestValidFrom != null) 'valid_from': guestValidFrom!.toUtc().toIso8601String(),
        if (guestValidUntil != null) 'valid_until': guestValidUntil!.toUtc().toIso8601String(),
        'is_expired': serverMarkedExpired,
        'access_state': accessState.wire,
      };

  HomeModel copyWith({String? role, bool? serverMarkedExpired, HomeAccessState? accessState}) =>
      HomeModel(
        id: id,
        name: name,
        address: address,
        mqttTopicId: mqttTopicId,
        role: role ?? this.role,
        timezone: timezone,
        guestValidFrom: guestValidFrom,
        guestValidUntil: guestValidUntil,
        serverMarkedExpired: serverMarkedExpired ?? this.serverMarkedExpired,
        accessState: accessState ?? this.accessState,
      );
}

// Düzenli ifade bir kez derlenir (PF-25): `shutterBaseName` panjur kartı/öğesi türetiminde her çağrıda çalışır.
final RegExp _shutterDirectionSuffix = RegExp(
  r'\s*\(?\s*(yukar[ıi]|a[sş]a[gğ][ıi]|yukari|asagi|up|down)\s*\)?\s*$',
  caseSensitive: false,
  unicode: true,
);

/// Panjur adındaki yön ekini ("Salon Panjur Yukarı" -> "Salon Panjur") atar.
String shutterBaseName(String name, {String fallback = 'Panjur'}) {
  final cleaned = name.replaceAll(_shutterDirectionSuffix, '').trim();
  return cleaned.isEmpty ? fallback : cleaned;
}

/// Kontrol noktası (röle / panjur) — `GET /homes/:id/endpoints`.
///
/// Uç nokta ve ev kimlikleri UUID'dir (**String**). Kanal numarası **1 tabanlıdır**; panjur
/// çifti `pair` = 1 tabanlı panjur numarasıdır (`pair N` = röle `2N-1` YUKARI, `2N` AŞAĞI).
class EndpointModel {
  const EndpointModel({
    required this.id,
    required this.homeId,
    this.deviceId,
    this.deviceUuid,
    required this.channel,
    this.shutterPair,
    required this.name,
    required this.room,
    required this.endpointType,
    required this.currentState,
    this.shutterPosition = 0,
    this.shutterDurationSec = 20,
    this.deviceOnline,
  });

  final String id;
  final String homeId;

  /// Cihazın iç (`devices.id`) kimliği.
  final String? deviceId;

  /// Cihazın `AHBU-...` kimliği (komut hedefi olarak tercih edilir).
  final String? deviceUuid;

  /// 1 tabanlı röle numarası (`channel_index`).
  final int channel;

  /// 1 tabanlı panjur numarası (sunucu `shutter_pair_index`); yoksa kanaldan türetilir.
  final int? shutterPair;
  final String name;
  final String room;

  /// `light` | `shutter` | `impulse` | `plug`.
  final String endpointType;
  final bool currentState;

  /// 0 = tam kapalı, 100 = tam açık.
  final int shutterPosition;

  /// Panjur motor süresi (1..300 sn).
  final int shutterDurationSec;

  /// Cihazın çevrimiçi bilgisi (`device_online`); bilinmiyorsa `null`.
  final bool? deviceOnline;

  bool get isLight => endpointType == 'light';
  bool get isShutter => endpointType == 'shutter';
  bool get isImpulse => endpointType == 'impulse';
  bool get isPlug => endpointType == 'plug';

  /// Röle gibi anahtarlanan uç nokta (panjur değil).
  bool get isRelayLike => !isShutter;

  /// 1 tabanlı panjur numarası (yalnızca panjurlar için anlamlı).
  int get pair => shutterPair ?? ((channel + 1) ~/ 2);

  /// Panjurun YUKARI rölesi (`channel == 2*pair-1`): panjuru temsil eden "birincil" satır.
  bool get isPrimaryShutterRow => isShutter && channel == 2 * pair - 1;

  static const Set<String> knownTypes = <String>{'light', 'shutter', 'impulse', 'plug'};

  factory EndpointModel.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id'] ?? json['endpoint_id']);
    if (id == null) throw const FormatException('Uç nokta kimliği yok');
    final channel = asInt(json['channel_index'] ?? json['channel']);
    if (channel == null || channel < 1 || channel > 64) {
      throw const FormatException('Geçersiz kanal');
    }
    final type = (asNonEmptyString(json['type'] ?? json['endpoint_type']) ?? 'light').toLowerCase();
    if (!knownTypes.contains(type)) throw const FormatException('Bilinmeyen uç nokta tipi');
    final pairRaw = asInt(json['shutter_pair_index'] ?? json['shutter_pair'] ?? json['pair']);
    final position = asInt(json['current_position'] ?? json['shutter_position'] ?? json['pos']);
    final duration = asInt(json['shutter_duration_sec']);
    return EndpointModel(
      id: id,
      homeId: asNonEmptyString(json['home_id']) ?? '',
      deviceId: asNonEmptyString(json['device_id']),
      deviceUuid: asNonEmptyString(json['device_uuid']),
      channel: channel,
      shutterPair: (pairRaw != null && pairRaw >= 1) ? pairRaw : null,
      name: asNonEmptyString(json['name']) ?? 'Uç Nokta',
      room: asNonEmptyString(json['room']) ?? 'Genel',
      endpointType: type,
      currentState: asBool(json['current_state'] ?? json['state']) ?? false,
      shutterPosition: clampInt(position ?? 0, 0, 100),
      shutterDurationSec: clampInt(duration ?? 20, 1, 300),
      deviceOnline: asBool(json['device_online'] ?? json['online']),
    );
  }

  EndpointModel copyWith({
    bool? currentState,
    int? shutterPosition,
    String? name,
    String? room,
    int? shutterDurationSec,
    bool? deviceOnline,
  }) {
    return EndpointModel(
      id: id,
      homeId: homeId,
      deviceId: deviceId,
      deviceUuid: deviceUuid,
      channel: channel,
      shutterPair: shutterPair,
      name: name ?? this.name,
      room: room ?? this.room,
      endpointType: endpointType,
      currentState: currentState ?? this.currentState,
      shutterPosition: shutterPosition ?? this.shutterPosition,
      shutterDurationSec: shutterDurationSec ?? this.shutterDurationSec,
      deviceOnline: deviceOnline ?? this.deviceOnline,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'home_id': homeId,
        if (deviceId != null) 'device_id': deviceId,
        if (deviceUuid != null) 'device_uuid': deviceUuid,
        'channel_index': channel,
        if (shutterPair != null) 'shutter_pair_index': shutterPair,
        'name': name,
        'room': room,
        'type': endpointType,
        'current_state': currentState,
        'current_position': shutterPosition,
        'shutter_duration_sec': shutterDurationSec,
        if (deviceOnline != null) 'device_online': deviceOnline,
      };
}

/// Servis PIN'i (`POST /homes/:homeId/service-token`). PIN yalnızca bir kez gösterilir.
class ServiceTokenModel {
  const ServiceTokenModel({required this.pin, required this.expiresAt});

  final String pin;
  final DateTime expiresAt;

  factory ServiceTokenModel.fromJson(Map<String, dynamic> json, {DateTime? now}) {
    final pin = asNonEmptyString(json['pin'] ?? json['service_pin']);
    if (pin == null) throw const FormatException('Servis PIN yok');
    return ServiceTokenModel(
      pin: pin,
      // Sözleşme: 2 saat geçerli. Sunucu süreyi vermezse güvenli varsayılan.
      expiresAt: asDate(json['expires_at']) ??
          (now ?? DateTime.now()).toUtc().add(const Duration(hours: 2)),
    );
  }
}

/// Davet (aile bireyi / süreli misafir).
class InvitationModel {
  const InvitationModel({
    required this.code,
    required this.role,
    required this.expiresAt,
    this.homeName,
    this.qrPayload,
    this.guestName,
    this.guestValidFrom,
    this.guestValidUntil,
  });

  final String code;

  /// `resident` | `guest`.
  final String role;
  final DateTime expiresAt;
  final String? homeName;

  /// QR içeriği (`AHBU-INVITE:<kod>`).
  final String? qrPayload;
  final String? guestName;
  final DateTime? guestValidFrom;
  final DateTime? guestValidUntil;

  /// QR'a yazılacak içerik (sunucu vermediyse `AHBU-INVITE:<kod>`).
  String get qrContent => qrPayload ?? 'AHBU-INVITE:$code';

  /// Hem snake_case hem (geçiş dönemi) camelCase alanları kabul eder.
  factory InvitationModel.fromJson(Map<String, dynamic> json, {DateTime? now}) {
    final code = asNonEmptyString(json['code'] ?? json['invite_code'] ?? json['inviteCode']);
    if (code == null) throw const FormatException('Davet kodu yok');
    final rawRole = asNonEmptyString(json['role']) ?? 'resident';
    return InvitationModel(
      code: code,
      role: HomeRole.parse(rawRole) == HomeRole.unknown
          ? rawRole.toLowerCase()
          : HomeRole.parse(rawRole).wire,
      expiresAt: asDate(json['expires_at'] ?? json['expiresAt']) ??
          (now ?? DateTime.now()).toUtc().add(const Duration(hours: 24)),
      homeName: asNonEmptyString(json['home_name'] ?? json['homeName']),
      qrPayload: asNonEmptyString(json['qr_payload'] ?? json['qrPayload']),
      guestName: asNonEmptyString(json['guest_name'] ?? json['guestName']),
      guestValidFrom: asDate(json['guest_valid_from'] ?? json['guestValidFrom']),
      guestValidUntil: asDate(json['guest_valid_until'] ?? json['guestValidUntil']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'role': role,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        if (homeName != null) 'home_name': homeName,
        if (qrPayload != null) 'qr_payload': qrPayload,
        if (guestName != null) 'guest_name': guestName,
        if (guestValidFrom != null) 'guest_valid_from': guestValidFrom!.toUtc().toIso8601String(),
        if (guestValidUntil != null) 'guest_valid_until': guestValidUntil!.toUtc().toIso8601String(),
      };
}

/// Evdeki bir üye / misafir (`GET /homes/:homeId/members`).
///
/// `userId` **UUID string**'tir; (eski `int` varsayımı üye silmeyi bozuyordu).
class HomeMember {
  const HomeMember({
    required this.userId,
    required this.fullName,
    required this.role,
    this.email = '',
    this.phone = '',
    this.validFrom,
    this.validUntil,
    this.isExpired = false,
    this.joinedAt,
  });

  final String userId;
  final String fullName;
  final String email;
  final String phone;

  /// Normalleştirilmiş ev rolü.
  final String role;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final bool isExpired;
  final DateTime? joinedAt;

  HomeRole get homeRole => HomeRole.parse(role);
  bool get isOwner => homeRole == HomeRole.owner;
  bool get isGuest => homeRole == HomeRole.guest;

  factory HomeMember.fromJson(Map<String, dynamic> json) {
    final userId = asNonEmptyString(json['user_id'] ?? json['userId'] ?? json['id']);
    if (userId == null) throw const FormatException('Üye kimliği yok');
    final rawRole = asNonEmptyString(json['role']) ?? 'resident';
    final parsed = HomeRole.parse(rawRole);
    return HomeMember(
      userId: userId,
      fullName: asString(json['full_name'] ?? json['fullName']) ?? '',
      // Telefonla açılmış üyenin yer tutucu e-postası gösterilmez (üye kartı telefona düşer; UYELIK-07).
      email: UserModel.contactEmailFrom(json['email']),
      phone: asString(json['phone']) ?? '',
      role: parsed == HomeRole.unknown ? rawRole.toLowerCase() : parsed.wire,
      validFrom: asDate(json['valid_from'] ?? json['validFrom']),
      validUntil: asDate(json['valid_until'] ?? json['validUntil']),
      isExpired: asBool(json['is_expired'] ?? json['isExpired']) ?? false,
      joinedAt: asDate(json['joined_at'] ?? json['joinedAt'] ?? json['created_at']),
    );
  }
}

/// Cihaz Envanteri ve QR Yaşam Döngüsü Modeli (Faz 6 & Süper Yönetici).
class InventoryDeviceModel {
  const InventoryDeviceModel({
    required this.id,
    this.serialNo,
    required this.deviceUuid,
    required this.macAddress,
    required this.model,
    required this.batchNo,
    required this.status,
    this.failedAttempts = 0,
    this.lockedUntil,
    this.claimedAt,
    required this.createdAt,
    this.updatedAt,
    this.claimedHomeName,
    this.claimedUserEmail,
    required this.qrClaimUrl,
  });

  final String id;
  final int? serialNo;
  final String deviceUuid;
  final String macAddress;

  /// Boş = sunucu bilgi vermedi (uydurma varsayılan kullanılmaz).
  final String model;
  final String batchNo;
  final String status;
  final int failedAttempts;
  final DateTime? lockedUntil;
  final DateTime? claimedAt;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? claimedHomeName;
  final String? claimedUserEmail;
  final String qrClaimUrl;

  String get formattedSerial =>
      serialNo != null ? '#${serialNo.toString().padLeft(4, '0')}' : '#----';
  bool get isInStock => status.toUpperCase() == 'IN_STOCK';
  bool get isClaimed =>
      status.toUpperCase() == 'CLAIMED' || status.toUpperCase() == 'INSTALLED';
  bool get isSuspended => status.toUpperCase() == 'SUSPENDED';
  bool get isRevoked => status.toUpperCase() == 'REVOKED';

  String get statusLabel {
    switch (status.toUpperCase()) {
      case 'IN_STOCK':
        return 'STOKTA';
      case 'CLAIMED':
        return 'DEVREDE';
      case 'INSTALLED':
        return 'MONTAJLANDI';
      case 'SUSPENDED':
        return 'ASKIDA';
      case 'REVOKED':
        return 'İPTAL';
      default:
        return status.toUpperCase();
    }
  }

  factory InventoryDeviceModel.fromJson(Map<String, dynamic> json) {
    final uuid = asNonEmptyString(json['device_uuid']);
    if (uuid == null) throw const FormatException('Cihaz kimliği yok');
    return InventoryDeviceModel(
      id: asString(json['id']) ?? '',
      serialNo: asInt(json['serial_no']),
      deviceUuid: uuid,
      macAddress: asString(json['mac_address']) ?? '',
      model: asString(json['model']) ?? '',
      batchNo: asString(json['batch_no']) ?? '',
      status: asNonEmptyString(json['status']) ?? 'IN_STOCK',
      failedAttempts: asInt(json['failed_attempts']) ?? 0,
      lockedUntil: asDate(json['locked_until']),
      claimedAt: asDate(json['claimed_at']),
      createdAt: asDate(json['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: asDate(json['updated_at']),
      claimedHomeName: asNonEmptyString(json['claimed_home_name']),
      claimedUserEmail: asNonEmptyString(json['claimed_user_email']),
      qrClaimUrl: asNonEmptyString(json['qr_claim_url']) ??
          '${AppConfig.productionClaimUrl}?uid=${Uri.encodeQueryComponent(uuid)}',
    );
  }

  InventoryDeviceModel copyWith({String? status, DateTime? updatedAt}) => InventoryDeviceModel(
        id: id,
        serialNo: serialNo,
        deviceUuid: deviceUuid,
        macAddress: macAddress,
        model: model,
        batchNo: batchNo,
        status: status ?? this.status,
        failedAttempts: failedAttempts,
        lockedUntil: lockedUntil,
        claimedAt: claimedAt,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        claimedHomeName: claimedHomeName,
        claimedUserEmail: claimedUserEmail,
        qrClaimUrl: qrClaimUrl,
      );
}
