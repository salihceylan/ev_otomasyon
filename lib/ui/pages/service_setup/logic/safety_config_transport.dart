import 'package:flutter/foundation.dart';

import '../../../../models/json_utils.dart';
import '../../../../services/api_exception.dart';
import '../../../../services/clock.dart';
import '../../../../services/ev_cloud_api_service.dart';

// =============================================================================
// Güvenlik yapılandırması yazım taşıması (Faz 2 WP-C3; tasarım F2.D.5).
//
// Sihirbazın `buildSafetyPatches` planı TEK öğelik yamalardır; bu soyutlama onları panoya iletir:
//  * [LanSafetyConfigTransport]: bugünkü yerel yol (`GET/POST /api/safety/config`; davranış birebir aynı).
//  * [CloudSafetyConfigTransport]: sunucunun yapılandırma kopyası (`GET …/safety-config`) ve yama ucu
//    (`POST …/safety-config {base_rev, set|del, id}`). Pano çevrimdışıysa sunucu yamayı kuyruğa alır (`202 queued`).
//
// Seçim kuralı (K5: yerel öncelikli) ve LAN gevşetme reddinde bulut önerisi `RelayLogic`'tedir.
// =============================================================================

/// Bir yama dizisinin sonucu.
@immutable
class SafetyApplyResult {
  const SafetyApplyResult({
    required this.rev,
    this.queued = false,
    this.position,
    this.expiresAt,
    this.unconfirmed = false,
  });

  /// Son bilinen yapılandırma sürümü (kuyrukta / doğrulanmamışsa tahmini).
  final int rev;

  /// Pano çevrimdışı: yamalar sunucu kuyruğunda (24 sa içinde uygulanır). Adım tamamlanmış SAYILMAZ.
  final bool queued;
  final int? position;
  final DateTime? expiresAt;

  /// Pano 10 sn içinde yanıt vermedi (`202 applied:null`): sonuç state'te görünür; kalan yamalar gönderilmedi.
  final bool unconfirmed;

  bool get applied => !queued && !unconfirmed;
}

/// Sunucunun bekleyen yapılandırma kuyruğundaki öğe (`GET …/safety-config` `pending[]`; yalnız yetkiliye).
@immutable
class SafetyPendingItem {
  const SafetyPendingItem({required this.id, required this.op, required this.item, this.target, this.at, this.loosening = false});

  final String id;
  final String op;
  final String item;
  final String? target;
  final DateTime? at;
  final bool loosening;

  static SafetyPendingItem? fromJson(Object? raw) {
    final map = asMap(raw);
    final id = asNonEmptyString(map?['id']);
    if (map == null || id == null) return null;
    return SafetyPendingItem(
      id: id,
      op: asNonEmptyString(map['op']) ?? 'set',
      item: asNonEmptyString(map['item']) ?? '',
      target: asNonEmptyString(map['target']),
      at: asDate(map['at']),
      loosening: asBool(map['loosening']) ?? false,
    );
  }
}

/// Sunucunun pano başına çevrimdışı yapılandırma kuyruğu sınırı (`CONFIG_QUEUE_FULL`; guvenlik-4).
const int kMaxQueuedSafetyPatches = 16;

/// Çevrimdışı panoya gönderilecek plan kuyruğa sığmıyor (guvenlik-4): hiç gönderilmez (ya da kuyruğa giren ilk yama geri
/// alınır); plan yerel ağdan yazılmalıdır.
class SafetyQueueLimitExceeded implements Exception {
  const SafetyQueueLimitExceeded();

  String get message => 'Pano çevrimdışıyken en çok $kMaxQueuedSafetyPatches değişiklik sıraya alınabilir; yerel ağdan '
      'yazın.';

  @override
  String toString() => message;
}

/// Panodaki yapılandırma bu arada değişti (`409 CONFIG_CHANGED_ON_DEVICE` ya da LAN `cfg_conflict`, F2.D.3). [rev]
/// panonun bildirdiği güncel sürüm (bilinmiyorsa `null`). [rolledBack]: bu kayıtta kuyruğa alınan kısmi yamalar geri
/// alındı (çevrimdışı zincir geçersiz; guvenlik-4): kullanıcıya "iptal + yeniden gönder" sunulur, otomatik yeniden
/// deneme yapılmaz.
class SafetyConfigConflict implements Exception {
  const SafetyConfigConflict({this.rev, required this.message, this.rolledBack = false});

  final int? rev;
  final String message;
  final bool rolledBack;

  @override
  String toString() => message;
}

abstract class SafetyConfigTransport {
  /// Bulut yolu mu (arayüz metinleri: bölge testi sonucu yalnız LAN'da okunur, F2-10).
  bool get isCloud;

  /// Yapılandırma (`{rev, crc, sensors, actuators, lights, intrusion?…}`). Bulutta kopya en az [minRev]'e ve panonun son
  /// bildirdiği sürüme (`state_rev`) ulaşana kadar beklenir.
  Future<Map<String, dynamic>> read({int? minRev});

  /// Yamaları sırayla uygular (her biri bir öncekinin `rev`'iyle).
  Future<SafetyApplyResult> apply(List<Map<String, dynamic>> patches, {required int baseRev});
}

/// Yerel ağ yolu: mevcut `AutomationApiService` çağrıları (davranış birebir).
class LanSafetyConfigTransport implements SafetyConfigTransport {
  LanSafetyConfigTransport({required this.readConfig, required this.applyPatches});

  final Future<Map<String, dynamic>> Function() readConfig;
  final Future<({int rev, String? crc})> Function(List<Map<String, dynamic>> patches, int baseRev) applyPatches;

  @override
  bool get isCloud => false;

  @override
  Future<Map<String, dynamic>> read({int? minRev}) => readConfig();

  @override
  Future<SafetyApplyResult> apply(List<Map<String, dynamic>> patches, {required int baseRev}) async {
    final out = await applyPatches(patches, baseRev);
    return SafetyApplyResult(rev: out.rev);
  }
}

/// Bulut yolu (F2.D.1, D.2, D.5).
class CloudSafetyConfigTransport implements SafetyConfigTransport {
  CloudSafetyConfigTransport({
    required this.cloud,
    required this.homeId,
    required this.deviceId,
    required this.clock,
    required this.delay,
    this.copyWait = const Duration(seconds: 15),
    this.pollInterval = const Duration(seconds: 1),
  });

  final EvCloudApiService cloud;
  final String homeId;
  final String deviceId;
  final Clock clock;
  final Future<void> Function(Duration) delay;

  /// Kopyanın panonun `rev`'ine ulaşmasını bekleme sınırı (F2.D.3: en çok 15 sn).
  final Duration copyWait;
  final Duration pollInterval;

  int _seq = 0;

  /// Son okumanın bekleyen kuyruğu (yetkiliye; yoksa boş).
  List<SafetyPendingItem> pending = const <SafetyPendingItem>[];

  /// Kuyruk varsa yeni yamanın `base_rev`'i (sunucu `next_base_rev`).
  int? nextBaseRev;

  /// Pano sunucuda çevrimiçi mi (çağıranın en iyi çaba bilgisi; `null` = bilinmiyor). Çevrimdışı bilinen panoya kuyruk
  /// sınırını aşan plan hiç gönderilmez (guvenlik-4).
  bool? deviceOnline;

  @override
  bool get isCloud => true;

  /// Kopya henüz yok (`404` ya da `409 CONFIG_NOT_AVAILABLE`): sunucu `cfg_get` tetikledi; kopya gelene kadar yeniden okunur.
  static bool _copyMissing(ApiException e) =>
      e.statusCode == 404 || (e.statusCode == 409 && e.code == 'CONFIG_NOT_AVAILABLE');

  @override
  Future<Map<String, dynamic>> read({int? minRev}) async {
    final deadline = clock.now().add(copyWait);
    while (true) {
      final Map<String, dynamic> data;
      try {
        data = await cloud.safetyConfig(homeId, deviceId);
      } on ApiException catch (e) {
        // Boş (yapılandırılmamış) panonun kopyası ilk istekte yoktur (guvenlik-3): süre dolana kadar yeniden okunur.
        if (!_copyMissing(e) || !clock.now().add(pollInterval).isBefore(deadline)) rethrow;
        await delay(pollInterval);
        continue;
      }
      final rev = asInt(data['rev']);
      final stateRev = asInt(data['state_rev']);
      pending = <SafetyPendingItem>[
        for (final raw in asList(data['pending']) ?? const <dynamic>[])
          if (SafetyPendingItem.fromJson(raw) != null) SafetyPendingItem.fromJson(raw)!,
      ];
      nextBaseRev = asInt(data['next_base_rev']);
      // İstenen sürüm ile panonun son bildirdiği sürümün büyüğü: 409'daki rev bayat olabilir; plan, panonun güncel halinden
      // geride kalan kopyadan hesaplanmasın (Faz 2 incelemesi R3).
      final want = (minRev != null && stateRev != null) ? (minRev > stateRev ? minRev : stateRev) : (minRev ?? stateRev);
      // Kopya panonun bildirdiği sürüme ulaştı (ya da sunucu state_rev yazmıyor: eski sunucu).
      if (want == null || (rev != null && rev >= want)) return data;
      if (!clock.now().add(pollInterval).isBefore(deadline)) {
        throw const ApiException(
          statusCode: 409,
          code: 'CONFIG_NOT_AVAILABLE',
          message: 'Pano yapılandırması okunuyor… Biraz sonra yeniden deneyin.',
        );
      }
      await delay(pollInterval);
    }
  }

  @override
  Future<SafetyApplyResult> apply(List<Map<String, dynamic>> patches, {required int baseRev}) async {
    final pendingAtStart = pending.length;
    final room = kMaxQueuedSafetyPatches - pendingAtStart;
    // Çevrimdışı bilinen panoya sığmayan plan hiç gönderilmez (guvenlik-4).
    if (deviceOnline == false && patches.length > room) throw const SafetyQueueLimitExceeded();
    var rev = baseRev;
    var queued = false;
    var queuedInRun = 0;
    int? position;
    DateTime? expiresAt;
    for (final patch in patches) {
      Map<String, dynamic> res;
      try {
        res = await cloud.patchSafetyConfig(
          homeId: homeId,
          deviceId: deviceId,
          baseRev: rev,
          patch: patch,
          commandId: _commandId(),
        );
      } on ApiException catch (e) {
        // Zincir ortasında hata (kuyruk dolu, bekleyen var, zincir geçersiz, ağ ...): bu kayıtta kuyruğa giren kısmi plan
        // geri alınır (yarım plan pano bağlanınca uygulanmasın; guvenlik-4).
        final rolledBack = await _rollbackPartial(queuedInRun, pendingAtStart);
        if (e.statusCode == 409 && e.code == 'CONFIG_CHANGED_ON_DEVICE') {
          final data = asMap(e.details?['data']) ?? e.details;
          throw SafetyConfigConflict(rev: asInt(data?['rev']), message: e.message, rolledBack: rolledBack);
        }
        rethrow;
      }
      if (asBool(res['queued']) == true) {
        // Pano çevrimdışı: kuyruk zinciri `base_rev + 1` ile sürer (F2.D.2).
        queued = true;
        queuedInRun++;
        position = asInt(res['position']) ?? position;
        expiresAt = asDate(res['expires_at']) ?? expiresAt;
        rev += 1;
        if (queuedInRun == 1 && patches.length > room) {
          // Pano çevrimdışı çıktı ve plan kuyruğa sığmıyor: kuyruğa giren ilk yama geri alınır (guvenlik-4).
          await _rollbackPartial(queuedInRun, pendingAtStart);
          throw const SafetyQueueLimitExceeded();
        }
        continue;
      }
      if (asBool(res['applied']) == true) {
        rev = asInt(res['rev']) ?? rev + 1;
        continue;
      }
      // `202 applied:null`: pano yanıtı gecikti; zincirin geri kalanı bilinmeyen `rev` ile gönderilmez.
      return SafetyApplyResult(rev: rev, unconfirmed: true);
    }
    return SafetyApplyResult(rev: rev, queued: queued, position: position, expiresAt: expiresAt);
  }

  /// Bu çağrıda kuyruğa alınan yamaları geri alır (`DELETE …/safety-config/pending`). Yalnız kuyruk bu kayıt başlarken
  /// boşsa (başkasının bekleyen değişikliği silinmez). En iyi çaba: silinemezse `false`.
  Future<bool> _rollbackPartial(int queuedInRun, int pendingAtStart) async {
    if (queuedInRun == 0 || pendingAtStart > 0) return false;
    try {
      await cloud.clearSafetyConfigPending(homeId, deviceId);
      return true;
    } on Exception {
      return false;
    }
  }

  String _commandId() {
    _seq++;
    final t = clock.now().microsecondsSinceEpoch.toRadixString(36);
    final id = 'cfg$t$_seq';
    return id.length > 24 ? id.substring(id.length - 24) : id;
  }
}
