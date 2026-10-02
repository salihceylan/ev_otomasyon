import 'package:flutter/foundation.dart';

import '../../../../models/json_utils.dart';

/// Abonenin (dairenin) mevcut Home Admin'i (sahibi).
@immutable
class SubscriberOwner {
  const SubscriberOwner({this.id, required this.fullName, this.email, this.phone, this.accountStatus});

  final String? id;
  final String fullName;
  final String? email;
  final String? phone;

  /// `active | pending_invite | suspended` (sunucu bildirmediyse `null`).
  final String? accountStatus;

  /// Yönetici adı yoksa `null` (sahip yok sayılır).
  static SubscriberOwner? tryParse(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final name = asNonEmptyString(map['full_name'] ?? map['fullName'] ?? map['name']);
    if (name == null) return null;
    return SubscriberOwner(
      id: asNonEmptyString(map['id'] ?? map['user_id']),
      fullName: name,
      email: asNonEmptyString(map['email']),
      phone: asNonEmptyString(map['phone']),
      accountStatus: asNonEmptyString(map['account_status']),
    );
  }

  /// İletişim bilgisi (e-posta, yoksa telefon).
  String get contact => email ?? phone ?? 'İletişim bilgisi yok';

  /// Hesap henüz etkinleştirilmedi (davet bekliyor): sahibe e-posta ile kod gitse de uygulamaya girmemiş olabilir.
  bool get isPendingInvite => accountStatus == 'pending_invite';
}

/// Servis abonesi: bir daire + pano(lar) + Home Admin durumu.
///
/// **Tip güvenli ayrıştırma:** `home_id` sunucudan sayı ya da metin gelebilir (`101` / UUID); sert
/// `as int` / `as String` dönüşümü yoktur. Kimliği olmayan kayıt `null` döner ve atlanır.
///
/// Sunucu (B2) yanıtı: `{home_id, home_name, home_address, owner, device_count, online_count,
/// commissioned_count, commissioned_at, last_seen_at, device_uuids[], created_at}`. Eski/yalın biçimler
/// (`device_uuid`, `is_commissioned`, `commissioning_status`) de okunur.
@immutable
class Subscriber {
  const Subscriber({
    required this.homeId,
    required this.homeName,
    this.address = '',
    this.deviceUuids = const <String>[],
    this.deviceCount = 0,
    this.onlineCount = 0,
    this.commissionedCount = 0,
    this.commissionedFlag = false,
    this.lastSeenAt,
    this.owner,
  });

  final String homeId;
  final String homeName;
  final String address;

  /// Dairedeki panoların kimlikleri (sunucu en çok birkaçını listeler; toplam [deviceCount]).
  final List<String> deviceUuids;
  final int deviceCount;
  final int onlineCount;
  final int commissionedCount;

  /// Eski biçimdeki tek "devrede" bilgisi.
  final bool commissionedFlag;
  final DateTime? lastSeenAt;
  final SubscriberOwner? owner;

  bool get hasOwner => owner != null;

  /// İlk panonun kimliği (yoksa boş).
  String get deviceUuid => deviceUuids.isEmpty ? '' : deviceUuids.first;

  /// Dairede devreye alınmış (onaylanmış) en az bir pano var.
  bool get isCommissioned => commissionedCount > 0 || commissionedFlag;

  /// Listelenenden fazla pano var mı ("+N pano").
  int get hiddenDeviceCount {
    final extra = deviceCount - deviceUuids.length;
    return extra > 0 ? extra : 0;
  }

  static Subscriber? tryParse(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['home_id'] ?? json['homeId'] ?? json['id']);
    if (id == null) return null;
    final uuids = <String>[
      for (final raw in asList(json['device_uuids'] ?? json['deviceUuids']) ?? const <dynamic>[])
        if (asNonEmptyString(raw) != null) asNonEmptyString(raw)!,
    ];
    final single = asNonEmptyString(json['device_uuid'] ?? json['deviceUuid']);
    if (uuids.isEmpty && single != null) uuids.add(single);
    final count = asInt(json['device_count'] ?? json['deviceCount']) ?? uuids.length;
    return Subscriber(
      homeId: id,
      homeName: asNonEmptyString(json['home_name'] ?? json['homeName'] ?? json['name']) ?? 'İsimsiz Daire',
      address: asNonEmptyString(json['home_address'] ?? json['address']) ?? '',
      deviceUuids: uuids,
      deviceCount: count < uuids.length ? uuids.length : count,
      onlineCount: asInt(json['online_count']) ?? 0,
      commissionedCount: asInt(json['commissioned_count']) ?? (asNonEmptyString(json['commissioned_at']) != null ? 1 : 0),
      commissionedFlag: asBool(json['is_commissioned'] ?? json['isCommissioned']) ??
          (asNonEmptyString(json['commissioning_status'])?.toUpperCase() == 'APPROVED_WORKING'),
      lastSeenAt: asDate(json['last_seen_at']),
      owner: SubscriberOwner.tryParse(json['owner']),
    );
  }

  /// Kullanıcıya gösterilen kısa daire kimliği.
  String get shortId => homeId.length > 8 ? homeId.substring(0, 8) : homeId;

  /// Arama için birleşik metin (küçük harf).
  String get searchText => <String>[
        homeName,
        address,
        ...deviceUuids,
        owner?.fullName ?? '',
        owner?.email ?? '',
        owner?.phone ?? '',
      ].join(' ').toLowerCase();
}

/// Ham liste -> tipli abonelere (bozuk kayıt atlanır).
List<Subscriber> parseSubscribers(Iterable<Map<String, dynamic>> raw) => <Subscriber>[
      for (final item in raw) ?Subscriber.tryParse(item),
    ];
