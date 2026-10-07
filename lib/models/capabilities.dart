import 'package:flutter/foundation.dart';

/// Küresel (hesap) rolü: JWT `role` talebi / `users.role`.
enum GlobalRole {
  /// Müşteri hesabı (ev sahibi / sakin / misafir olabilir; yetkisi ev rolünden gelir).
  user,

  /// Kalıcı servis personeli (yalnızca `home_users` kaydı olan evlerde yetkili).
  serviceUser,

  /// Süper kullanıcı (yönetici).
  superUser,

  /// 2 saatlik servis PIN oturumu (tek eve kapsamlı; kullanıcı satırı yok).
  serviceSession,

  /// Tanınmayan rol: **hiçbir yetki** verilmez (beyaz liste).
  unknown;

  /// Sunucudaki / JWT'deki dizgiyi normalleştirir (büyük-küçük harf, boşluk, eski adlar).
  static GlobalRole parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'user':
        return GlobalRole.user;
      case 'service_user':
      case 'installer': // 016 ile kaldırılan eski ad
        return GlobalRole.serviceUser;
      case 'super_user':
        return GlobalRole.superUser;
      case 'service_session':
        return GlobalRole.serviceSession;
    }
    return GlobalRole.unknown;
  }

  /// Sunucu sözleşmesindeki dizgi.
  String get wire {
    switch (this) {
      case GlobalRole.user:
        return 'user';
      case GlobalRole.serviceUser:
        return 'service_user';
      case GlobalRole.superUser:
        return 'super_user';
      case GlobalRole.serviceSession:
        return 'service_session';
      case GlobalRole.unknown:
        return 'unknown';
    }
  }
}

/// Ev bazlı rol: `home_users.role` (`GET /homes` -> `role`).
enum HomeRole {
  owner,
  resident,
  guest,

  /// Evde kayıtlı kalıcı servis personeli.
  serviceUser,

  /// Servis PIN oturumunun tek evi.
  serviceSession,

  /// Tanınmayan rol: **hiçbir yetki** verilmez.
  unknown;

  static HomeRole parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'owner':
        return HomeRole.owner;
      case 'resident':
      case 'member': // eski ad (A9: `resident`)
        return HomeRole.resident;
      case 'guest':
        return HomeRole.guest;
      case 'service_user':
      case 'installer': // eski ad
        return HomeRole.serviceUser;
      case 'service_session':
        return HomeRole.serviceSession;
    }
    return HomeRole.unknown;
  }

  /// Sunucu sözleşmesindeki dizgi.
  String get wire {
    switch (this) {
      case HomeRole.owner:
        return 'owner';
      case HomeRole.resident:
        return 'resident';
      case HomeRole.guest:
        return 'guest';
      case HomeRole.serviceUser:
        return 'service_user';
      case HomeRole.serviceSession:
        return 'service_session';
      case HomeRole.unknown:
        return 'unknown';
    }
  }
}

/// Rol -> yetki eşlemesi (CONTRACTS §1.4 matrisinin istemci yansıması).
///
/// **UI gizleme tek başına yetki değildir; sunucu esastır.** Bu sınıf (a) arayüz kapılarını
/// tek yerden besler ve (b) `AutomationState` metotlarında savunmacı denetim yapar.
///
/// Beyaz liste mantığı: bilinmeyen / eksik rol = **hiçbir yetki**. Süresi dolmuş (veya henüz
/// başlamamış) misafir, tüm ev yetkilerini kaybeder ([isGuestExpired]).
@immutable
class Capabilities {
  /// [globalRole]: oturum açmış kullanıcının küresel rolü (`null` = oturum yok).
  /// [homeRole]: aktif evdeki rol (`activeHome.role`; `null` = aktif ev/üyelik yok).
  /// [guestValidUntil] / [guestValidFrom]: misafir penceresi (yalnızca `guest` için anlamlı).
  /// [hasActiveHome]: aktif ev var mı (varsayılan: [homeRole] verilmişse true). Süper
  /// kullanıcı evin üyesi olmadan da (açık istisna) ev bağlamında işlem yapabilir.
  factory Capabilities({
    String? globalRole,
    String? homeRole,
    DateTime? guestValidUntil,
    DateTime? guestValidFrom,
    DateTime? now,
    bool? hasActiveHome,
  }) {
    final authenticated = globalRole != null && globalRole.trim().isNotEmpty;
    final g = authenticated ? GlobalRole.parse(globalRole) : null;
    final h = (homeRole == null || homeRole.trim().isEmpty) ? null : HomeRole.parse(homeRole);
    return Capabilities._compute(
      authenticated: authenticated,
      g: g,
      h: h,
      guestValidUntil: guestValidUntil,
      guestValidFrom: guestValidFrom,
      now: now ?? DateTime.now(),
      hasActiveHome: hasActiveHome ?? (h != null),
    );
  }

  /// Oturumsuz / yetkisiz durum: hiçbir yetki yok.
  const Capabilities.none()
      : isAuthenticated = false,
        isSuperUser = false,
        isStaff = false,
        isServiceSession = false,
        isOwner = false,
        isResident = false,
        isGuest = false,
        isGuestExpired = false,
        hasHomeAccess = false,
        canViewState = false,
        canControlDevices = false,
        canUseGroupCommands = false,
        canChangeChildLock = false,
        canCalibrate = false,
        canManageRules = false,
        canInvite = false,
        canManageMembers = false,
        canTransferOwnership = false,
        canGenerateServicePin = false,
        canClaimDevice = false,
        canCommission = false,
        canReplaceBoard = false,
        canEmergencyReset = false,
        canOpenWifiRecovery = false,
        canEditDeviceHost = false,
        canSwitchMode = false,
        canFetchLocalKey = false,
        canReissueDeviceCredential = false,
        canViewInventory = false,
        canManageInventory = false,
        canOpenServiceManagement = false,
        canManageAdminAccounts = false,
        canCloseActuators = false,
        canAckAlarm = false,
        canControlActuators = false,
        canTestSafety = false;

  /// Oturumsuz **yerel mod** + elle girilmiş/saklı cihaz anahtarı: yalnızca durum görme ve
  /// cihaz komutu (anahtar sahibi yerel ağda cihazı kullanabilir). Başka hiçbir yetki yoktur.
  const Capabilities.localKeyHolder()
      : isAuthenticated = false,
        isSuperUser = false,
        isStaff = false,
        isServiceSession = false,
        isOwner = false,
        isResident = false,
        isGuest = false,
        isGuestExpired = false,
        hasHomeAccess = false,
        canViewState = true,
        canControlDevices = true,
        canUseGroupCommands = true,
        canChangeChildLock = true,
        canCalibrate = false,
        canManageRules = false,
        canInvite = false,
        canManageMembers = false,
        canTransferOwnership = false,
        canGenerateServicePin = false,
        canClaimDevice = false,
        canCommission = false,
        canReplaceBoard = false,
        canEmergencyReset = false,
        canOpenWifiRecovery = false,
        canEditDeviceHost = true,
        canSwitchMode = true,
        canFetchLocalKey = false,
        canReissueDeviceCredential = false,
        canViewInventory = false,
        canManageInventory = false,
        canOpenServiceManagement = false,
        canManageAdminAccounts = false,
        // Yerel anahtar resident düzeyidir (role_matrix: local_key): kapat/onay/eylemci kontrolü var, bölge testi yok.
        canCloseActuators = true,
        canAckAlarm = true,
        canControlActuators = true,
        canTestSafety = false;

  const Capabilities._raw({
    required this.isAuthenticated,
    required this.isSuperUser,
    required this.isStaff,
    required this.isServiceSession,
    required this.isOwner,
    required this.isResident,
    required this.isGuest,
    required this.isGuestExpired,
    required this.hasHomeAccess,
    required this.canViewState,
    required this.canControlDevices,
    required this.canUseGroupCommands,
    required this.canChangeChildLock,
    required this.canCalibrate,
    required this.canManageRules,
    required this.canInvite,
    required this.canManageMembers,
    required this.canTransferOwnership,
    required this.canGenerateServicePin,
    required this.canClaimDevice,
    required this.canCommission,
    required this.canReplaceBoard,
    required this.canEmergencyReset,
    required this.canOpenWifiRecovery,
    required this.canEditDeviceHost,
    required this.canSwitchMode,
    required this.canFetchLocalKey,
    required this.canReissueDeviceCredential,
    required this.canViewInventory,
    required this.canManageInventory,
    required this.canOpenServiceManagement,
    required this.canManageAdminAccounts,
    required this.canCloseActuators,
    required this.canAckAlarm,
    required this.canControlActuators,
    required this.canTestSafety,
  });

  factory Capabilities._compute({
    required bool authenticated,
    required GlobalRole? g,
    required HomeRole? h,
    required DateTime? guestValidUntil,
    required DateTime? guestValidFrom,
    required DateTime now,
    required bool hasActiveHome,
  }) {
    if (!authenticated || g == null || g == GlobalRole.unknown) {
      return const Capabilities.none();
    }

    final isSuper = g == GlobalRole.superUser;
    final isSession = g == GlobalRole.serviceSession || h == HomeRole.serviceSession;
    final isStaffGlobal = g == GlobalRole.serviceUser;
    final isStaffHome = h == HomeRole.serviceUser;
    final isStaff = isStaffGlobal || isStaffHome;
    final isOwner = h == HomeRole.owner;
    final isResident = h == HomeRole.resident;
    final isGuestRole = h == HomeRole.guest;

    // Misafir penceresi: valid_from <= now <= valid_until. Pencere bilinmiyorsa (null) geçersiz.
    final guestWindowOk = isGuestRole &&
        guestValidUntil != null &&
        !now.isAfter(guestValidUntil) &&
        (guestValidFrom == null || !now.isBefore(guestValidFrom));
    final guestExpired = isGuestRole && !guestWindowOk;

    // Ev erişimi (durum görme / komut): beyaz liste.
    final homeAccess = hasActiveHome &&
        !guestExpired &&
        (isSuper ||
            isSession ||
            isOwner ||
            isResident ||
            isStaffHome ||
            guestWindowOk);

    // Ev rolü olarak "tam yetkili" üyelik (misafir olmayan).
    final isManagerLike = isSuper || isOwner || isStaffHome || isSession;

    final notGuest = !guestWindowOk;
    final control = homeAccess;
    final group = homeAccess && notGuest;
    final childLock = homeAccess && notGuest;
    final calibrate = homeAccess && isManagerLike; // owner, staff, session, super (resident ✖)
    final rules = homeAccess && (isSuper || isStaffHome || isOwner || isResident); // session ✖
    final invite = homeAccess && (isSuper || isOwner);
    final transfer = homeAccess && isOwner; // super ✖
    final servicePin = homeAccess && isOwner; // yalnızca ev sahibi
    final commission = homeAccess && (isSuper || isStaffHome || isSession);
    final replace = homeAccess && (isSuper || isStaffHome || isSession || isOwner);
    final wifi = homeAccess && (isManagerLike || isResident); // misafir ✖
    final emergency = isSuper || isStaffGlobal; // cihaz bazlı; ev bağlamından bağımsız
    // Sunucu matrisi (role_matrix: local_key): staff, servis oturumu, owner, resident — süper ✖.
    final localKey = homeAccess && (isStaffHome || isSession || isOwner || isResident);
    // Sunucu matrisi (device_credential): süper, staff, servis oturumu, owner.
    final deviceCredential = homeAccess && (isSuper || isStaffHome || isSession || isOwner);
    // Güvenlik (tasarım §5.2.4; sunucu role_matrix: actuator_close / safety_ack / actuator_control / safety_test).
    // Güvenli yön (vanayı kapat, sireni sustur) misafir dahil herkes; onay ve açma misafirde yok (7.2b karar 4).
    final safetyMember = homeAccess && (isSuper || isStaffHome || isSession || isOwner || isResident);

    // Cihaz sahiplenme: oturum PIN'i ✖, misafir ✖; ev rolü olmayan sade kullanıcı ✔
    // (yeni müşteri ilk cihazını eşler); bilinmeyen ev rolü ✖.
    final claim = !isSession &&
        (isSuper ||
            isStaff ||
            h == null ||
            h == HomeRole.owner ||
            h == HomeRole.resident);

    return Capabilities._raw(
      isAuthenticated: true,
      isSuperUser: isSuper,
      isStaff: isStaff,
      isServiceSession: isSession,
      isOwner: isOwner && homeAccess,
      isResident: isResident && homeAccess,
      isGuest: guestWindowOk,
      isGuestExpired: guestExpired,
      hasHomeAccess: homeAccess,
      canViewState: homeAccess,
      canControlDevices: control,
      canUseGroupCommands: group,
      canChangeChildLock: childLock,
      canCalibrate: calibrate,
      canManageRules: rules,
      canInvite: invite,
      canManageMembers: invite,
      canTransferOwnership: transfer,
      canGenerateServicePin: servicePin,
      canClaimDevice: claim,
      canCommission: commission,
      canReplaceBoard: replace,
      canEmergencyReset: emergency,
      canOpenWifiRecovery: wifi,
      canEditDeviceHost: wifi,
      canSwitchMode: wifi,
      canFetchLocalKey: localKey,
      canReissueDeviceCredential: deviceCredential,
      canViewInventory: isSuper || isStaffGlobal,
      canManageInventory: isSuper,
      canOpenServiceManagement: isSuper || isStaffGlobal,
      canManageAdminAccounts: isSuper,
      canCloseActuators: control,
      canAckAlarm: safetyMember,
      canControlActuators: safetyMember,
      canTestSafety: homeAccess && isManagerLike,
    );
  }

  /// Oturum açılmış mı (geçerli, tanınan bir küresel rol).
  final bool isAuthenticated;

  /// Küresel `super_user`.
  final bool isSuperUser;

  /// Kalıcı servis personeli: küresel `service_user` **veya** aktif evde `service_user` rolü.
  final bool isStaff;

  /// 2 saatlik servis PIN oturumu.
  final bool isServiceSession;

  /// Aktif evde `owner` (ev erişimi geçerliyse).
  final bool isOwner;

  /// Aktif evde `resident`.
  final bool isResident;

  /// Aktif evde **geçerli** misafir.
  final bool isGuest;

  /// Misafir süresi dolmuş / başlamamış: tüm ev yetkileri kapalı, "süre doldu" ekranı gösterilir.
  final bool isGuestExpired;

  /// Aktif eve (durum görme + komut) erişim var mı.
  final bool hasHomeAccess;

  /// Durum görme (state / endpoint listesi).
  final bool canViewState;

  /// Röle / panjur komutu.
  final bool canControlDevices;

  /// Toplu komutlar (`all_*`, senaryolar). Misafir ✖.
  final bool canUseGroupCommands;

  /// Çocuk kilidi ve huzur bildirimi ayarı. Misafir ✖.
  final bool canChangeChildLock;

  /// Panjur kalibrasyonu, kanal adı/oda. Sakin ve misafir ✖.
  final bool canCalibrate;

  /// Zamanlı kural oluştur/düzenle/sil. Servis PIN oturumu ve misafir ✖.
  final bool canManageRules;

  /// Üye/misafir davet etme (yalnızca owner ve süper kullanıcı).
  final bool canInvite;

  /// Üye listesi yönetimi / çıkarma (yalnızca owner ve süper kullanıcı).
  final bool canManageMembers;

  /// Daire devri (yalnızca owner).
  final bool canTransferOwnership;

  /// Servis PIN'i üretme (yalnızca owner).
  final bool canGenerateServicePin;

  /// Cihaz sahiplenme (claim).
  final bool canClaimDevice;

  /// Devreye alma (commissioning).
  final bool canCommission;

  /// Pano değişimi.
  final bool canReplaceBoard;

  /// Acil sıfırlama (yalnızca süper kullanıcı ve kalıcı servis personeli).
  final bool canEmergencyReset;

  /// Giriş yapılmış alanlardaki (pano/ayarlar kartı, sistem doktoru) Wi-Fi kurtarma sihirbazı
  /// **giriş noktalarını** gösterme yetkisi. Misafir ✖. Sihirbazın kendisi (`WifiRecoveryDialog`) ve servis
  /// paneli kartı **yetki kapısızdır**: girişsiz/internetsiz de açılır (CONTRACTS §3d; cihaza özel kurulum
  /// ağı parolasını bilmek = fiziksel erişim).
  final bool canOpenWifiRecovery;

  /// Cihaz adresi (IP/host) düzenleme. Misafir ✖.
  final bool canEditDeviceHost;

  /// Bulut/Doğrudan mod anahtarı. Misafir ✖.
  final bool canSwitchMode;

  /// Cihaz yerel anahtarını (`X-Device-Key`) sunucudan alma: owner, resident, kalıcı servis
  /// personeli (o evde) ve servis PIN oturumu. **Süper kullanıcı ✖** (sunucu matrisi), misafir ✖.
  final bool canFetchLocalKey;

  /// Cihazın bulut (MQTT) kimliğini yeniden üretme: owner, servis personeli, servis oturumu,
  /// süper kullanıcı. Resident ve misafir ✖.
  final bool canReissueDeviceCredential;

  /// Cihaz envanterini listeleme (süper kullanıcı; servis personeli kendi stoku).
  final bool canViewInventory;

  /// Envanter oluştur/sil/durum değiştir (yalnızca süper kullanıcı).
  final bool canManageInventory;

  /// Servis yönetim ekranı (süper kullanıcı ve kalıcı servis personeli).
  final bool canOpenServiceManagement;

  /// Yönetici hesapları (süper kullanıcı/servis sorumlusu oluşturma-düzenleme).
  final bool canManageAdminAccounts;

  /// Güvenlik eylemcisini güvenli yöne götürme: vanayı kapatma, sireni/fanı kapatma. Misafir DAHİL.
  final bool canCloseActuators;

  /// Alarmı onaylama / susturma. Misafir ✖.
  final bool canAckAlarm;

  /// Eylemciyi güvenli olmayan yöne sürme: su vanasını açma, siren/fan/genel cihazı açma. Misafir ✖.
  /// **Gaz vanası hiçbir rolde uygulamadan açılmaz** (yalnız yerinde) [K-4].
  final bool canControlActuators;

  /// Bölge testi (`alarm_test`): owner, kalıcı servis personeli, servis oturumu, süper kullanıcı.
  final bool canTestSafety;

  /// Hırsız alarmı kipini kurma/çözme (Faz 2 F2.B.6, karar F2-3; sunucu `safety_arm` = owner, resident). Misafir ve
  /// servis rolleri (süper, servis personeli, servis oturumu) buluttan YAPAMAZ; yerel anahtar (LAN) resident düzeyidir.
  /// Mevcut bayraklardan türetilir (eşitlik maskesi değişmez).
  bool get canArm {
    if (!isAuthenticated) return canControlActuators; // yerel anahtar sahibi (Capabilities.localKeyHolder)
    return hasHomeAccess && (isOwner || isResident) && !isSuperUser && !isStaff && !isServiceSession;
  }

  /// Test/hata ayıklama için tüm bayrakların adlı görünümü.
  Map<String, bool> toMap() => <String, bool>{
        'isAuthenticated': isAuthenticated,
        'isSuperUser': isSuperUser,
        'isStaff': isStaff,
        'isServiceSession': isServiceSession,
        'isOwner': isOwner,
        'isResident': isResident,
        'isGuest': isGuest,
        'isGuestExpired': isGuestExpired,
        'hasHomeAccess': hasHomeAccess,
        'canViewState': canViewState,
        'canControlDevices': canControlDevices,
        'canUseGroupCommands': canUseGroupCommands,
        'canChangeChildLock': canChangeChildLock,
        'canCalibrate': canCalibrate,
        'canManageRules': canManageRules,
        'canInvite': canInvite,
        'canManageMembers': canManageMembers,
        'canTransferOwnership': canTransferOwnership,
        'canGenerateServicePin': canGenerateServicePin,
        'canClaimDevice': canClaimDevice,
        'canCommission': canCommission,
        'canReplaceBoard': canReplaceBoard,
        'canEmergencyReset': canEmergencyReset,
        'canOpenWifiRecovery': canOpenWifiRecovery,
        'canEditDeviceHost': canEditDeviceHost,
        'canSwitchMode': canSwitchMode,
        'canFetchLocalKey': canFetchLocalKey,
        'canReissueDeviceCredential': canReissueDeviceCredential,
        'canViewInventory': canViewInventory,
        'canManageInventory': canManageInventory,
        'canOpenServiceManagement': canOpenServiceManagement,
        'canManageAdminAccounts': canManageAdminAccounts,
        'canCloseActuators': canCloseActuators,
        'canAckAlarm': canAckAlarm,
        'canControlActuators': canControlActuators,
        'canTestSafety': canTestSafety,
      };

  /// İlk 32 bayrağın tek bir tamsayıdaki bit maskesi ([toMap] sırasıyla; bit 0 = [isAuthenticated]); sonraki
  /// bayraklar [_mask2]'dedir (web'de bit işlemleri 32 bitliktir: `1 << 32` kullanılmaz). `==`/`hashCode`
  /// bununla karşılaştırır: `context.select<AutomationState, Capabilities>` her bildirimde `==` çağırır ve eski
  /// uygulama her çağrıda iki 32'lik `Map` kuruyordu (PF-20). Sınıf `const` kurucular içerdiğinden `late final`
  /// alan kullanılamaz; maske her çağrıda 32 koşullu `OR` ile (ayırma olmadan) hesaplanır. Yeni bir bayrak
  /// eklenirse HEM [toMap] HEM bu maske güncellenmelidir (test: `state_memo_test.dart`, `toMap` eşdeğerliği).
  int get _mask =>
      (isAuthenticated ? 1 << 0 : 0) |
      (isSuperUser ? 1 << 1 : 0) |
      (isStaff ? 1 << 2 : 0) |
      (isServiceSession ? 1 << 3 : 0) |
      (isOwner ? 1 << 4 : 0) |
      (isResident ? 1 << 5 : 0) |
      (isGuest ? 1 << 6 : 0) |
      (isGuestExpired ? 1 << 7 : 0) |
      (hasHomeAccess ? 1 << 8 : 0) |
      (canViewState ? 1 << 9 : 0) |
      (canControlDevices ? 1 << 10 : 0) |
      (canUseGroupCommands ? 1 << 11 : 0) |
      (canChangeChildLock ? 1 << 12 : 0) |
      (canCalibrate ? 1 << 13 : 0) |
      (canManageRules ? 1 << 14 : 0) |
      (canInvite ? 1 << 15 : 0) |
      (canManageMembers ? 1 << 16 : 0) |
      (canTransferOwnership ? 1 << 17 : 0) |
      (canGenerateServicePin ? 1 << 18 : 0) |
      (canClaimDevice ? 1 << 19 : 0) |
      (canCommission ? 1 << 20 : 0) |
      (canReplaceBoard ? 1 << 21 : 0) |
      (canEmergencyReset ? 1 << 22 : 0) |
      (canOpenWifiRecovery ? 1 << 23 : 0) |
      (canEditDeviceHost ? 1 << 24 : 0) |
      (canSwitchMode ? 1 << 25 : 0) |
      (canFetchLocalKey ? 1 << 26 : 0) |
      (canReissueDeviceCredential ? 1 << 27 : 0) |
      (canViewInventory ? 1 << 28 : 0) |
      (canManageInventory ? 1 << 29 : 0) |
      (canOpenServiceManagement ? 1 << 30 : 0) |
      (canManageAdminAccounts ? 1 << 31 : 0);

  /// Güvenlik bayrakları ([toMap] sırasıyla, 33. bayraktan itibaren).
  int get _mask2 =>
      (canCloseActuators ? 1 << 0 : 0) |
      (canAckAlarm ? 1 << 1 : 0) |
      (canControlActuators ? 1 << 2 : 0) |
      (canTestSafety ? 1 << 3 : 0);

  @override
  bool operator ==(Object other) => other is Capabilities && _mask == other._mask && _mask2 == other._mask2;

  @override
  int get hashCode => Object.hash(_mask, _mask2);

  @override
  String toString() {
    final granted = toMap().entries.where((e) => e.value).map((e) => e.key).join(', ');
    return 'Capabilities($granted)';
  }
}
