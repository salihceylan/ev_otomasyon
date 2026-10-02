import 'package:flutter/foundation.dart';

import '../../../../models/capabilities.dart';
import '../../../../models/json_utils.dart';

/// Hesabın yaşam durumu (`users.account_status`).
enum AccountStatus { active, pendingInvite, suspended, unknown }

/// Servis yönetimi listesindeki bir hesap (süper yönetici, servis sorumlusu ya da müşteri).
///
/// * `id` metindir (UUID); `role` **normalleştirilir** ([GlobalRole.parse]: büyük/küçük harf, boşluk,
///   eski adlar).
/// * Bozuk kayıt ([tryParse] -> `null`) listeden atılır, tüm listeyi bozmaz.
@immutable
class AdminAccount {
  const AdminAccount({
    required this.id,
    required this.fullName,
    required this.email,
    required this.role,
    required this.isActive,
    required this.status,
    this.phone = '',
    this.notes = '',
    this.createdByName,
    this.homeCount,
  });

  final String id;
  final String fullName;
  final String email;
  final String phone;
  final GlobalRole role;
  final bool isActive;
  final AccountStatus status;
  final String notes;
  final String? createdByName;
  final int? homeCount;

  bool get isSuper => role == GlobalRole.superUser;
  bool get isServiceStaff => role == GlobalRole.serviceUser;

  /// Hesap donduruldu (pasif ya da `suspended`).
  bool get isFrozen => !isActive || status == AccountStatus.suspended;

  /// Davet e-postası bekliyor (henüz parola belirlenmedi).
  bool get isPendingInvite => status == AccountStatus.pendingInvite;

  static AccountStatus _status(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'active':
        return AccountStatus.active;
      case 'pending_invite':
        return AccountStatus.pendingInvite;
      case 'suspended':
        return AccountStatus.suspended;
    }
    return AccountStatus.unknown;
  }

  static AdminAccount? tryParse(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final id = asNonEmptyString(map['id']);
    if (id == null) return null;
    final role = GlobalRole.parse(asString(map['role']));
    return AdminAccount(
      id: id,
      fullName: asNonEmptyString(map['full_name'] ?? map['fullName']) ?? 'İsimsiz',
      email: asString(map['email']) ?? '',
      phone: asString(map['phone']) ?? '',
      role: role,
      isActive: asBool(map['is_active']) ?? true,
      status: _status(asString(map['account_status'])),
      notes: asString(map['admin_notes']) ?? '',
      createdByName: asNonEmptyString(map['created_by_name']),
      homeCount: asInt(map['home_count']),
    );
  }

  AdminAccount copyWith({bool? isActive, AccountStatus? status}) => AdminAccount(
        id: id,
        fullName: fullName,
        email: email,
        phone: phone,
        role: role,
        isActive: isActive ?? this.isActive,
        status: status ?? this.status,
        notes: notes,
        createdByName: createdByName,
        homeCount: homeCount,
      );

  /// Kullanıcıya gösterilen rol etiketi.
  String get roleLabel {
    switch (role) {
      case GlobalRole.superUser:
        return 'SÜPER YÖNETİCİ';
      case GlobalRole.serviceUser:
        return 'SERVİS SORUMLUSU';
      case GlobalRole.user:
        return 'MÜŞTERİ';
      case GlobalRole.serviceSession:
        return 'SERVİS OTURUMU';
      case GlobalRole.unknown:
        return 'BİLİNMEYEN ROL';
    }
  }

  /// Durum etiketi (kart rozeti).
  String get statusLabel {
    if (isFrozen) return 'Donduruldu';
    if (isPendingInvite) return 'Davet bekliyor';
    return 'Aktif';
  }
}

/// Dondurma engelinin nedeni.
enum FreezeBlock { self, lastSuper }

/// Hesap yönetimi kuralları (istemci tarafı ön denetim; **karar sunucudadır**).
class AccountRules {
  AccountRules._();

  /// [target] dondurulamıyorsa nedeni; dondurulabilirse `null`.
  ///
  /// * Kullanıcı kendi hesabını donduramaz.
  /// * Son aktif süper yönetici donduramaz: yalnızca **tüm süper yöneticiler yüklüyse** ([allSupersLoaded])
  ///   ve [loaded] içinde başka aktif süper yönetici yoksa kesin konuşulur; aksi halde karar sunucuya
  ///   bırakılır (`409 CONFLICT` kullanıcıya gösterilir).
  static FreezeBlock? freezeBlock({
    required AdminAccount target,
    required String? currentUserId,
    required List<AdminAccount> loaded,
    required bool allSupersLoaded,
  }) {
    if (currentUserId != null && target.id == currentUserId) return FreezeBlock.self;
    if (target.isSuper && !target.isFrozen && allSupersLoaded) {
      final otherActiveSupers = loaded.where((a) => a.isSuper && !a.isFrozen && a.id != target.id).length;
      if (otherActiveSupers == 0) return FreezeBlock.lastSuper;
    }
    return null;
  }

  /// Dondurma engelinin açıklaması.
  static String freezeBlockText(FreezeBlock block) {
    switch (block) {
      case FreezeBlock.self:
        return 'Kendi hesabınızı donduramazsınız.';
      case FreezeBlock.lastSuper:
        return 'Son aktif süper yönetici dondurulamaz; önce başka bir süper yönetici ekleyin.';
    }
  }
}
