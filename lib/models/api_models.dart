import 'package:flutter/foundation.dart' show kReleaseMode;

import 'json_utils.dart';

/// `POST /homes/:homeId/mqtt-credentials` yanıtı (CONTRACTS §1.5).
///
/// **Salt-okunur** (yalnızca `state`/`status` abonelik) ve **süreli** kimliktir; istemci süre
/// dolmadan yeniler. Parola hiçbir zaman loglanmaz ([toString] gizler).
class MqttCredentials {
  const MqttCredentials({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.expiresAt,
    required this.topicId,
    this.clientId,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final DateTime expiresAt;

  /// `ev/{topicId}/state|status` konu kimliği.
  final String topicId;

  /// Sunucunun önerdiği (oturuma özgü) istemci kimliği; yoksa istemci üretir.
  final String? clientId;

  factory MqttCredentials.fromJson(Map<String, dynamic> json) {
    final host = asNonEmptyString(json['host']);
    final port = asInt(json['port']);
    final username = asNonEmptyString(json['username']);
    final password = asString(json['password']);
    final topic = asNonEmptyString(json['topic_id'] ?? json['topicId']);
    final expires = asDate(json['expires_at'] ?? json['expiresAt']);
    if (host == null ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        username == null ||
        password == null ||
        password.isEmpty ||
        topic == null ||
        expires == null) {
      throw const FormatException('Geçersiz MQTT kimlik yanıtı');
    }
    return MqttCredentials(
      host: host,
      port: port,
      username: username,
      password: password,
      expiresAt: expires,
      topicId: topic,
      clientId: asNonEmptyString(json['client_id'] ?? json['clientId']),
    );
  }

  @override
  String toString() => 'MqttCredentials(host: $host, port: $port, expiresAt: $expiresAt)';
}

/// `POST /devices/:id/command` yanıtı: `{ delivered, device_online, command_id }`.
class CommandResult {
  const CommandResult({
    required this.delivered,
    this.deviceOnline,
    this.commandId,
    this.noChange = false,
    this.requested,
    this.offlineDevices = const <String>[],
  });

  /// Komut broker'a bırakıldı (cihaza iletim denendi). `false` ise anında geri alınır.
  final bool delivered;

  /// Cihazın çevrimiçi bilgisi (bilinmiyorsa `null`).
  final bool? deviceOnline;

  /// Cihazın `state.last_id` alanında geri yankılayacağı kimlik.
  final String? commandId;

  /// Sunucu: çevrimiçi cihaz zaten hedef değeri bildiriyor (`no_change`); yeni komut yayınlanmadı
  /// ve yeni bir `state` iletisi gelmeyebilir -> komut anında doğrulanmış sayılır.
  final bool noChange;

  /// Çocuk kilidi yanıtında sunucunun kaydettiği **niyet** (`requested`). Gerçek durum yanıtta
  /// DEĞİLDİR (`child_lock_enabled` yoktur): cihazın `state.child_lock` bildirimiyle gelir.
  final bool? requested;

  /// Komutun iletilmediği çevrimdışı panolar (`offline_devices`; çok panolu evde). Boş değilse komut
  /// yalnızca çevrimiçi panolara iletilmiştir: arayüz "bazı panolar çevrimdışı" uyarısı gösterir.
  final List<String> offlineDevices;

  /// Doğrudan (LAN) modda cihaz HTTP 200 döndü: komut kuyruğa alındı.
  static const CommandResult accepted = CommandResult(delivered: true);

  /// 2xx yanıtta `delivered` alanı yoksa [deliveredDefault] kullanılır (varsayılan: iletildi; eski
  /// sunucu uyumu). Güvenlik/ebeveyn denetimi gibi "uygulandı" iddiası taşıyan uçlarda
  /// `deliveredDefault: false` verilir (fail-closed: alan yoksa iletildi sayılmaz).
  factory CommandResult.fromJson(Map<String, dynamic> json, {bool deliveredDefault = true}) =>
      CommandResult(
        delivered: asBool(json['delivered']) ?? deliveredDefault,
        deviceOnline: asBool(json['device_online'] ?? json['deviceOnline']),
        commandId: asNonEmptyString(json['command_id'] ?? json['commandId']),
        noChange: asBool(json['no_change'] ?? json['noChange']) ?? false,
        requested: asBool(json['requested']),
        offlineDevices: _asStringList(json['offline_devices'] ?? json['offlineDevices']),
      );
}

/// `GET /devices/child-lock/:homeId` içindeki pano satırı: `{ device_uuid, online, child_lock_enabled }`.
class ChildLockDeviceInfo {
  const ChildLockDeviceInfo({
    required this.deviceUuid,
    this.online = false,
    this.enabled = false,
  });

  final String deviceUuid;
  final bool online;

  /// Panonun **bildirdiği** (cihaz `state.child_lock`) kilit durumu.
  final bool enabled;

  factory ChildLockDeviceInfo.fromJson(Map<String, dynamic> json) {
    final uuid = asNonEmptyString(json['device_uuid'] ?? json['uid']);
    if (uuid == null) throw const FormatException('Pano kimliği yok');
    return ChildLockDeviceInfo(
      deviceUuid: uuid,
      online: asBool(json['online'] ?? json['is_online']) ?? false,
      enabled: asBool(json['child_lock_enabled'] ?? json['child_lock']) ?? false,
    );
  }
}

/// `GET /devices/child-lock/:homeId` yanıtı: `{ child_lock_enabled, requested, requested_at,
/// in_sync, devices[] }`.
///
/// * [enabled]: evin birleşik kilit durumu (köprünün cihaz bildirimlerinden eşitlediği değer).
/// * [requested] / [requestedAt]: kullanıcının en son **isteği** (sunucuda kayıtlı niyet); hiç istek
///   yoksa `null`. [requested] ile [enabled] farklıysa istek henüz cihazlara uygulanmamıştır
///   ([isApplying]; ör. pano çevrimdışı).
/// * [inSync]: çevrimiçi panoların bildirdiği değer [enabled] ile tutarlı mı.
class ChildLockInfo {
  const ChildLockInfo({
    required this.enabled,
    this.requested,
    this.requestedAt,
    this.inSync = true,
    this.devices = const <ChildLockDeviceInfo>[],
  });

  final bool enabled;
  final bool? requested;
  final DateTime? requestedAt;
  final bool inSync;
  final List<ChildLockDeviceInfo> devices;

  /// İstek kaydedilmiş ama bildirilen durumla eşleşmiyor: cihazlara uygulanması bekleniyor.
  bool get isApplying => requested != null && requested != enabled;

  /// Çevrimdışı panolar.
  List<String> get offlineDevices => <String>[
        for (final d in devices)
          if (!d.online) d.deviceUuid,
      ];

  /// `child_lock_enabled` yoksa `FormatException` (hata "kilitsiz" sanılmaz).
  factory ChildLockInfo.fromJson(Map<String, dynamic> json) {
    final enabled = asBool(json['child_lock_enabled'] ?? json['child_lock'] ?? json['enabled']);
    if (enabled == null) throw const FormatException('Çocuk kilidi durumu yok');
    return ChildLockInfo(
      enabled: enabled,
      requested: asBool(json['requested']),
      requestedAt: asDate(json['requested_at'] ?? json['requestedAt']),
      inSync: asBool(json['in_sync'] ?? json['inSync']) ?? true,
      devices: parseList(json['devices'], ChildLockDeviceInfo.fromJson, label: 'ChildLockDevice'),
    );
  }
}

/// `GET /homes/:homeId/devices` öğesi.
class DeviceInfo {
  const DeviceInfo({
    required this.deviceUuid,
    this.name = '',
    this.online = false,
    this.lastSeenAt,
    this.firmware = '',
  });

  /// `AHBU-...` cihaz kimliği.
  final String deviceUuid;
  final String name;
  final bool online;
  final DateTime? lastSeenAt;
  final String firmware;

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final uuid = asNonEmptyString(json['device_uuid'] ?? json['uid']);
    if (uuid == null) throw const FormatException('Cihaz kimliği yok');
    return DeviceInfo(
      deviceUuid: uuid,
      name: asString(json['name']) ?? '',
      online: asBool(json['online'] ?? json['is_online']) ?? false,
      lastSeenAt: asDate(json['last_seen_at']),
      firmware: asString(json['firmware'] ?? json['firmware_version'] ?? json['fw']) ?? '',
    );
  }
}

/// Devreye alma kontrolünün tek sonucu: `{ ok, detail }`.
class CommissionCheck {
  const CommissionCheck({required this.ok, this.detail = ''});

  final bool ok;
  final String detail;

  Map<String, dynamic> toJson() => <String, dynamic>{'ok': ok, 'detail': detail};
}

/// Devreye alma kontrolleri (CONTRACTS §1.5): `relays`, `buttons`, `shutters`, `network`,
/// `cloud`. **`tests_passed` sunucuda hesaplanır**; istemci göndermez.
class CommissioningChecks {
  const CommissioningChecks({
    required this.relays,
    required this.buttons,
    required this.shutters,
    required this.network,
    required this.cloud,
  });

  final CommissionCheck relays;
  final CommissionCheck buttons;
  final CommissionCheck shutters;
  final CommissionCheck network;
  final CommissionCheck cloud;

  /// Zorunlu 5 kontrolün hepsi başarılı mı (yalnızca arayüz özeti için; karar sunucuda).
  bool get allOk => relays.ok && buttons.ok && shutters.ok && network.ok && cloud.ok;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'relays': relays.toJson(),
        'buttons': buttons.toJson(),
        'shutters': shutters.toJson(),
        'network': network.toJson(),
        'cloud': cloud.toJson(),
      };
}

/// `POST /homes/:homeId/commissioning` yanıtı.
class CommissioningResult {
  const CommissioningResult({required this.testsPassed, this.status, this.raw = const {}});

  /// Sunucunun hesapladığı sonuç (zorunlu 5 kontrolün hepsi `ok`).
  final bool testsPassed;
  final String? status;
  final Map<String, dynamic> raw;

  factory CommissioningResult.fromJson(Map<String, dynamic> json) => CommissioningResult(
        testsPassed: asBool(json['tests_passed'] ?? json['testsPassed']) ?? false,
        status: asNonEmptyString(json['status'] ?? json['commissioning_status']),
        raw: json,
      );
}

/// Cihazın bulut (MQTT) kimliği: `{ host, port, username, password, client_id, topic_id }`.
///
/// Sunucu bunu **yalnızca tek seferlik** döndürür (`POST /devices/claim`, acil sıfırlama devri,
/// pano değişimi, `POST /homes/:id/devices/:uuid/mqtt-credential`). Parola **saklanmaz ve
/// loglanmaz**: kurulum sihirbazı bunu hemen panoya `AutomationApiService.configureMqtt` ile yazar.
/// [toString] parolayı ve konu kimliğini gizler.
class DeviceMqttCredential {
  const DeviceMqttCredential({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.topicId,
    this.clientId,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String topicId;
  final String? clientId;

  /// `{ host, port, mqtt_server, mqtt_port, username, password, client_id, topic_id }`: panonun
  /// `POST /api/mqtt/config`'e yazacağı sunucu **`mqtt_server` (DNS adı)**, port `mqtt_port`'tur;
  /// `host`/`port` geriye uyum için aynı değerlerdir (`mqtt_*` varsa onlar tercih edilir).
  factory DeviceMqttCredential.fromJson(Map<String, dynamic> json) {
    final host = asNonEmptyString(json['mqtt_server'] ?? json['host'] ?? json['server']);
    final port = asInt(json['mqtt_port'] ?? json['port']);
    final username = asNonEmptyString(json['username'] ?? json['user']);
    final password = asString(json['password'] ?? json['pass']);
    final topic = asNonEmptyString(json['topic_id'] ?? json['topicId']);
    if (host == null ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        username == null ||
        password == null ||
        password.isEmpty ||
        topic == null) {
      throw const FormatException('Geçersiz cihaz MQTT kimliği');
    }
    return DeviceMqttCredential(
      host: host,
      port: port,
      username: username,
      password: password,
      topicId: topic,
      clientId: asNonEmptyString(json['client_id'] ?? json['clientId']),
    );
  }

  /// Bozuk / eksik kimlikte `null` (istisna fırlatmaz).
  static DeviceMqttCredential? tryParse(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    try {
      return DeviceMqttCredential.fromJson(map);
    } on FormatException {
      return null;
    }
  }

  /// Panonun yerel `POST /api/mqtt/config` gövdesi: `{ server, port, user, pass }`.
  Map<String, dynamic> toLanConfigBody() => <String, dynamic>{
        'server': host,
        'port': port,
        'user': username,
        'pass': password,
      };

  @override
  String toString() => 'DeviceMqttCredential(host: $host, port: $port, password: ******)';
}

/// `POST /devices/claim` yanıtındaki müşteri hesabı bilgisi (servis personeli müşteri adına
/// eşlerken hesap yoksa açılır ve davet e-postası gider).
class CustomerAccountInfo {
  const CustomerAccountInfo({
    this.created = false,
    this.status,
    this.inviteSent = false,
  });

  final bool created;

  /// Ör. `pending_invite`.
  final String? status;
  final bool inviteSent;

  factory CustomerAccountInfo.fromJson(Map<String, dynamic> json) => CustomerAccountInfo(
        created: asBool(json['created']) ?? false,
        status: asNonEmptyString(json['status']),
        inviteSent: asBool(json['invite_sent'] ?? json['inviteSent']) ?? false,
      );
}

/// `POST /devices/claim` yanıtı: `{ home_id, home_name, device_uuid, device_credential?,
/// customer_account?, technician_access_expires_at?, warnings? }`.
class ClaimResult {
  const ClaimResult({
    required this.homeId,
    this.homeName = '',
    this.deviceUuid = '',
    this.deviceCredential,
    this.customerAccount,
    this.technicianAccessExpiresAt,
    this.warnings = const <String>[],
    this.raw = const {},
  });

  final String homeId;
  final String homeName;
  final String deviceUuid;

  /// Cihazın bulut kimliği (**tek seferlik**; bkz. [DeviceMqttCredential]). Yoksa `null`.
  final DeviceMqttCredential? deviceCredential;

  /// Müşteri adına eşleme yapıldıysa müşteri hesabı bilgisi.
  final CustomerAccountInfo? customerAccount;

  /// Servis personeline tanınan süreli kurulum erişiminin bitişi.
  final DateTime? technicianAccessExpiresAt;

  /// Kısmi başarı uyarıları (ör. davet e-postası gönderilemedi). Kullanıcıya gösterilmelidir.
  final List<String> warnings;

  /// Ham yanıt (**`device_credential` çıkarılmıştır**; parola bu haritada bulunmaz).
  final Map<String, dynamic> raw;

  factory ClaimResult.fromJson(Map<String, dynamic> json) {
    final home = asMap(json['home']);
    final homeId = asNonEmptyString(json['home_id'] ?? json['homeId'] ?? home?['id']);
    if (homeId == null) throw const FormatException('Ev kimliği yok');
    final customer = asMap(json['customer_account']);
    final safeRaw = Map<String, dynamic>.of(json)..remove('device_credential');
    return ClaimResult(
      homeId: homeId,
      homeName: asString(json['home_name'] ?? json['homeName'] ?? home?['name']) ?? '',
      deviceUuid: asString(json['device_uuid'] ?? json['deviceUuid']) ?? '',
      deviceCredential: DeviceMqttCredential.tryParse(json['device_credential']),
      customerAccount: customer == null ? null : CustomerAccountInfo.fromJson(customer),
      technicianAccessExpiresAt: asDate(json['technician_access_expires_at']),
      warnings: _asStringList(json['warnings']),
      raw: safeRaw,
    );
  }
}

List<String> _asStringList(Object? value) {
  final list = asList(value);
  if (list == null) return const <String>[];
  return <String>[
    for (final item in list)
      if (asNonEmptyString(item) != null) asNonEmptyString(item)!,
  ];
}

/// `POST /homes/join` yanıtı.
class JoinHomeResult {
  const JoinHomeResult({
    this.homeId,
    this.homeName = '',
    this.role,
    this.message = '',
    this.alreadyMember = false,
  });

  final String? homeId;
  final String homeName;
  final String? role;
  final String message;
  final bool alreadyMember;

  factory JoinHomeResult.fromJson(Map<String, dynamic> json) {
    final home = asMap(json['home']) ?? const <String, dynamic>{};
    return JoinHomeResult(
      homeId: asNonEmptyString(home['id'] ?? json['home_id']),
      homeName: asString(home['name'] ?? json['home_name']) ?? '',
      role: asNonEmptyString(home['role'] ?? json['role']),
      message: asString(json['message']) ?? '',
      alreadyMember: asBool(json['already_member'] ?? json['alreadyMember']) ?? false,
    );
  }
}

/// Daire devri başlatma yanıtı (`transfer-initiate`).
class TransferInfo {
  const TransferInfo({
    required this.code,
    this.qrPayload,
    this.expiresAt,
    this.targetIdentifier,
  });

  final String code;
  final String? qrPayload;
  final DateTime? expiresAt;
  final String? targetIdentifier;

  String get qrContent => qrPayload ?? 'AHBU-TRANSFER:$code';

  factory TransferInfo.fromJson(Map<String, dynamic> json) {
    final code = asNonEmptyString(
        json['transfer_code'] ?? json['transferCode'] ?? json['code']);
    if (code == null) throw const FormatException('Devir kodu yok');
    return TransferInfo(
      code: code,
      qrPayload: asNonEmptyString(json['qr_payload'] ?? json['qrPayload']),
      expiresAt: asDate(json['expires_at'] ?? json['expiresAt']),
      targetIdentifier:
          asNonEmptyString(json['target_identifier'] ?? json['targetIdentifier']),
    );
  }
}

/// Daire devri kabul yanıtı.
class TransferAcceptResult {
  const TransferAcceptResult({this.homeId, this.homeName = '', this.message = ''});

  final String? homeId;
  final String homeName;
  final String message;

  factory TransferAcceptResult.fromJson(Map<String, dynamic> json) {
    final home = asMap(json['home']) ?? const <String, dynamic>{};
    return TransferAcceptResult(
      homeId: asNonEmptyString(home['id'] ?? json['home_id']),
      homeName: asString(home['name'] ?? json['home_name']) ?? '',
      message: asString(json['message']) ?? '',
    );
  }
}

/// Servis PIN oturumu (`POST /auth/service-login`): tek eve kapsamlı, 2 saat, **refresh yok**.
class ServiceSessionInfo {
  const ServiceSessionInfo({
    required this.homeId,
    required this.homeName,
    required this.expiresAt,
    this.technicianName = '',
  });

  final String homeId;
  final String homeName;
  final DateTime expiresAt;
  final String technicianName;

  Duration remaining(DateTime now) {
    final left = expiresAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'home_id': homeId,
        'home_name': homeName,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'technician_name': technicianName,
      };

  factory ServiceSessionInfo.fromJson(Map<String, dynamic> json) {
    final homeId = asNonEmptyString(json['home_id']);
    final expires = asDate(json['expires_at']);
    if (homeId == null || expires == null) throw const FormatException('Servis oturumu bozuk');
    return ServiceSessionInfo(
      homeId: homeId,
      homeName: asString(json['home_name']) ?? '',
      expiresAt: expires,
      technicianName: asString(json['technician_name']) ?? '',
    );
  }
}

/// Kod isteme yanıtı (`POST /auth/otp/send`, `POST /auth/forgot-password`).
///
/// Arayüz [resendAfter] dolmadan "Yeniden gönder"i kapalı tutar; [expiresIn] kodun geçerlilik
/// süresidir. Geliştirme sunucusu (`ALLOW_DEBUG_OTP`) kodu yanıtta döndürebilir: [debugCode] /
/// [debugToken] **release derlemede asla dolmaz** ve [toString]'e yazılmaz.
class CodeChallenge {
  const CodeChallenge({
    this.message = '',
    this.expiresIn,
    this.resendAfter = defaultResendAfter,
    this.debugCode,
    this.debugToken,
  });

  /// Sunucu süre vermezse varsayılan yeniden gönderim bekleme süresi (CONTRACTS: 60 sn).
  static const Duration defaultResendAfter = Duration(seconds: 60);

  final String message;

  /// Kodun geçerlilik süresi (bilinmiyorsa `null`).
  final Duration? expiresIn;

  /// Yeni kod istemeden önce beklenmesi gereken süre.
  final Duration resendAfter;

  /// Yalnızca geliştirme/QA sunucusu ve release dışı derleme (aksi halde `null`).
  final String? debugCode;
  final String? debugToken;

  factory CodeChallenge.fromJson(Map<String, dynamic> json, {bool releaseMode = kReleaseMode}) {
    final expires = asInt(json['expires_in'] ?? json['expiresIn']);
    final resend = asInt(json['resend_after'] ?? json['resendAfter']);
    return CodeChallenge(
      message: asString(json['message']) ?? '',
      expiresIn: (expires != null && expires > 0) ? Duration(seconds: expires) : null,
      resendAfter: (resend != null && resend > 0) ? Duration(seconds: resend) : defaultResendAfter,
      debugCode: releaseMode ? null : asNonEmptyString(json['debug_code']),
      debugToken: releaseMode ? null : asNonEmptyString(json['debug_token']),
    );
  }

  @override
  String toString() => 'CodeChallenge(expiresIn: $expiresIn, resendAfter: $resendAfter)';
}

/// `GET /homes/:homeId/service-tokens` öğesi (ev sahibi için PIN geçmişi). **PIN değeri dönmez**
/// (sunucu yalnızca özetini saklar; PIN üretim anında bir kez gösterilir).
class ServiceTokenSummary {
  const ServiceTokenSummary({
    required this.id,
    required this.status,
    this.expiresAt,
    this.usedAt,
    this.revokedAt,
    this.createdAt,
    this.createdByName,
  });

  final String id;

  /// `active` | `used` | `expired` | `revoked`.
  final String status;
  final DateTime? expiresAt;
  final DateTime? usedAt;
  final DateTime? revokedAt;
  final DateTime? createdAt;
  final String? createdByName;

  bool get isActive => status == 'active';

  factory ServiceTokenSummary.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id']);
    if (id == null) throw const FormatException('Servis PIN kaydı kimliği yok');
    final usedAt = asDate(json['used_at']);
    final revokedAt = asDate(json['revoked_at']);
    var status = asNonEmptyString(json['status'])?.toLowerCase();
    status ??= revokedAt != null
        ? 'revoked'
        : (usedAt != null || (asBool(json['is_used']) ?? false))
            ? 'used'
            : 'active';
    return ServiceTokenSummary(
      id: id,
      status: status,
      expiresAt: asDate(json['expires_at']),
      usedAt: usedAt,
      revokedAt: revokedAt,
      createdAt: asDate(json['created_at']),
      createdByName: asNonEmptyString(json['created_by_name']),
    );
  }
}

/// `GET /homes/:homeId/service-sessions` öğesi: evde açık servis (PIN) oturumu.
class ServiceSessionSummary {
  const ServiceSessionSummary({
    required this.id,
    this.technicianName = '',
    this.createdAt,
    this.expiresAt,
  });

  final String id;
  final String technicianName;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  factory ServiceSessionSummary.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id']);
    if (id == null) throw const FormatException('Servis oturumu kimliği yok');
    return ServiceSessionSummary(
      id: id,
      technicianName: asString(json['technician_name'] ?? json['technicianName']) ?? '',
      createdAt: asDate(json['created_at']),
      expiresAt: asDate(json['expires_at']),
    );
  }
}

/// `POST /homes/:homeId/service-access/revoke` yanıtı.
class RevokeServiceAccessResult {
  const RevokeServiceAccessResult({this.revokedPins = 0, this.revokedSessions = 0});

  final int revokedPins;
  final int revokedSessions;

  factory RevokeServiceAccessResult.fromJson(Map<String, dynamic> json) => RevokeServiceAccessResult(
        revokedPins: asInt(json['revoked_pins']) ?? 0,
        revokedSessions: asInt(json['revoked_sessions']) ?? 0,
      );
}

/// Gece (huzur) bildirimi ayarı ve açık cihaz özeti (`GET /devices/peace-notification/:homeId`).
///
/// Sunucu hem uzun (`peace_notification_enabled/_time`) hem kısa (`enabled/time`) anahtarları
/// kullanabilir; bu model ikisini de okur (arayüzün yanlış anahtar okuması hatasını önler).
class PeaceNotificationSettings {
  const PeaceNotificationSettings({
    this.enabled,
    this.time,
    this.timezone,
    this.openLightsCount,
    this.openShuttersCount,
    this.summaryText = '',
    this.raw = const <String, dynamic>{},
    this.stale,
    this.devicesTotal,
    this.devicesOnline,
    this.openShutters,
    this.lastNotice,
  });

  /// Bildirim açık mı (`null` = sunucu söylemedi).
  final bool? enabled;

  /// `SS:DD` (24 saat) yerel gece saati; yoksa `null`.
  final String? time;
  final String? timezone;
  final int? openLightsCount;
  final int? openShuttersCount;
  final String summaryText;

  /// Ham yanıt (v2 alanları: `last_notice`, `devices_online`, `stale` ... buradan okunur).
  final Map<String, dynamic> raw;

  /// v2: canlı cihaz yok, sayılar bilinmiyor (`true` iken "hepsi kapalı" DENMEZ). `null` = v1 sunucu.
  final bool? stale;

  /// v2: evdeki / canlı (çevrimiçi) cihaz sayıları; yoksa `null`.
  final int? devicesTotal;
  final int? devicesOnline;

  /// v2: açık panjur çifti sayısı (`open_shutters` liste ya da sayı gelebilir; yoksa `open_shutters_count`).
  final int? openShutters;

  /// v2: en yeni gece bildirim kaydı (yoksa `null`).
  final PeaceLastNotice? lastNotice;

  static final RegExp _timePattern = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$');

  factory PeaceNotificationSettings.fromJson(Map<String, dynamic> json) {
    final settings = asMap(json['settings']);
    String? pickTime() {
      final value = asNonEmptyString(json['time'] ??
          json['notification_time'] ??
          json['peace_notification_time'] ??
          settings?['peace_notification_time']);
      if (value == null) return null;
      // `23:30:00` -> `23:30`
      final match = _timePattern.firstMatch(value);
      if (match == null) return value;
      return '${match.group(1)!.padLeft(2, '0')}:${match.group(2)}';
    }

    return PeaceNotificationSettings(
      enabled: asBool(json['enabled'] ??
          json['peace_notification_enabled'] ??
          settings?['peace_notification_enabled']),
      time: pickTime(),
      timezone: asNonEmptyString(json['timezone']),
      openLightsCount: asInt(json['open_lights_count'] ?? json['openLightsCount']),
      openShuttersCount: asInt(json['open_shutters_count'] ?? json['openShuttersCount']),
      summaryText: asString(json['summary_text'] ?? json['summary']) ?? '',
      raw: json,
      stale: asBool(json['stale']),
      devicesTotal: asInt(json['devices_total']),
      devicesOnline: asInt(json['devices_online']),
      openShutters: _openShutters(json),
      lastNotice: _lastNotice(json['last_notice']),
    );
  }

  /// `open_shutters`: v2 sunucuda panjur listesi, bazı yanıtlarda sayı; yoksa `open_shutters_count`.
  static int? _openShutters(Map<String, dynamic> json) {
    final raw = json['open_shutters'];
    if (raw is List) return raw.length;
    return asInt(raw) ?? asInt(json['open_shutters_count'] ?? json['openShuttersCount']);
  }

  static PeaceLastNotice? _lastNotice(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    try {
      return PeaceLastNotice.fromJson(map);
    } catch (_) {
      // Bozuk `last_notice` ayar ekranını düşürmez; yok sayılır.
      return null;
    }
  }
}

/// `GET /devices/peace-notification/:home_id` yanıtındaki `last_notice` (en yeni gece bildirim kaydı).
/// Yalnızca `sent` | `no_recipients` | `resolved` durumları görünür.
class PeaceLastNotice {
  const PeaceLastNotice({
    required this.id,
    this.localDate,
    this.status,
    this.summaryText = '',
    this.openLightsCount,
    this.openShuttersCount,
    this.createdAt,
    this.resolvedAt,
  });

  /// `peace_notification_logs.id` (CONTRACTS: kimliklerin tek istisnası, tam sayı).
  final int id;

  /// Yerel gece tarihi (`YYYY-MM-DD`).
  final String? localDate;
  final String? status;
  final String summaryText;
  final int? openLightsCount;
  final int? openShuttersCount;
  final DateTime? createdAt;

  /// Kullanıcı kapattıysa (ya da "Hepsini kapat" çözdüyse) dolu.
  final DateTime? resolvedAt;

  bool get isResolved => resolvedAt != null || status == 'resolved';

  factory PeaceLastNotice.fromJson(Map<String, dynamic> json) {
    final id = asInt(json['id']);
    if (id == null) throw const FormatException('Bildirim kimliği yok');
    return PeaceLastNotice(
      id: id,
      localDate: asNonEmptyString(json['local_date']),
      status: asNonEmptyString(json['status']),
      summaryText: asString(json['summary_text']) ?? '',
      openLightsCount: asInt(json['open_lights_count']),
      openShuttersCount: asInt(json['open_shutters_count']),
      createdAt: asDate(json['created_at']),
      resolvedAt: asDate(json['resolved_at']),
    );
  }
}

/// `POST /devices/peace-notification/close-all` yanıtı.
class CloseAllResult {
  const CloseAllResult({
    this.closedCount,
    this.delivered = true,
    this.deviceOnline,
    this.commandId,
    this.message = '',
    this.closedShutters,
    this.skippedCount = 0,
    this.nothingToDo = false,
    this.resolved = false,
    this.noticeId,
  });

  /// Kapatılması hedeflenen **gerçek** açık lamba sayısı (sunucu sayar; bilinmiyorsa `null`).
  final int? closedCount;

  /// Komut cihaza iletildi (uygulandığı `state` bildirimiyle doğrulanır).
  final bool delivered;
  final bool? deviceOnline;
  final String? commandId;
  final String message;

  /// v2: indirilmesi hedeflenen açık panjur çifti sayısı (v1 sunucuda `null`).
  final int? closedShutters;

  /// v2: çok panolu evde ortak kanal numarası yüzünden güvenle kapatılamayanlar; `> 0` ise
  /// [message] elle kontrolü söyler ve bildirim çözülmez.
  final int skippedCount;

  /// v2: sunucu kayıtlarına göre kapatılacak şey YOKTU, cihaza komut gitmedi: "kapatıldı" denmemeli.
  final bool nothingToDo;

  /// v2: bildirim kaydı çözüldü.
  final bool resolved;

  /// v2: çözülen/ilgili bildirim kaydı (`peace_notification_logs.id`).
  final int? noticeId;

  factory CloseAllResult.fromJson(Map<String, dynamic> json) => CloseAllResult(
        closedCount: asInt(json['closed_count'] ?? json['closed'] ?? json['count']),
        delivered: asBool(json['delivered']) ?? true,
        deviceOnline: asBool(json['device_online'] ?? json['deviceOnline']),
        commandId: asNonEmptyString(json['command_id'] ?? json['commandId']),
        message: asString(json['message']) ?? '',
        closedShutters: asInt(json['closed_shutters']),
        skippedCount: asInt(json['skipped_count']) ?? 0,
        nothingToDo: asBool(json['nothing_to_do']) ?? false,
        resolved: asBool(json['resolved']) ?? false,
        noticeId: asInt(json['notice_id']),
      );
}

/// Acil sıfırlamada cihazın devredildiği yeni sahip (`new_owner`).
class ResetNewOwner {
  const ResetNewOwner({required this.id, this.fullName = ''});

  final String id;
  final String fullName;

  factory ResetNewOwner.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id'] ?? json['user_id']);
    if (id == null) throw const FormatException('Yeni sahip kimliği yok');
    return ResetNewOwner(id: id, fullName: asString(json['full_name'] ?? json['fullName']) ?? '');
  }
}

/// `POST /devices/emergency-reset` yanıtı (CONTRACTS §1.5b).
///
/// * [isUnclaimed] (`UNCLAIMED`): cihaz stoğa alındı; [setupPin] **tek seferlik** yeni kurulum PIN'i.
/// * [isReassigned] (`REASSIGNED`): cihaz [newOwner]'a devredildi; [deviceCredential] **tek seferlik**
///   yeni bulut kimliği (servis sihirbazı panoya `AutomationApiService.configureMqtt` ile yazar).
/// * [localKeyPublish]: `published | pending | skipped`. `pending` ([localKeyPending]): pano çevrimdışı ya da sunucunun
///   bulut (broker) bağlantısı yok; yeni yerel anahtar pano buluta bağlanınca sunucu tarafından **otomatik** iletilir,
///   o zamana kadar panonun mevcut anahtarı geçerlidir (sunucunun verdiği anahtar odur; "Panoyu şimdi bağla"
///   sihirbazı 6. adımda onunla çalışır). Bu durumda yanıtta `local_key` YOKTUR. Eski sunucular `failed |
///   skipped_offline` + [localKey] dönebilir.
/// * [childLockReset]: `published | failed | skipped_offline | skipped`.
/// * [localKey]: yalnızca ESKİ sunucu yanıtında (anahtar panoya iletilemedi) **tek seferlik** döner. Ağ üzerinden
///   panoya yazılamaz: seri konsolda `RESETKEY` + `FACTORYINIT` (fabrika aracı) ile yazılır ([needsManualLocalKey]).
/// * Kısmi başarısızlıkta **HTTP 200 + [warnings] + [partial]=true**: arayüz uyarıları göstermelidir.
///
/// Gizli değerler ([setupPin], [localKey], [deviceCredential]) `toString`'e yazılmaz; saklanmamalıdır.
class EmergencyResetResult {
  const EmergencyResetResult({
    required this.action,
    this.deviceUuid = '',
    this.homeId,
    this.affectedUsersCount = 0,
    this.setupPin,
    this.newOwner,
    this.deviceCredential,
    this.localKeyPublish,
    this.childLockReset,
    this.localKey,
    this.message = '',
    this.warnings = const <String>[],
    this.partial = false,
  });

  /// `UNCLAIMED` | `REASSIGNED` (büyük harf; bilinmeyen değer olduğu gibi).
  final String action;
  final String deviceUuid;
  final String? homeId;
  final int affectedUsersCount;
  final String? setupPin;
  final ResetNewOwner? newOwner;
  final DeviceMqttCredential? deviceCredential;
  final String? localKeyPublish;
  final String? childLockReset;
  final String? localKey;
  final String message;
  final List<String> warnings;
  final bool partial;

  bool get isUnclaimed => action == 'UNCLAIMED';
  bool get isReassigned => action == 'REASSIGNED';

  /// Uyarı var (kısmi başarı) — kullanıcıya gösterilmelidir. Yalnız bekleyen anahtar uyarı SAYILMAZ (bkz. [isPartial]).
  bool get hasWarnings => isPartial || displayWarnings.isNotEmpty;

  /// Kullanıcıya uyarı satırı olarak gösterilecek uyarılar. Anahtar bekliyorsa ([localKeyPending]) yerel anahtarla
  /// ilgili bilgi ayrı bir bilgi notunda verilir: ESKİ sunucunun `warnings` içine koyduğu bekleyen anahtar uyarısı
  /// burada tekrar edilmez (aynı bilgi biri hata tonunda iki kez görünmesin). Bekleyen durumda sunucunun yerel
  /// anahtarla ilgili ürettiği tek uyarı budur (iletilemeyen anahtar uyarısı yalnız `failed` iken gelir).
  List<String> get displayWarnings =>
      localKeyPending ? warnings.where((w) => !_localKeyWarning.hasMatch(w)).toList(growable: false) : warnings;

  /// Kısmi başarı. Yeni sunucu bekleyen anahtar için `partial` döndürmez; ESKİ sunucu döndürür: uyarılarının
  /// TAMAMI bekleyen anahtar bilgisiyse (hepsi [displayWarnings]'ten süzüldüyse) sıfırlama kısmi sayılmaz.
  bool get isPartial => partial && (warnings.isEmpty || displayWarnings.isNotEmpty);

  static final RegExp _localKeyWarning = RegExp('yerel anahtar', caseSensitive: false);

  /// Eski sunucu yanıtı: yerel anahtar cihaza **iletilmedi** ve [localKey] döndü; seri konsolda `RESETKEY` +
  /// `FACTORYINIT` (fabrika aracı) ile yazılmalıdır. Anahtar bekliyorsa ([localKeyPending]) sunucu onu kendisi
  /// iletir: elle yazılacak anahtar yoktur (yanıtta yine de gelmişse gösterilmez).
  bool get needsManualLocalKey => localKey != null && !localKeyPending;

  /// Yeni yerel anahtar panoya henüz iletilmedi; pano buluta bağlanınca sunucu otomatik iletecek (`pending`).
  bool get localKeyPending => localKeyPublish == 'pending';

  factory EmergencyResetResult.fromJson(Map<String, dynamic> json) {
    final owner = asMap(json['new_owner']);
    ResetNewOwner? newOwner;
    if (owner != null) {
      try {
        newOwner = ResetNewOwner.fromJson(owner);
      } on FormatException {
        newOwner = null;
      }
    }
    return EmergencyResetResult(
      action: asNonEmptyString(json['action'])?.toUpperCase() ?? '',
      deviceUuid: asString(json['device_uuid'] ?? json['deviceUuid']) ?? '',
      homeId: asNonEmptyString(json['home_id'] ?? json['homeId']),
      affectedUsersCount: asInt(json['affected_users_count']) ?? 0,
      setupPin: asNonEmptyString(json['setup_pin']),
      newOwner: newOwner,
      deviceCredential: DeviceMqttCredential.tryParse(json['device_credential']),
      localKeyPublish: asNonEmptyString(json['local_key_publish']),
      childLockReset: asNonEmptyString(json['child_lock_reset']),
      localKey: asNonEmptyString(json['local_key']),
      message: asString(json['message']) ?? '',
      warnings: _asStringList(json['warnings']),
      partial: asBool(json['partial']) ?? false,
    );
  }

  @override
  String toString() => 'EmergencyResetResult(action: $action, device: $deviceUuid, '
      'partial: $partial, secrets: ******)';
}

/// Pano değişiminde yeni panoya `set_runtime` ile aktarılacak panjur süresi.
class ShutterRuntimeSync {
  const ShutterRuntimeSync({required this.shutter, required this.seconds});

  /// 1 tabanlı panjur numarası.
  final int shutter;
  final int seconds;

  factory ShutterRuntimeSync.fromJson(Map<String, dynamic> json) {
    final shutter = asInt(json['shutter'] ?? json['pair']);
    final sec = asInt(json['sec'] ?? json['seconds'] ?? json['shutter_duration_sec']);
    if (shutter == null || shutter < 1 || sec == null || sec < 1 || sec > 300) {
      throw const FormatException('Geçersiz panjur süresi');
    }
    return ShutterRuntimeSync(shutter: shutter, seconds: sec);
  }
}

/// `POST /devices/replace-board` yanıtı (CONTRACTS §1.5b).
///
/// [deviceCredential] **tek seferlik** yeni pano kimliğidir (servis sihirbazı yeni panoya
/// `AutomationApiService.configureMqtt` ile yazar; saklanmaz). Yeni pano henüz çevrimdışı olduğundan
/// panjur süreleri ([runtimeSync]) ve çocuk kilidi ([childLockSync]) **pano çevrimiçi olunca**
/// uygulanır (`pending_device_online`).
class ReplaceBoardResult {
  const ReplaceBoardResult({
    this.message = '',
    this.oldDeviceUuid,
    required this.newDeviceUuid,
    this.migratedEndpointsCount = 0,
    this.homeId,
    this.deviceCredential,
    this.shutterRuntimes = const <ShutterRuntimeSync>[],
    this.runtimeSync,
    this.childLockEnabled,
    this.childLockSync,
    this.warnings = const <String>[],
    this.partial = false,
  });

  final String message;
  final String? oldDeviceUuid;
  final String newDeviceUuid;

  /// Yeni panoya taşınan kanal (uç nokta) sayısı.
  final int migratedEndpointsCount;
  final String? homeId;
  final DeviceMqttCredential? deviceCredential;
  final List<ShutterRuntimeSync> shutterRuntimes;

  /// Ör. `pending_device_online`.
  final String? runtimeSync;

  /// Değişimden önceki çocuk kilidi ve uygulanma durumu (`pending_device_online` | `not_required`).
  final bool? childLockEnabled;
  final String? childLockSync;
  final List<String> warnings;
  final bool partial;

  bool get hasWarnings => partial || warnings.isNotEmpty;

  /// Çocuk kilidi yeni pano çevrimiçi olunca yeniden uygulanacak mı.
  bool get childLockPending => childLockSync == 'pending_device_online';

  factory ReplaceBoardResult.fromJson(Map<String, dynamic> json) {
    final newUuid = asNonEmptyString(json['new_device_uuid'] ?? json['newDeviceUuid']);
    if (newUuid == null) throw const FormatException('Yeni pano kimliği yok');
    final lock = asMap(json['child_lock']);
    return ReplaceBoardResult(
      message: asString(json['message']) ?? '',
      oldDeviceUuid: asNonEmptyString(json['old_device_uuid'] ?? json['oldDeviceUuid']),
      newDeviceUuid: newUuid,
      migratedEndpointsCount:
          asInt(json['migrated_endpoints_count'] ?? json['migratedEndpointsCount']) ?? 0,
      homeId: asNonEmptyString(json['home_id'] ?? json['homeId']),
      deviceCredential: DeviceMqttCredential.tryParse(json['device_credential']),
      shutterRuntimes: parseList(json['shutter_runtimes'], ShutterRuntimeSync.fromJson, label: 'ShutterRuntime'),
      runtimeSync: asNonEmptyString(json['runtime_sync']),
      childLockEnabled: asBool(lock?['enabled']),
      childLockSync: asNonEmptyString(lock?['sync']),
      warnings: _asStringList(json['warnings']),
      partial: asBool(json['partial']) ?? false,
    );
  }

  @override
  String toString() => 'ReplaceBoardResult(new: $newDeviceUuid, migrated: $migratedEndpointsCount, '
      'warnings: ${warnings.length}, secrets: ******)';
}
