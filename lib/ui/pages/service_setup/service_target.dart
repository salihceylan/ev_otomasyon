import 'package:flutter/foundation.dart';

import '../../../services/automation_state.dart';

/// Kurulumun **hedefi**: sihirbazın claim sonrasındaki HER adımı yalnızca bu eve ve bu cihaza işlem
/// yapar. Claim edilen ev aktif ev (`AutomationState.activeHome`) değildir; yanlış ev/cihaz
/// karışmasın diye hiçbir adım aktif evi okumaz.
///
/// [localKey] yalnızca **bellekte** tutulur: ne ilerleme kaydına, ne güvenli depoya (sihirbaz anahtarı
/// `AutomationState.localKeyFor` ile DEĞİL, saklamayan okumayla alır), ne loga ne de rapora yazılır
/// ([toString] gizler).
@immutable
class ServiceTarget {
  const ServiceTarget({
    required this.homeId,
    required this.deviceUuid,
    this.homeName = '',
    this.ip = '',
    this.localKey,
  });

  /// Dairenin UUID'si (sunucu).
  final String homeId;

  /// Cihaz kimliği (`AHBU-...`).
  final String deviceUuid;

  /// Dairenin adı (kullanıcıya gösterim için).
  final String homeName;

  /// Panonun şu an erişilen yerel adresi: kurulum ağı (AP) adresi ya da ev ağındaki IP.
  final String ip;

  /// Panonun yerel anahtarı (`X-Device-Key`); **hiçbir kalıcı depoya (güvenli depo dahil) yazılmaz**.
  /// Pano anahtarı reddederse hedeften silinir (aynı anahtar yeniden gönderilmez).
  final String? localKey;

  ServiceTarget copyWith({
    String? homeName,
    String? ip,
    String? localKey,
    bool clearLocalKey = false,
  }) =>
      ServiceTarget(
        homeId: homeId,
        deviceUuid: deviceUuid,
        homeName: homeName ?? this.homeName,
        ip: ip ?? this.ip,
        localKey: clearLocalKey ? null : (localKey ?? this.localKey),
      );

  @override
  bool operator ==(Object other) =>
      other is ServiceTarget &&
      other.homeId == homeId &&
      other.deviceUuid == deviceUuid &&
      other.homeName == homeName &&
      other.ip == ip &&
      other.localKey == localKey;

  @override
  int get hashCode => Object.hash(homeId, deviceUuid, homeName, ip, localKey);

  @override
  String toString() =>
      'ServiceTarget(home: $homeId, device: $deviceUuid, ip: $ip, key: ${localKey == null ? '-' : '******'})';
}

/// Sihirbazı kimin çalıştırdığı.
enum SetupMode {
  /// Kalıcı servis personeli (veya süper yönetici): cihazı müşteriye bağlayabilir (claim).
  staff,

  /// Ev sahibinin verdiği 2 saatlik geçici servis PIN oturumu: yalnızca o evde, **claim yok**.
  pinSession,
}

/// Oturumun sihirbaz için özeti: kim, hangi yetkiyle, ne kadar süre.
@immutable
class ServiceSetupAccess {
  const ServiceSetupAccess({
    required this.mode,
    required this.ownerKey,
    required this.technicianName,
    this.isSuperUser = false,
    this.sessionHomeId,
    this.sessionHomeName,
    this.sessionExpiresAt,
  });

  final SetupMode mode;

  /// Kayıtlı ilerlemenin sahibi: `user:<id>` ya da `session:<evId>`. Başka teknisyenin/oturumun
  /// kaydı görünmez.
  final String ownerKey;
  final String technicianName;
  final bool isSuperUser;

  /// Yalnızca PIN oturumunda: oturumun tek evi ve bitiş zamanı.
  final String? sessionHomeId;
  final String? sessionHomeName;
  final DateTime? sessionExpiresAt;

  bool get isPinSession => mode == SetupMode.pinSession;

  /// Cihazı müşteriye bağlama (claim) yalnızca kalıcı personel / süper kullanıcıdadır.
  bool get canClaim => mode == SetupMode.staff;

  /// Oturumdan çıkarılır; sihirbaz yetkisi yoksa `null`.
  static ServiceSetupAccess? fromState(AutomationState state) {
    if (!state.isAuthenticated) return null;
    final session = state.serviceSession;
    final user = state.currentUser;
    if (state.isServiceSession) {
      final home = state.activeHome;
      final homeId = session?.homeId ?? home?.id;
      if (homeId == null || homeId.isEmpty) return null;
      final name = (user?.fullName.isNotEmpty ?? false)
          ? user!.fullName
          : ((session?.technicianName.isNotEmpty ?? false) ? session!.technicianName : 'Servis Teknisyeni');
      return ServiceSetupAccess(
        mode: SetupMode.pinSession,
        ownerKey: 'session:$homeId',
        technicianName: name,
        sessionHomeId: homeId,
        sessionHomeName: session?.homeName ?? home?.name,
        sessionExpiresAt: session?.expiresAt,
      );
    }
    if (user == null) return null;
    if (state.isServiceUser || state.isSuperUser) {
      return ServiceSetupAccess(
        mode: SetupMode.staff,
        ownerKey: 'user:${user.id}',
        technicianName: user.fullName,
        isSuperUser: state.isSuperUser,
      );
    }
    return null;
  }
}
