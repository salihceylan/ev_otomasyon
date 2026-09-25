class UserModel {
  final int id;
  final String idStr;
  final String email;
  final String fullName;
  final String phone;
  final String role; // super_user, service_user, owner, resident, guest
  final String? token;
  final String? adminNotes;

  UserModel({
    required this.id,
    this.idStr = '',
    required this.email,
    required this.fullName,
    required this.phone,
    required this.role,
    this.token,
    this.adminNotes,
  });

  String get effectiveId => idStr.isNotEmpty ? idStr : id.toString();
  bool get isSuperUser => role == 'super_user';
  bool get isServiceUser => role == 'service_user';
  bool get isServiceManagerOrSuper => isSuperUser || isServiceUser;
  bool get isOwner => role == 'owner';
  bool get isResident => role == 'resident';
  bool get isGuest => role == 'guest';

  factory UserModel.fromJson(Map<String, dynamic> json, {String? token}) {
    final rawId = json['id']?.toString() ?? '';
    return UserModel(
      id: json['id'] is int ? json['id'] : int.tryParse(rawId) ?? 0,
      idStr: rawId,
      email: json['email'] ?? '',
      fullName: json['full_name'] ?? '',
      phone: json['phone'] ?? '',
      role: json['role'] ?? 'resident',
      token: token ?? json['token'],
      adminNotes: json['admin_notes']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': idStr.isNotEmpty ? idStr : id,
      'email': email,
      'full_name': fullName,
      'phone': phone,
      'role': role,
      'token': token,
      'admin_notes': adminNotes,
    };
  }
}

class HomeModel {
  final int id;
  final String idStr;
  final String name;
  final String? address;
  final String mqttUsername;
  final String? role;

  HomeModel({
    required this.id,
    this.idStr = '',
    required this.name,
    this.address,
    required this.mqttUsername,
    this.role,
  });

  /// UUID veya integer id'nin güvenli string temsili
  String get effectiveId => (idStr.isNotEmpty && idStr != '0') ? idStr : id.toString();

  factory HomeModel.fromJson(Map<String, dynamic> json) {
    final rawId = json['id']?.toString() ?? '';
    return HomeModel(
      id: json['id'] is int ? json['id'] : int.tryParse(rawId) ?? 0,
      idStr: rawId,
      name: json['name'] ?? 'Evim',
      address: json['address'],
      mqttUsername: json['mqtt_username'] ?? '',
      role: json['role'],
    );
  }
}

class EndpointModel {
  final int id;
  final int homeId;
  final int? deviceId;
  final int channel;
  final String name;
  final String room; // salon, mutfak, yatak_odasi, antre, balkon vb.
  final String endpointType; // light, shutter, impulse, plug
  final bool currentState;
  final int shutterPosition; // 0..100
  final int shutterDurationSec;

  EndpointModel({
    required this.id,
    required this.homeId,
    this.deviceId,
    required this.channel,
    required this.name,
    required this.room,
    required this.endpointType,
    required this.currentState,
    this.shutterPosition = 0,
    this.shutterDurationSec = 20,
  });

  bool get isLight => endpointType == 'light';
  bool get isShutter => endpointType == 'shutter';
  bool get isImpulse => endpointType == 'impulse';
  bool get isPlug => endpointType == 'plug';

  factory EndpointModel.fromJson(Map<String, dynamic> json) {
    return EndpointModel(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 0,
      homeId: json['home_id'] is int ? json['home_id'] : int.tryParse(json['home_id'].toString()) ?? 0,
      deviceId: json['device_id'] is int ? json['device_id'] : int.tryParse(json['device_id']?.toString() ?? ''),
      channel: json['channel'] is int ? json['channel'] : int.tryParse(json['channel'].toString()) ?? 1,
      name: json['name'] ?? 'Uç Nokta',
      room: json['room'] ?? 'Genel',
      endpointType: json['endpoint_type'] ?? 'light',
      currentState: json['current_state'] == true || json['current_state'] == 1,
      shutterPosition: json['shutter_position'] is int ? json['shutter_position'] : int.tryParse(json['shutter_position']?.toString() ?? '0') ?? 0,
      shutterDurationSec: json['shutter_duration_sec'] is int ? json['shutter_duration_sec'] : int.tryParse(json['shutter_duration_sec']?.toString() ?? '20') ?? 20,
    );
  }

  EndpointModel copyWith({
    bool? currentState,
    int? shutterPosition,
    String? name,
    String? room,
  }) {
    return EndpointModel(
      id: id,
      homeId: homeId,
      deviceId: deviceId,
      channel: channel,
      name: name ?? this.name,
      room: room ?? this.room,
      endpointType: endpointType,
      currentState: currentState ?? this.currentState,
      shutterPosition: shutterPosition ?? this.shutterPosition,
      shutterDurationSec: shutterDurationSec,
    );
  }
}

class ServiceTokenModel {
  final String pin;
  final DateTime expiresAt;

  ServiceTokenModel({
    required this.pin,
    required this.expiresAt,
  });

  factory ServiceTokenModel.fromJson(Map<String, dynamic> json) {
    return ServiceTokenModel(
      pin: json['pin'] ?? '',
      expiresAt: DateTime.tryParse(json['expires_at'] ?? '') ?? DateTime.now().add(const Duration(hours: 2)),
    );
  }
}

class InvitationModel {
  final String code;
  final String role;
  final DateTime expiresAt;
  final String? homeName;

  InvitationModel({
    required this.code,
    required this.role,
    required this.expiresAt,
    this.homeName,
  });

  factory InvitationModel.fromJson(Map<String, dynamic> json) {
    return InvitationModel(
      code: json['code'] ?? '',
      role: json['role'] ?? 'member',
      expiresAt: DateTime.tryParse(json['expires_at'] ?? '') ?? DateTime.now().add(const Duration(hours: 24)),
      homeName: json['home_name'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'role': role,
      'expires_at': expiresAt.toIso8601String(),
      if (homeName != null) 'home_name': homeName,
    };
  }
}

/// Cihaz Envanteri ve QR Yaşam Döngüsü Modeli (Faz 6 & Süper Yönetici)
class InventoryDeviceModel {
  final String id;
  final int? serialNo;
  final String deviceUuid;
  final String macAddress;
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

  String get formattedSerial => serialNo != null ? '#${serialNo.toString().padLeft(4, '0')}' : '#----';
  bool get isInStock => status.toUpperCase() == 'IN_STOCK';
  bool get isClaimed => status.toUpperCase() == 'CLAIMED' || status.toUpperCase() == 'INSTALLED';
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
    return InventoryDeviceModel(
      id: json['id']?.toString() ?? '',
      serialNo: json['serial_no'] != null ? int.tryParse(json['serial_no'].toString()) : null,
      deviceUuid: json['device_uuid']?.toString() ?? '',
      macAddress: json['mac_address']?.toString() ?? '',
      model: json['model']?.toString() ?? 'ESP32-S3-POE-ETH-8DI-8RO',
      batchNo: json['batch_no']?.toString() ?? 'BATCH-2026-01',
      status: json['status']?.toString() ?? 'IN_STOCK',
      failedAttempts: (json['failed_attempts'] as num?)?.toInt() ?? 0,
      lockedUntil: json['locked_until'] != null ? DateTime.tryParse(json['locked_until']) : null,
      claimedAt: json['claimed_at'] != null ? DateTime.tryParse(json['claimed_at']) : null,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: json['updated_at'] != null ? DateTime.tryParse(json['updated_at']) : null,
      claimedHomeName: json['claimed_home_name']?.toString(),
      claimedUserEmail: json['claimed_user_email']?.toString(),
      qrClaimUrl: json['qr_claim_url']?.toString() ??
          'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=${json['device_uuid']}',
    );
  }
}



