import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

/// CONTRACTS §1.4 rol/yetki matrisi: her rol × her yetki, **tam küme eşitliği** ile.
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);
  final inFuture = now.add(const Duration(hours: 5));
  final inPast = now.subtract(const Duration(hours: 5));

  Set<String> granted(Capabilities c) =>
      c.toMap().entries.where((e) => e.value).map((e) => e.key).toSet();

  /// Her satırda `is*` rozetleri de dahil, `true` olması gereken TÜM alanlar yazılır.
  void expectExactly(String label, Capabilities caps, Set<String> expected) {
    final actual = granted(caps);
    expect(
      actual,
      equals(expected),
      reason: '$label\n  fazla: ${actual.difference(expected)}\n  eksik: ${expected.difference(actual)}',
    );
  }

  const homeBase = <String>{'hasHomeAccess', 'canViewState', 'canControlDevices'};
  const groupAndLock = <String>{'canUseGroupCommands', 'canChangeChildLock'};

  test('süper kullanıcı (ev bağlamında, üye olmadan açık istisna)', () {
    final caps = Capabilities(globalRole: 'super_user', homeRole: null, hasActiveHome: true, now: now);
    expectExactly('super', caps, <String>{
      'isAuthenticated',
      'isSuperUser',
      ...homeBase,
      ...groupAndLock,
      'canCalibrate',
      'canManageRules',
      'canInvite',
      'canManageMembers',
      // devir ✖, servis PIN ✖ (yalnızca owner)
      'canClaimDevice',
      'canCommission',
      'canReplaceBoard',
      'canEmergencyReset',
      'canOpenWifiRecovery',
      'canEditDeviceHost',
      'canSwitchMode',
      // yerel anahtar ✖ (sunucu matrisi: süper kullanıcı local_key alamaz); cihaz kimliği ✔
      'canReissueDeviceCredential',
      'canViewInventory',
      'canManageInventory',
      'canOpenServiceManagement',
      'canManageAdminAccounts',
    });
  });

  test('süper kullanıcı aktif ev yokken ev yetkisi almaz; küresel yetkileri kalır', () {
    final caps = Capabilities(globalRole: 'super_user', now: now);
    expect(caps.canControlDevices, isFalse);
    expect(caps.canCalibrate, isFalse);
    expect(caps.canEmergencyReset, isTrue);
    expect(caps.canManageInventory, isTrue);
    expect(caps.canClaimDevice, isTrue);
  });

  test('kalıcı servis personeli (evde service_user)', () {
    final caps = Capabilities(globalRole: 'service_user', homeRole: 'service_user', now: now);
    expectExactly('staff', caps, <String>{
      'isAuthenticated',
      'isStaff',
      ...homeBase,
      ...groupAndLock,
      'canCalibrate',
      'canManageRules',
      // davet ✖, devir ✖, servis PIN ✖
      'canClaimDevice',
      'canCommission',
      'canReplaceBoard',
      'canEmergencyReset',
      'canOpenWifiRecovery',
      'canEditDeviceHost',
      'canSwitchMode',
      'canFetchLocalKey',
      'canReissueDeviceCredential',
      'canViewInventory',
      'canOpenServiceManagement',
    });
  });

  test('kalıcı servis personeli üyeliği olmayan eve erişemez (home_users zorunlu)', () {
    final caps = Capabilities(globalRole: 'service_user', homeRole: null, hasActiveHome: true, now: now);
    expect(caps.hasHomeAccess, isFalse);
    expect(caps.canControlDevices, isFalse);
    expect(caps.canCommission, isFalse);
    // ev bağlamından bağımsız yetkiler:
    expect(caps.canClaimDevice, isTrue);
    expect(caps.canEmergencyReset, isTrue);
    expect(caps.canViewInventory, isTrue);
  });

  test('servis PIN oturumu (tek ev)', () {
    final caps = Capabilities(globalRole: 'service_session', homeRole: 'service_session', now: now);
    expectExactly('service_session', caps, <String>{
      'isAuthenticated',
      'isServiceSession',
      ...homeBase,
      ...groupAndLock,
      'canCalibrate',
      // kural ✖, davet ✖, devir ✖, PIN ✖, claim ✖
      'canCommission',
      'canReplaceBoard',
      // acil sıfırlama ✖
      'canOpenWifiRecovery',
      'canEditDeviceHost',
      'canSwitchMode',
      'canFetchLocalKey',
      'canReissueDeviceCredential',
    });
  });

  test('ev sahibi (owner)', () {
    final caps = Capabilities(globalRole: 'user', homeRole: 'owner', now: now);
    expectExactly('owner', caps, <String>{
      'isAuthenticated',
      'isOwner',
      ...homeBase,
      ...groupAndLock,
      'canCalibrate',
      'canManageRules',
      'canInvite',
      'canManageMembers',
      'canTransferOwnership',
      'canGenerateServicePin',
      'canClaimDevice',
      // devreye alma ✖
      'canReplaceBoard',
      // acil sıfırlama ✖
      'canOpenWifiRecovery',
      'canEditDeviceHost',
      'canSwitchMode',
      'canFetchLocalKey',
      'canReissueDeviceCredential',
    });
  });

  test('sakin (resident; eski ad member de eşlenir)', () {
    for (final role in <String>['resident', 'member', ' Resident ']) {
      final caps = Capabilities(globalRole: 'user', homeRole: role, now: now);
      expectExactly('resident($role)', caps, <String>{
        'isAuthenticated',
        'isResident',
        ...homeBase,
        ...groupAndLock,
        // kalibrasyon ✖
        'canManageRules',
        // davet ✖, devir ✖, PIN ✖
        'canClaimDevice',
        'canOpenWifiRecovery',
        'canEditDeviceHost',
        'canSwitchMode',
        'canFetchLocalKey', // cihaz kimliği yenileme ✖
      });
    }
  });

  test('geçerli misafir', () {
    final caps = Capabilities(
      globalRole: 'user',
      homeRole: 'guest',
      guestValidFrom: inPast,
      guestValidUntil: inFuture,
      now: now,
    );
    expectExactly('guest', caps, <String>{
      'isAuthenticated',
      'isGuest',
      ...homeBase,
      // toplu ✖, çocuk kilidi ✖, kalibrasyon ✖, kural ✖, davet ✖, claim ✖, Wi-Fi/IP ✖
    });
  });

  test('süresi dolmuş / henüz başlamamış / penceresi bilinmeyen misafir hiçbir ev yetkisi almaz', () {
    final expired = Capabilities(globalRole: 'user', homeRole: 'guest', guestValidUntil: inPast, now: now);
    final notStarted = Capabilities(
      globalRole: 'user',
      homeRole: 'guest',
      guestValidFrom: inFuture,
      guestValidUntil: inFuture.add(const Duration(hours: 1)),
      now: now,
    );
    final unknownWindow = Capabilities(globalRole: 'user', homeRole: 'guest', now: now);
    for (final caps in <Capabilities>[expired, notStarted, unknownWindow]) {
      expect(caps.isGuestExpired, isTrue);
      expect(caps.isGuest, isFalse);
      expect(caps.hasHomeAccess, isFalse);
      expect(caps.canViewState, isFalse);
      expect(caps.canControlDevices, isFalse);
      expect(caps.canUseGroupCommands, isFalse);
      expect(granted(caps), equals(<String>{'isAuthenticated', 'isGuestExpired'}));
    }
  });

  test('bilinmeyen / eksik rol = hiçbir yetki (beyaz liste)', () {
    expectExactly('bilinmeyen küresel rol', Capabilities(globalRole: 'hacker', homeRole: 'owner', now: now), <String>{});
    expectExactly('oturum yok', Capabilities(globalRole: null, homeRole: 'owner', now: now), <String>{});
    expectExactly('boş küresel rol', Capabilities(globalRole: '  ', now: now), <String>{});
    // Tanınmayan EV rolü: ev yetkisi yok; yalnızca küresel hak (claim: ev rolü bilinmediği için ✖).
    final unknownHome = Capabilities(globalRole: 'user', homeRole: 'admin', now: now);
    expect(unknownHome.hasHomeAccess, isFalse);
    expect(unknownHome.canControlDevices, isFalse);
    expect(unknownHome.canCalibrate, isFalse);
    expect(unknownHome.canInvite, isFalse);
    expect(unknownHome.canClaimDevice, isFalse);
  });

  test('evsiz sade kullanıcı: yalnızca cihaz sahiplenebilir', () {
    final caps = Capabilities(globalRole: 'user', now: now);
    expectExactly('evsiz kullanıcı', caps, <String>{'isAuthenticated', 'canClaimDevice'});
  });

  test('rol dizgisi normalizasyonu (büyük/küçük harf, boşluk, eski adlar)', () {
    expect(GlobalRole.parse('SUPER_USER'), GlobalRole.superUser);
    expect(GlobalRole.parse(' service_user '), GlobalRole.serviceUser);
    expect(GlobalRole.parse('installer'), GlobalRole.serviceUser);
    expect(GlobalRole.parse('owner'), GlobalRole.unknown); // ev rolü küresel rol değildir
    expect(GlobalRole.parse(null), GlobalRole.unknown);
    expect(HomeRole.parse('MEMBER'), HomeRole.resident);
    expect(HomeRole.parse('installer'), HomeRole.serviceUser);
    expect(HomeRole.parse('service_session'), HomeRole.serviceSession);
    expect(HomeRole.parse('xyz'), HomeRole.unknown);
    expect(HomeRole.owner.wire, 'owner');
    expect(GlobalRole.superUser.wire, 'super_user');
  });

  test('yerel anahtar sahibi (oturumsuz yerel mod) yalnızca durum + komut', () {
    const caps = Capabilities.localKeyHolder();
    expect(caps.canControlDevices, isTrue);
    expect(caps.canViewState, isTrue);
    expect(caps.canCalibrate, isFalse);
    expect(caps.canClaimDevice, isFalse);
    expect(caps.canInvite, isFalse);
    expect(caps.canFetchLocalKey, isFalse); // anahtarı zaten elinde; sunucudan alamaz
    expect(caps.canReissueDeviceCredential, isFalse);
    expect(const Capabilities.none().canControlDevices, isFalse);
  });

  test('yerel anahtar ve cihaz kimliği yetkileri sunucu matrisini (role_matrix) yansıtır', () {
    Capabilities caps(String global, String? home, {DateTime? until}) => Capabilities(
          globalRole: global,
          homeRole: home,
          guestValidUntil: until,
          hasActiveHome: true,
          now: now,
        );
    // local_key: staff, servis oturumu, owner, resident — süper ✖, misafir ✖.
    expect(caps('super_user', null).canFetchLocalKey, isFalse);
    expect(caps('service_user', 'service_user').canFetchLocalKey, isTrue);
    expect(caps('service_session', 'service_session').canFetchLocalKey, isTrue);
    expect(caps('user', 'owner').canFetchLocalKey, isTrue);
    expect(caps('user', 'resident').canFetchLocalKey, isTrue);
    expect(caps('user', 'guest', until: inFuture).canFetchLocalKey, isFalse);
    // device_credential: süper, staff, servis oturumu, owner — resident ✖, misafir ✖.
    expect(caps('super_user', null).canReissueDeviceCredential, isTrue);
    expect(caps('service_user', 'service_user').canReissueDeviceCredential, isTrue);
    expect(caps('service_session', 'service_session').canReissueDeviceCredential, isTrue);
    expect(caps('user', 'owner').canReissueDeviceCredential, isTrue);
    expect(caps('user', 'resident').canReissueDeviceCredential, isFalse);
    expect(caps('user', 'guest', until: inFuture).canReissueDeviceCredential, isFalse);
    // Süresi dolmuş misafir ve ev bağlamı olmayan kullanıcı: hiçbiri.
    expect(caps('user', 'guest', until: inPast).canFetchLocalKey, isFalse);
    expect(Capabilities(globalRole: 'user', now: now).canFetchLocalKey, isFalse);
  });

  test('eşitlik ve toString', () {
    final a = Capabilities(globalRole: 'user', homeRole: 'owner', now: now);
    final b = Capabilities(globalRole: 'user', homeRole: 'owner', now: now);
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(a.toString(), contains('canInvite'));
  });
}
