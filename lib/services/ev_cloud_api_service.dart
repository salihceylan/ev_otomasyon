import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/cloud_models.dart';

class EvCloudApiService {
  static final EvCloudApiService _instance = EvCloudApiService._internal();

  factory EvCloudApiService({String? baseUrl}) {
    if (baseUrl != null) {
      _instance.baseUrl = baseUrl;
    }
    return _instance;
  }

  EvCloudApiService._internal();

  String baseUrl = 'https://evotomasyon.gudeteknoloji.com.tr/api';
  String? _authToken;
  String? _refreshToken;

  /// Token yenilendiğinde dinleyicileri (SecureStorage) bilgilendirmek için geri çağrı
  void Function(String newAccessToken, String? newRefreshToken)? onTokenRefreshed;

  void setAuthToken(String? token) {
    _authToken = token;
  }

  void setRefreshToken(String? token) {
    _refreshToken = token;
  }

  String? get authToken => _authToken;
  String? get currentRefreshToken => _refreshToken;

  Map<String, String> get _headers {
    final map = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_authToken != null) {
      map['Authorization'] = 'Bearer $_authToken';
    }
    return map;
  }

  /// 401 Unauthorized veya 403 Durumunda sessizce token tazeleyip isteği tekrarlayan koruma
  Future<http.Response> _authenticatedRequest(Future<http.Response> Function() requestFn) async {
    var res = await requestFn();
    if ((res.statusCode == 401 || res.statusCode == 403) && _refreshToken != null && _refreshToken!.isNotEmpty) {
      try {
        final refreshData = await refreshToken();
        final newAccess = refreshData['access_token'] as String?;
        if (newAccess != null && newAccess.isNotEmpty) {
          res = await requestFn();
        }
      } catch (_) {
        // Sessiz yenileme başarısız olduysa orijinal yanıtı döndür
      }
    }
    return res;
  }

  /// Normal Kullanıcı Girişi (Ev Sahibi / Sakin - E-posta veya Telefon)
  Future<Map<String, dynamic>> login(String identifier, String password) async {
    final uri = Uri.parse('$baseUrl/v1/auth/login');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'identifier': identifier, 'password': password}),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final token = (payload['access_token'] ?? payload['token']) as String;
      setAuthToken(token);
      if (payload['refresh_token'] != null) {
        setRefreshToken(payload['refresh_token'] as String);
      }
      return payload;
    }
    throw Exception(data['message'] ?? 'Giriş başarısız (Kod: ${res.statusCode})');
  }

  /// Yeni Kullanıcı Kaydı (Register)
  Future<Map<String, dynamic>> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/auth/register');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'full_name': fullName,
        'email': email,
        'password': password,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      }),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if ((res.statusCode == 200 || res.statusCode == 201) &&
        (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final token = (payload['access_token'] ?? payload['token']) as String;
      setAuthToken(token);
      if (payload['refresh_token'] != null) {
        setRefreshToken(payload['refresh_token'] as String);
      }
      return payload;
    }
    throw Exception(data['message'] ?? 'Kayıt başarısız (Kod: ${res.statusCode})');
  }

  /// ADIM 18: Google Sign-In
  Future<Map<String, dynamic>> loginWithGoogle({
    String? idToken,
    String? email,
    String? name,
    String? googleId,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/auth/google');
    final payloadMap = <String, dynamic>{};
    if (idToken != null) payloadMap['id_token'] = idToken;
    if (email != null) payloadMap['email'] = email;
    if (name != null) payloadMap['name'] = name;
    if (googleId != null) payloadMap['google_id'] = googleId;

    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payloadMap),
    ).timeout(const Duration(seconds: 10));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final token = (payload['access_token'] ?? payload['token']) as String;
      setAuthToken(token);
      if (payload['refresh_token'] != null) {
        setRefreshToken(payload['refresh_token'] as String);
      }
      return payload;
    }
    throw Exception(data['message'] ?? 'Google ile giriş başarısız (Kod: ${res.statusCode})');
  }

  /// ADIM 18: Sign in with Apple
  Future<Map<String, dynamic>> loginWithApple({
    String? identityToken,
    required String userId,
    String? email,
    String? name,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/auth/apple');
    final payloadMap = <String, dynamic>{'user_id': userId};
    if (identityToken != null) payloadMap['identity_token'] = identityToken;
    if (email != null) payloadMap['email'] = email;
    if (name != null) payloadMap['name'] = name;

    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payloadMap),
    ).timeout(const Duration(seconds: 10));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final token = (payload['access_token'] ?? payload['token']) as String;
      setAuthToken(token);
      if (payload['refresh_token'] != null) {
        setRefreshToken(payload['refresh_token'] as String);
      }
      return payload;
    }
    throw Exception(data['message'] ?? 'Apple ile giriş başarısız (Kod: ${res.statusCode})');
  }

  /// ADIM 18: Telefon OTP Kodu Gönder
  Future<Map<String, dynamic>> sendPhoneOtp(String phone) async {
    final uri = Uri.parse('$baseUrl/v1/auth/otp/send');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone.trim()}),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Doğrulama kodu gönderilemedi (Kod: ${res.statusCode})');
  }

  /// ADIM 18: Telefon OTP Kodu Doğrula ve Giriş Yap
  Future<Map<String, dynamic>> verifyPhoneOtp(String phone, String code) async {
    final uri = Uri.parse('$baseUrl/v1/auth/otp/verify');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone.trim(), 'code': code.trim()}),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final token = (payload['access_token'] ?? payload['token']) as String;
      setAuthToken(token);
      if (payload['refresh_token'] != null) {
        setRefreshToken(payload['refresh_token'] as String);
      }
      return payload;
    }
    throw Exception(data['message'] ?? 'Doğrulama başarısız (Kod: ${res.statusCode})');
  }

  /// JWT Refresh Token ile Sessiz Oturum Tazeleme (Silent Token Refresh)
  Future<Map<String, dynamic>> refreshToken({String? token}) async {
    final tokenToSend = token ?? _refreshToken;
    if (tokenToSend == null || tokenToSend.isEmpty) {
      throw Exception('Refresh token bulunamadı');
    }

    final uri = Uri.parse('$baseUrl/v1/auth/refresh');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': tokenToSend}),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final newAccessToken = (payload['access_token'] ?? payload['token']) as String;
      final newRefreshToken = payload['refresh_token'] as String?;

      setAuthToken(newAccessToken);
      if (newRefreshToken != null && newRefreshToken.isNotEmpty) {
        setRefreshToken(newRefreshToken);
      }

      onTokenRefreshed?.call(newAccessToken, newRefreshToken ?? tokenToSend);
      return payload;
    }
    throw Exception(data['message'] ?? 'Oturum yenilenemedi');
  }

  /// ADIM 20: Şifre Sıfırlama Talebi (OTP & Magic Link Üret)
  Future<Map<String, dynamic>> forgotPassword(String identifier) async {
    final uri = Uri.parse('$baseUrl/v1/auth/forgot-password');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'identifier': identifier.trim()}),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Şifre sıfırlama kodu gönderilemedi');
  }

  /// ADIM 20: OTP Kodu / Magic Token ile Yeni Şifre Belirleme & Otomatik Giriş
  Future<Map<String, dynamic>> resetPassword({
    required String identifier,
    String? otpCode,
    String? code,
    String? token,
    required String newPassword,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/auth/reset-password');
    final payloadMap = <String, dynamic>{
      'identifier': identifier.trim(),
      'code': (code ?? otpCode ?? '').trim(),
      'new_password': newPassword.trim(),
    };
    if (token != null && token.isNotEmpty) {
      payloadMap['token'] = token.trim();
    }

    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payloadMap),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      if (payload['access_token'] != null || payload['token'] != null) {
        final authToken = (payload['access_token'] ?? payload['token']) as String;
        setAuthToken(authToken);
        if (payload['refresh_token'] != null) {
          setRefreshToken(payload['refresh_token'] as String);
        }
      }
      return payload;
    }
    throw Exception(data['message'] ?? 'Şifre sıfırlanamadı');
  }

  /// ADIM 20: Sihirli Bağlantı (Magic Link) ile Tek Tıkla Giriş
  Future<Map<String, dynamic>> magicLogin(String token) async {
    final uri = Uri.parse('$baseUrl/v1/auth/magic-login/${token.trim()}');
    final res = await http.get(
      uri,
      headers: {'Content-Type': 'application/json'},
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final authToken = (payload['access_token'] ?? payload['token']) as String;
      setAuthToken(authToken);
      if (payload['refresh_token'] != null) {
        setRefreshToken(payload['refresh_token'] as String);
      }
      return payload;
    }
    throw Exception(data['message'] ?? 'Sihirli bağlantı geçersiz veya süresi dolmuş');
  }

  /// Sunucu Tarafında Oturum Kapatma (Refresh Token İptali)
  Future<void> logout() async {
    try {
      if (_refreshToken != null) {
        final uri = Uri.parse('$baseUrl/v1/auth/logout');
        await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': _refreshToken}),
        ).timeout(const Duration(seconds: 4));
      }
    } catch (_) {}
    setAuthToken(null);
    setRefreshToken(null);
  }

  /// 6 Haneli Servis PIN'i ile Yetkili Servis Girişi
  Future<Map<String, dynamic>> serviceLogin(String servicePin) async {
    final uri = Uri.parse('$baseUrl/v1/auth/service-login');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'service_pin': servicePin}),
    ).timeout(const Duration(seconds: 8));

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && (data['status'] == 'success' || data['success'] == true)) {
      final payload = (data['data'] as Map<String, dynamic>?) ?? data;
      final token = (payload['access_token'] ?? payload['token']) as String;
      setAuthToken(token);
      return payload;
    }
    throw Exception(data['message'] ?? 'Servis PIN geçersiz veya süresi dolmuş');
  }

  /// Kullanıcının yetkili olduğu daireleri listeleme
  Future<List<HomeModel>> fetchHomes() async {
    final uri = Uri.parse('$baseUrl/homes');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    if (res.statusCode == 200) {
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = (json['data'] as List<dynamic>?) ?? [];
      return list.map((h) => HomeModel.fromJson(h as Map<String, dynamic>)).toList();
    }
    throw Exception('Ev listesi alınamadı (Kod: ${res.statusCode})');
  }

  /// Bir daireye ait tüm uç noktaları (röle, lamba, panjur) listeleme
  Future<List<EndpointModel>> fetchEndpoints(int homeId) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/endpoints');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    if (res.statusCode == 200) {
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = (json['data'] as List<dynamic>?) ?? [];
      return list.map((e) => EndpointModel.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception('Uç noktalar alınamadı (Kod: ${res.statusCode})');
  }

  /// Uç nokta kontrolü (REST üzerinden komut gönderme)
  Future<bool> controlEndpoint(int homeId, int endpointId, String command, {dynamic value}) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/endpoints/$endpointId/control');
    final body = <String, dynamic>{'command': command};
    if (value != null) body['value'] = value;

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 6)),
    );

    return res.statusCode == 200;
  }

  /// Cihaz Sahiplenme & Devreye Alma (Device Claiming - Setup PIN ile)
  Future<Map<String, dynamic>> claimDevice({
    required String deviceUuid,
    required String setupPin,
    int? homeId,
    String? homeName,
    String? targetOwner,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/devices/claim');
    final body = <String, dynamic>{
      'device_uuid': deviceUuid,
      'setup_pin': setupPin,
    };
    if (homeId != null) body['home_id'] = homeId;
    if (homeName != null) body['home_name'] = homeName;
    if (targetOwner != null && targetOwner.isNotEmpty) body['target_owner'] = targetOwner;

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 || res.statusCode == 201) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Cihaz sahiplenilemedi (Kod: ${res.statusCode})');
  }

  /// Yetkili Servis Sorumlusu: Sistemi test edip "Çalışır" olarak onaylama ve devreye alma (Commissioning)
  Future<Map<String, dynamic>> commissionSystem(int homeId, {String? notes, bool testsPassed = true}) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/commissioning');
    final res = await _authenticatedRequest(
      () => http.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'notes': notes ?? 'Sistem klemens eşlemeleri ve panjur kalibrasyonları test edildi. Sistem çalışır durumda teslim edildi.',
          'tests_passed': testsPassed,
        }),
      ).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Sistem devreye alma onayı verilemedi');
  }

  /// Dairenin devreye alma ve servis onay durumunu sorgulama
  Future<Map<String, dynamic>> getCommissioningStatus(int homeId) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/commissioning-status');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Devreye alma durumu sorgulanamadı');
  }

  /// Uç Nokta Bilgilerini Güncelleme (Oda, İsim, Tip, Panjur Motor Süresi)
  Future<Map<String, dynamic>> updateEndpoint({
    required int homeId,
    required int endpointId,
    String? name,
    String? room,
    String? type,
    int? shutterDurationSec,
  }) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/endpoints/$endpointId');
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (room != null) body['room'] = room;
    if (type != null) body['type'] = type;
    if (shutterDurationSec != null) body['shutter_duration_sec'] = shutterDurationSec;

    final res = await _authenticatedRequest(
      () => http.put(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Kontrol noktası güncellenemedi');
  }

  /// Ev Sahibi: Yetkili Servis Sorumlusu için 2 saatlik servis PIN'i oluşturma
  Future<ServiceTokenModel> createServiceToken(int homeId, {int durationHours = 2}) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/service-token');
    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode({'duration_hours': durationHours})).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 201) {
      return ServiceTokenModel.fromJson(data['data'] as Map<String, dynamic>);
    }
    throw Exception(data['message'] ?? 'Servis PIN üretilemedi');
  }

  /// Ev Sahibi: Aile bireyi için veya süreli misafir için davet kodu / QR oluşturma
  Future<Map<String, dynamic>> createInvitation(
    int homeId, {
    String role = 'member',
    int? durationHours,
    String? validFrom,
    String? validUntil,
    String? guestName,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/homes/$homeId/invitations');
    final body = <String, dynamic>{'role': role};
    if (durationHours != null) body['durationHours'] = durationHours;
    if (validFrom != null) body['validFrom'] = validFrom;
    if (validUntil != null) body['validUntil'] = validUntil;
    if (guestName != null) body['guestName'] = guestName;

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 201) {
      return (data['invitation'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? data['error'] ?? 'Davet kodu üretilemedi (Kod: ${res.statusCode})');
  }

  /// Aile Bireyi / Misafir: Davet koduyla veya QR ile eve katılma
  Future<Map<String, dynamic>> joinHome(String code) async {
    final uri = Uri.parse('$baseUrl/v1/homes/join');
    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode({'code': code})).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return data;
    }
    throw Exception(data['message'] ?? data['error'] ?? 'Eve katılma başarısız (Kod: ${res.statusCode})');
  }

  /// Ev Sahibi: Evdeki tüm aile bireylerini ve süreli misafirleri listeleme
  Future<List<Map<String, dynamic>>> getHomeMembers(int homeId) async {
    final uri = Uri.parse('$baseUrl/v1/homes/$homeId/members');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && data['success'] == true) {
      final list = (data['members'] as List<dynamic>?) ?? [];
      return list.map((m) => m as Map<String, dynamic>).toList();
    }
    throw Exception(data['message'] ?? 'Üyeler listelenemedi');
  }

  /// Ev Sahibi: Bir üyenin veya misafirin yetkisini iptal etme / evden çıkarma
  Future<bool> removeHomeMember(int homeId, int targetUserId) async {
    final uri = Uri.parse('$baseUrl/v1/homes/$homeId/members/$targetUserId');
    final res = await _authenticatedRequest(
      () => http.delete(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return true;
    }
    throw Exception(data['message'] ?? data['error'] ?? 'Üye silinemedi');
  }

  /// ADIM 13: Ev Sahibi - Daire Devir Sürecini Başlatma (48 saat geçerli kod üretir)
  Future<Map<String, dynamic>> initiateTransfer(dynamic homeId, {String? targetIdentifier}) async {
    final uri = Uri.parse('$baseUrl/v1/homes/$homeId/transfer-initiate');
    final body = <String, dynamic>{};
    if (targetIdentifier != null && targetIdentifier.trim().isNotEmpty) {
      body['target_identifier'] = targetIdentifier.trim();
    }

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 || res.statusCode == 201) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Daire devir kodu üretilemedi (Kod: ${res.statusCode})');
  }

  /// ADIM 13: Yeni Kullanıcı - Devir Kodunu Kabul Etme ve Daireyi Devralma
  Future<Map<String, dynamic>> acceptTransfer(String transferCode) async {
    final uri = Uri.parse('$baseUrl/v1/homes/transfer-accept');
    final res = await _authenticatedRequest(
      () => http.post(
        uri,
        headers: _headers,
        body: jsonEncode({'transfer_code': transferCode.trim()}),
      ).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Daire devralma işlemi başarısız (Kod: ${res.statusCode})');
  }

  /// ADIM 13: Ev Sahibi - Daire Devir Durumunu Sorgulama
  Future<Map<String, dynamic>?> getTransferStatus(dynamic homeId) async {
    final uri = Uri.parse('$baseUrl/v1/homes/$homeId/transfer-status');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && data['success'] == true) {
      final inner = data['data'] as Map<String, dynamic>?;
      return inner?['pendingTransfer'] as Map<String, dynamic>?;
    }
    return null;
  }

  /// ADIM 13: Ev Sahibi - Devir İşlemini İptal Etme
  Future<bool> cancelTransfer(dynamic homeId) async {
    final uri = Uri.parse('$baseUrl/v1/homes/$homeId/transfer-cancel');
    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return true;
    }
    throw Exception(data['message'] ?? 'Devir işlemi iptal edilemedi');
  }

  /// ADIM 13: Yetkili Servis Sorumlusu / Acil Sıfırlama - Cihazı Sıfırlama / Yeni Malik Atama
  Future<Map<String, dynamic>> emergencyResetDevice({
    required String deviceUuid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/devices/emergency-reset');
    final body = <String, dynamic>{
      'device_uuid': deviceUuid.trim(),
      'reason': reason.trim(),
    };
    if (newOwnerIdentifier != null && newOwnerIdentifier.trim().isNotEmpty) {
      body['new_owner_identifier'] = newOwnerIdentifier.trim();
    }

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Acil servis sıfırlama işlemi başarısız (Kod: ${res.statusCode})');
  }

  /// ADIM 16: Sistem Doktoru (Self-Diagnostic) Raporu Çekme
  Future<Map<String, dynamic>> fetchSystemDiagnostic(dynamic homeId) async {
    final uri = Uri.parse('$baseUrl/v1/devices/diagnostic/$homeId');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Sistem teşhis raporu alınamadı (Kod: ${res.statusCode})');
  }

  /// ADIM 16: Felaket Kurtarma (Disaster Recovery) - Tek Tıkla Pano Değişimi
  Future<Map<String, dynamic>> replaceBoard({
    required dynamic homeId,
    String? oldDeviceUuid,
    required String newDeviceUuid,
    required String setupPin,
    String? reason,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/devices/replace-board');
    final body = <String, dynamic>{
      'home_id': homeId,
      'new_device_uuid': newDeviceUuid.trim().toUpperCase(),
      'setup_pin': setupPin.trim(),
    };
    if (oldDeviceUuid != null && oldDeviceUuid.trim().isNotEmpty) {
      body['old_device_uuid'] = oldDeviceUuid.trim().toUpperCase();
    }
    if (reason != null && reason.trim().isNotEmpty) {
      body['reason'] = reason.trim();
    }

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 12)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Pano değişimi işlemi başarısız (Kod: ${res.statusCode})');
  }

  /// ADIM 17: Çocuk Kilidi Aç/Kapa
  Future<Map<String, dynamic>> setChildLock({required dynamic homeId, required bool enabled}) async {
    final uri = Uri.parse('$baseUrl/v1/devices/child-lock');
    final body = <String, dynamic>{
      'home_id': homeId,
      'enabled': enabled,
    };

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Çocuk kilidi güncellenemedi (Kod: ${res.statusCode})');
  }

  /// ADIM 17: Çocuk Kilidi Durumunu Oku
  Future<bool> getChildLock(dynamic homeId) async {
    final uri = Uri.parse('$baseUrl/v1/devices/child-lock/$homeId');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    if (res.statusCode == 200) {
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final data = (json['data'] as Map<String, dynamic>?) ?? json;
      return data['child_lock_enabled'] == true;
    }
    return false;
  }

  /// ADIM 17: Gece Huzur Bildirimi Durumu ve Açık Lambaları Oku
  Future<Map<String, dynamic>> getPeaceNotification(dynamic homeId) async {
    final uri = Uri.parse('$baseUrl/v1/devices/peace-notification/$homeId');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Gece huzur bildirimi durumu alınamadı (Kod: ${res.statusCode})');
  }

  /// ADIM 17: Gece Huzur Bildirimi Ayarlarını Güncelle
  Future<Map<String, dynamic>> updatePeaceNotification(dynamic homeId, {bool? enabled, String? notificationTime}) async {
    final uri = Uri.parse('$baseUrl/v1/devices/peace-notification/$homeId');
    final body = <String, dynamic>{};
    if (enabled != null) body['enabled'] = enabled;
    if (notificationTime != null) body['notification_time'] = notificationTime;

    final res = await _authenticatedRequest(
      () => http.put(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Huzur bildirimi ayarları kaydedilemedi (Kod: ${res.statusCode})');
  }

  /// ADIM 17: Açık Lambaları Tek Tıkla Kapat
  Future<Map<String, dynamic>> closeAllOpenLights(dynamic homeId) async {
    final uri = Uri.parse('$baseUrl/v1/devices/peace-notification/close-all');
    final body = <String, dynamic>{'home_id': homeId};

    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Lambalar kapatılamadı (Kod: ${res.statusCode})');
  }

  // ── ADIM 18: Zamanlı Otomasyon Kuralları ─────────────────────────────────

  /// Evin zamanlı kurallarını listele
  Future<Map<String, dynamic>> getScheduledRules(int homeId) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/scheduled-rules');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return data;
    throw Exception(data['error'] ?? 'Kurallar alınamadı (Kod: ${res.statusCode})');
  }

  /// Yeni kural oluştur
  Future<Map<String, dynamic>> createScheduledRule(int homeId, Map<String, dynamic> ruleData) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/scheduled-rules');
    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(ruleData)).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 201) return data;
    throw Exception(data['error'] ?? 'Kural oluşturulamadı (Kod: ${res.statusCode})');
  }

  /// Kural güncelle
  Future<Map<String, dynamic>> updateScheduledRule(int homeId, int ruleId, Map<String, dynamic> updates) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/scheduled-rules/$ruleId');
    final res = await _authenticatedRequest(
      () => http.put(uri, headers: _headers, body: jsonEncode(updates)).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return data;
    throw Exception(data['error'] ?? 'Kural güncellenemedi (Kod: ${res.statusCode})');
  }

  /// Kural sil
  Future<void> deleteScheduledRule(int homeId, int ruleId) async {
    final uri = Uri.parse('$baseUrl/homes/$homeId/scheduled-rules/$ruleId');
    final res = await _authenticatedRequest(
      () => http.delete(uri, headers: _headers).timeout(const Duration(seconds: 10)),
    );
    if (res.statusCode != 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      throw Exception(data['error'] ?? 'Kural silinemedi (Kod: ${res.statusCode})');
    }
  }

  // ===========================================================================
  // SÜPER YÖNETİCİ & SERVİS SORUMLUSU YÖNETİMİ (ADIM 19)
  // ===========================================================================

  /// Kullanıcı listesini getir (rol, arama, aktiflik)
  Future<Map<String, dynamic>> listAdminUsers({
    String? role,
    String? search,
    bool? isActive,
    int limit = 50,
    int offset = 0,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (role != null && role.isNotEmpty) queryParams['role'] = role;
    if (search != null && search.isNotEmpty) queryParams['search'] = search;
    if (isActive != null) queryParams['is_active'] = isActive.toString();

    final uri = Uri.parse('$baseUrl/admin/users').replace(queryParameters: queryParams);
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return data['data'] ?? data;
    throw Exception(data['message'] ?? data['error'] ?? 'Kullanıcı listesi alınamadı (${res.statusCode})');
  }

  /// Yeni kullanıcı oluştur (super_user, service_user, user)
  Future<Map<String, dynamic>> createAdminUser({
    required String fullName,
    required String email,
    required String password,
    String? phone,
    required String role,
    String? adminNotes,
  }) async {
    final uri = Uri.parse('$baseUrl/admin/users');
    final body = {
      'full_name': fullName,
      'email': email,
      'password': password,
      'phone': phone,
      'role': role,
      'admin_notes': adminNotes,
    };
    final res = await _authenticatedRequest(
      () => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 201 || res.statusCode == 200) return data['data'] ?? data;
    throw Exception(data['message'] ?? data['error'] ?? 'Kullanıcı oluşturulamadı (${res.statusCode})');
  }

  /// Kullanıcı bilgilerini güncelle
  Future<Map<String, dynamic>> updateAdminUser(
    String userId, {
    String? fullName,
    String? phone,
    String? role,
    String? password,
    bool? isActive,
    String? adminNotes,
  }) async {
    final uri = Uri.parse('$baseUrl/admin/users/$userId');
    final body = <String, dynamic>{};
    if (fullName != null) body['full_name'] = fullName;
    if (phone != null) body['phone'] = phone;
    if (role != null) body['role'] = role;
    if (password != null && password.isNotEmpty) body['password'] = password;
    if (isActive != null) body['is_active'] = isActive;
    if (adminNotes != null) body['admin_notes'] = adminNotes;

    final res = await _authenticatedRequest(
      () => http.patch(uri, headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return data['data'] ?? data;
    throw Exception(data['message'] ?? data['error'] ?? 'Kullanıcı güncellenemedi (${res.statusCode})');
  }

  /// Kullanıcıyı sil veya pasife al
  Future<Map<String, dynamic>> deleteAdminUser(String userId, {bool hard = false}) async {
    final uri = Uri.parse('$baseUrl/admin/users/$userId?hard=$hard');
    final res = await _authenticatedRequest(
      () => http.delete(uri, headers: _headers).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return data;
    throw Exception(data['message'] ?? data['error'] ?? 'Kullanıcı silinemedi (${res.statusCode})');
  }

  /// Servis özet istatistiklerini getir
  Future<Map<String, dynamic>> getServiceSummary() async {
    final uri = Uri.parse('$baseUrl/admin/service-summary');
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _headers).timeout(const Duration(seconds: 10)),
    );
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return data['data'] ?? data;
    throw Exception(data['message'] ?? data['error'] ?? 'Servis özeti alınamadı (${res.statusCode})');
  }

  Map<String, String> get _adminHeaders {
    final map = Map<String, String>.from(_headers);
    map['x-admin-api-key'] = 'GudeAdminInventoryKey2026_SecretProvisioning';
    return map;
  }

  /// Cihaz Envanterini Listeleme (Süper & Servis Yöneticisi)
  Future<Map<String, dynamic>> fetchDeviceInventory({
    String? status,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async {
    final params = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (status != null && status.isNotEmpty && status.toUpperCase() != 'ALL') {
      params['status'] = status.toUpperCase();
    }
    if (search != null && search.trim().isNotEmpty) {
      params['search'] = search.trim();
    }

    final uri = Uri.parse('$baseUrl/v1/admin/inventory').replace(queryParameters: params);
    final res = await _authenticatedRequest(
      () => http.get(uri, headers: _adminHeaders).timeout(const Duration(seconds: 10)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && data['success'] == true) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Cihaz envanteri alınamadı (${res.statusCode})');
  }

  /// Cihaz Durumunu Güncelleme (Askıya Al / Aktif Et / İptal)
  Future<Map<String, dynamic>> updateInventoryDeviceStatus(String uuid, String status) async {
    final uri = Uri.parse('$baseUrl/v1/admin/inventory/$uuid/status');
    final res = await _authenticatedRequest(
      () => http.patch(
        uri,
        headers: _adminHeaders,
        body: jsonEncode({'status': status}),
      ).timeout(const Duration(seconds: 10)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && data['success'] == true) {
      return (data['data'] as Map<String, dynamic>?) ?? data;
    }
    throw Exception(data['message'] ?? 'Cihaz durumu güncellenemedi (${res.statusCode})');
  }

  /// Cihazı Envanterden Silme (Süper Yönetici)
  Future<bool> deleteInventoryDevice(String uuid) async {
    final uri = Uri.parse('$baseUrl/v1/admin/inventory/$uuid');
    final res = await _authenticatedRequest(
      () => http.delete(uri, headers: _adminHeaders).timeout(const Duration(seconds: 10)),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200 && data['success'] == true) {
      return true;
    }
    throw Exception(data['message'] ?? 'Cihaz silinemedi (${res.statusCode})');
  }
}
