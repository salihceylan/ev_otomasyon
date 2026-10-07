import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/api_models.dart';
import '../models/automation_models.dart';
import 'api_exception.dart';
import 'automation_api_service.dart';
import 'clock.dart';

/// Komutun neden geri alındığı.
enum CommandFailureReason {
  /// Cihaz çevrimdışı (`409 DEVICE_OFFLINE` / `device_online=false`).
  offline,

  /// REST yanıtı `delivered=false`.
  notDelivered,

  /// 2.5 sn içinde cihazdan `state` onayı gelmedi.
  timeout,

  /// Sunucuya / cihaza ulaşılamadı.
  network,

  /// Yetki yok (403 / 401 / yerel anahtar reddi).
  forbidden,

  /// Hız sınırı (429 / 423).
  rateLimited,

  /// MQTT broker'a yayın yapılamadı (502).
  brokerUnavailable,

  /// Girdi geçersiz (400).
  validation,

  /// Diğer sunucu/cihaz reddi.
  rejected,
}

/// Geri alınan bir komutun bilgisi: arayüz bunu snackbar olarak gösterir.
class CommandFailure {
  const CommandFailure({
    required this.key,
    required this.reason,
    required this.message,
    this.error,
    this.code,
  });

  /// Uç nokta anahtarı (`relay:3`, `shutter:2`, `childLock`, `group:all_lights_off` ...).
  final String key;
  final CommandFailureReason reason;

  /// Kullanıcıya gösterilebilir Türkçe mesaj.
  final String message;
  final Object? error;

  /// Panonun ret kodu (`state.last_rej.code`, LAN `rej`/hata kodu; ör. `zone_latched`, `gas_local_only`) ya da
  /// sunucunun güvenlik hata kodu (`ZONE_ALARM_ACTIVE` ...). Arayüz koda göre yönlendirme yapabilir.
  final String? code;

  /// Bir istisnadan sınıflandırılmış hata üretir (bulut [ApiException] / yerel [LocalApiException]).
  factory CommandFailure.fromError(String key, Object error) {
    if (error is ApiException) {
      if (error.isDeviceOffline) {
        // Alarm onayı çevrimdışı panoya kuyruğa alındı (sunucu `ack_queued:true`; CONTRACTS §1.5d).
        final queued = error.details?['ack_queued'] == true;
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.offline,
          message: queued
              ? 'Pano çevrimdışı. Onay, pano bağlanınca (aynı alarm sürüyorsa) iletilecek.'
              : 'Cihaz çevrimdışı. Komut iletilemedi.',
          error: error,
        );
      }
      if (error.statusCode == 409 && error.code == 'DEVICE_REJECTED') {
        // Pano komutu reddetti; `reason` firmware ret kodudur (`zone_latched`, `stale_ack` ...; CONTRACTS §1.5d).
        final reason = error.reason?.toLowerCase();
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.rejected,
          message: safetyRejectMessage(reason),
          error: error,
          code: reason ?? error.code,
        );
      }
      if (error.isNetwork) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.network,
          message: 'Sunucuya ulaşılamadı. İşlem geri alındı.',
          error: error,
        );
      }
      if (error.isForbidden || error.isUnauthorized) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.forbidden,
          message: error.message,
          error: error,
        );
      }
      if (error.isRateLimited || error.isPinLocked) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.rateLimited,
          message: error.message,
          error: error,
        );
      }
      if (error.isBrokerUnavailable) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.brokerUnavailable,
          message: 'Sunucu cihaza şu an ulaşamıyor. Lütfen tekrar deneyin.',
          error: error,
        );
      }
      if (error.statusCode == 400 || error.statusCode == 422) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.validation,
          message: error.message,
          error: error,
        );
      }
      final safetyMessage = error.statusCode == 409 ? _serverSafetyMessages[error.code] : null;
      return CommandFailure(
        key: key,
        reason: CommandFailureReason.rejected,
        message: safetyMessage ?? (error.isServerError ? 'Komut gönderilemedi. Lütfen tekrar deneyin.' : error.message),
        error: error,
        code: error.code,
      );
    }
    if (error is LocalApiException) {
      if (error.isNetwork || error.statusCode == 0) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.network,
          message: 'Cihaza ulaşılamadı. İşlem geri alındı.',
          error: error,
        );
      }
      if (error.isUnauthorized) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.forbidden,
          message: error.message,
          error: error,
        );
      }
      if (error.isLocked || error.statusCode == 429) {
        return CommandFailure(
          key: key,
          reason: CommandFailureReason.rateLimited,
          message: error.message,
          error: error,
        );
      }
      return CommandFailure(
        key: key,
        reason: CommandFailureReason.rejected,
        message: error.message,
        error: error,
        code: error.code,
      );
    }
    return CommandFailure(
      key: key,
      reason: CommandFailureReason.rejected,
      message: 'Komut gönderilemedi.',
      error: error,
    );
  }
}

/// Sunucunun güvenlik komutu ret kodları (tasarım §5.2.4) -> Türkçe metin (409).
const Map<String, String> _serverSafetyMessages = <String, String>{
  'ZONE_ALARM_ACTIVE': 'Alarm sürerken vana açılamaz. Önce sensörün kuruduğundan emin olup alarmı onaylayın.',
  'GAS_LOCAL_ONLY': 'Gaz vanası güvenlik gereği yalnız yerinde, panodaki düğmeyle açılır.',
  'ACTUATOR_USE_SAFETY_COMMAND': 'Bu kanal bir güvenlik cihazına bağlı; lamba gibi açılamaz.',
  'FIRMWARE_UNSUPPORTED': 'Pano yazılımı güvenlik modülünü desteklemiyor. Pano yazılımını güncelleyin.',
  'ALARM_NOT_OPEN': 'Bu alarm zaten kapanmış.',
};

/// `submit` çağrısının REST/LAN gönderim sonucu.
enum CommandDispatchStatus {
  /// Komut iletildi (onay `state` ile ayrıca beklenir).
  delivered,

  /// Gönderim başarısız: komut **zaten geri alındı** (bkz. [CommandDispatch.failure]).
  failed,

  /// Aynı uç noktaya daha yeni bir komut verildi; bu komutun yerine o geçti.
  superseded,

  /// `dispose` / çıkış / ev değişimi ile iptal edildi.
  cancelled,
}

class CommandDispatch {
  const CommandDispatch._(this.status, {this.failure, this.result});

  const CommandDispatch.delivered(CommandResult result)
      : this._(CommandDispatchStatus.delivered, result: result);
  const CommandDispatch.failed(CommandFailure failure)
      : this._(CommandDispatchStatus.failed, failure: failure);
  const CommandDispatch.superseded() : this._(CommandDispatchStatus.superseded);
  const CommandDispatch.cancelled() : this._(CommandDispatchStatus.cancelled);

  final CommandDispatchStatus status;
  final CommandFailure? failure;
  final CommandResult? result;

  bool get ok => status == CommandDispatchStatus.delivered;
}

/// Onay politikası.
enum CommandConfirmMode {
  /// Cihazdan hedefi doğrulayan `state` beklenir; 2.5 sn içinde gelmezse geri alınır.
  state,

  /// REST/LAN iletimi başarılıysa komut tamamlanmış sayılır (toplu komut, darbe, adım).
  delivery,

  /// İletim başarılıysa komut "iletildi" sayılır; ancak canlı `state` kanalı yokken (MQTT kopuk)
  /// iyimser değer onay penceresi boyunca tutulur ve süre dolunca **hata göstermeden** bırakılır.
  settle,
}

/// Bekleyen (iyimser) komutun dışa açık görünümü. Uç nokta başına **tek** kayıt vardır.
class PendingCommand {
  PendingCommand._({
    required this.key,
    required this.original,
    required this.target,
    required this.commandId,
    required this.startedAt,
    this.targetUid,
  }) : submittedAt = startedAt;

  /// Uç nokta anahtarı.
  final String key;

  /// **İlk dokunuştaki gerçek değer** (art arda dokunuşlarda değişmez).
  final Object? original;

  /// Son iyimser hedef değer (arayüzde gösterilir).
  Object? target;

  /// Cihazın `state.last_id` ile yankılayacağı komut kimliği.
  String commandId;

  /// İlk dokunuş zamanı.
  final DateTime startedAt;

  /// Komutun hedef panosu (`AHBU-...`, büyük harf); bilinmiyorsa `null` (LAN: tek pano). Panonun ret yankısı
  /// (`last_rej`) yalnız bu panonun `state`'inden kabul edilir: ev konusu bütün panolara gider ve düz `relay`
  /// komutunu başka bir pano kendi eylemcisi yüzünden reddedebilir [Y5].
  String? targetUid;

  /// Son komut sunucuya/cihaza iletildi mi. İletildi ama henüz doğrulanmadı = **"uygulanıyor"**.
  bool delivered = false;

  /// Son dokunuş zamanı (toplam üst sınır buradan ölçülür).
  DateTime submittedAt;

  int _generation = 0;
}

/// Hedef değeri doğrulayan `state` anlık görüntüsü mü?
typedef ConfirmPredicate = bool Function(DeviceStatus snapshot);

/// Komut gönderici: [commandId] komutun `id` alanına yazılır.
typedef CommandSender = Future<CommandResult> Function(String commandId);

/// İyimser arayüz komut hattı (CONTRACTS §5, EVOTOMASYON_TASKS 2.B).
///
/// * Uç nokta başına **tek** bekleyen komut: art arda dokunuş mevcut kaydın hedefini günceller,
///   **ilk dokunuştaki gerçek değer** saklanır ve gönderimler **sıraya** alınır (son niyet kazanır;
///   en çok bir uçuşta + bir bekleyen istek).
/// * REST yanıtı `delivered=false` veya hata ise **anında** geri alınır + [failures] olayı.
/// * Cihazdan hedefi doğrulayan `state` gelirse ([observe]) zamanlayıcı iptal olur.
/// * Cihaz `state.last_rej` ile komutumuzu reddettiyse ([observe]) komut BEKLEMEDEN geri alınır (ret metniyle).
/// * [confirmTimeout] (varsayılan 2.5 sn) içinde onay yoksa geri alınır + [failures] olayı.
/// * [cancelAll]: `dispose` / çıkış / ev değişiminde tüm kayıtları (geri alma olayı üretmeden) iptal eder.
///
/// Geri alma = kaydın silinmesi; arayüz değeri "gerçek durum + bekleyen hedefler" olarak türetir,
/// dolayısıyla kayıt kalkınca son bilinen **gerçek** değer görünür.
class CommandPipeline {
  CommandPipeline({
    required this.clock,
    this.confirmTimeout = const Duration(milliseconds: 2500),
    this.maxTotal = const Duration(seconds: 10),
    this.onChanged,
    this._idGenerator,
  });

  final Clock clock;

  /// Cihaz onayı penceresi. **İletimden (REST/LAN yanıtı) itibaren** ölçülür: ağ gecikmesi bu
  /// bütçeden yemez. Pencere içinde hedefi doğrulayan `state` gelmezse komut geri alınır.
  final Duration confirmTimeout;

  /// Bir komutun (son dokunuştan itibaren) toplam üst sınırı: gönderim yanıtı bu sürede
  /// gelmezse komut geri alınır; iletimden sonra onay penceresi bu sınırı aşmaz.
  final Duration maxTotal;

  /// Bekleyen kayıt kümesi değiştiğinde çağrılır (arayüzü yeniden hesaplamak için).
  final VoidCallback? onChanged;
  final String Function()? _idGenerator;

  final Map<String, _Entry> _entries = <String, _Entry>{};
  final _failures = StreamController<CommandFailure>.broadcast();
  final _confirmations = StreamController<String>.broadcast();
  int _counter = 0;
  bool _disposed = false;

  /// Geri alınan komutlar (snackbar için).
  Stream<CommandFailure> get failures => _failures.stream;

  /// Onaylanan komutların anahtarları.
  Stream<String> get confirmations => _confirmations.stream;

  Iterable<PendingCommand> get pending => _entries.values.map((e) => e.command);
  bool get hasPending => _entries.isNotEmpty;
  bool isPending(String key) => _entries.containsKey(key);
  PendingCommand? pendingFor(String key) => _entries[key]?.command;

  /// Komut kimliği (`cmd.id`): sunucu/firmware kuralı `^[A-Za-z0-9._:-]{1,24}$`. Üretilen kimlik
  /// `c` + zaman (base36) + sayaç (base36) biçimindedir (≈ 12 karakter, yalnız `[a-z0-9]`).
  String _newId() {
    final custom = _idGenerator;
    if (custom != null) return custom();
    _counter++;
    return 'c${clock.now().millisecondsSinceEpoch.toRadixString(36)}${_counter.toRadixString(36)}';
  }

  /// Yalnızca testler: bir sonraki komut kimliğini üretir (kimlik kuralı denetimi için).
  @visibleForTesting
  String nextCommandIdForTesting() => _newId();

  /// Komutu iyimser olarak kaydeder ve [send] ile gönderir. Dönen gelecek **gönderim** sonucuyla
  /// tamamlanır (onay/geri alma sonradan [confirmations]/[failures] ile bildirilir).
  Future<CommandDispatch> submit({
    required String key,
    required Object? original,
    required Object? target,
    required CommandSender send,
    ConfirmPredicate? confirms,
    CommandConfirmMode mode = CommandConfirmMode.state,
    String? targetUid,
  }) {
    if (_disposed) return Future.value(const CommandDispatch.cancelled());

    final existing = _entries[key];
    if (existing != null) {
      existing.command
        ..target = target
        ..delivered = false
        ..submittedAt = clock.now()
        ..targetUid = targetUid?.toUpperCase()
        .._generation += 1;
      existing
        ..send = send
        ..confirms = confirms
        ..mode = mode;
      final previous = existing.completer;
      existing.completer = Completer<CommandDispatch>();
      if (!previous.isCompleted) previous.complete(const CommandDispatch.superseded());
      _restartTimer(existing);
      if (existing.inFlight) {
        existing.dirty = true; // uçuştaki istek bitince en son hedef gönderilir
      } else {
        _launch(existing);
      }
      _notify();
      return existing.completer.future;
    }

    final command = PendingCommand._(
      key: key,
      original: original,
      target: target,
      commandId: _newId(),
      startedAt: clock.now(),
      targetUid: targetUid?.toUpperCase(),
    );
    final entry = _Entry(command: command, send: send, confirms: confirms, mode: mode);
    _entries[key] = entry;
    _restartTimer(entry);
    _launch(entry);
    _notify();
    return entry.completer.future;
  }

  /// Gönderim aşaması: yanıt [maxTotal] içinde gelmezse komut geri alınır.
  void _restartTimer(_Entry entry) {
    entry.timer?.cancel();
    entry.timer = clock.timer(maxTotal, () => _onTimeout(entry));
  }

  /// İletim sonrası: onay penceresi **iletimden** başlar ([confirmTimeout]); toplam üst sınırı aşmaz.
  void _restartConfirmTimer(_Entry entry) {
    entry.timer?.cancel();
    final deadline = entry.command.submittedAt.add(maxTotal);
    var delay = confirmTimeout;
    final remaining = deadline.difference(clock.now());
    if (remaining < delay) {
      delay = remaining > const Duration(milliseconds: 500) ? remaining : const Duration(milliseconds: 500);
    }
    entry.timer = clock.timer(delay, () => _onTimeout(entry));
  }

  bool _isCurrent(_Entry entry) => !_disposed && identical(_entries[entry.command.key], entry);

  void _launch(_Entry entry) {
    entry.inFlight = true;
    entry.dirty = false;
    final generation = entry.command._generation;
    final id = _newId();
    entry.command.commandId = id;
    Future<CommandResult> future;
    try {
      future = entry.send(id);
    } catch (e) {
      future = Future<CommandResult>.error(e);
    }
    future.then(
      (result) => _onResult(entry, generation, result),
      onError: (Object error) => _onError(entry, generation, error),
    );
  }

  void _onResult(_Entry entry, int generation, CommandResult result) {
    entry.inFlight = false;
    if (!_isCurrent(entry)) return;
    if (entry.dirty || generation != entry.command._generation) {
      _launch(entry); // arada daha yeni bir hedef verildi: onu gönder
      return;
    }
    if (!result.delivered || result.deviceOnline == false) {
      _fail(
        entry,
        CommandFailure(
          key: entry.command.key,
          reason: result.deviceOnline == false
              ? CommandFailureReason.offline
              : CommandFailureReason.notDelivered,
          message: result.deviceOnline == false
              ? 'Cihaz çevrimdışı. Komut iletilemedi.'
              : 'Komut cihaza iletilemedi.',
        ),
      );
      return;
    }
    entry.command.delivered = true;
    final serverId = result.commandId;
    if (serverId != null && serverId.isNotEmpty) entry.command.commandId = serverId;
    if (!entry.completer.isCompleted) entry.completer.complete(CommandDispatch.delivered(result));
    if (entry.mode == CommandConfirmMode.delivery) {
      _remove(entry);
      _confirmations.add(entry.command.key);
      _notify();
    } else if (result.noChange) {
      // Sunucu: cihaz zaten hedef değeri bildiriyor; yeni `state` gelmeyebilir -> doğrulanmış sayılır.
      _remove(entry);
      _confirmations.add(entry.command.key);
      _notify();
    } else {
      _restartConfirmTimer(entry); // "uygulanıyor": onay penceresi iletimden başlar
      _notify();
    }
  }

  void _onError(_Entry entry, int generation, Object error) {
    entry.inFlight = false;
    if (!_isCurrent(entry)) return;
    if (entry.dirty || generation != entry.command._generation) {
      _launch(entry);
      return;
    }
    _fail(entry, CommandFailure.fromError(entry.command.key, error));
  }

  void _onTimeout(_Entry entry) {
    if (!_isCurrent(entry)) return;
    if (!entry.command.delivered) {
      // Gönderim yanıtı hiç gelmedi (yavaş/kopuk ağ): geri al.
      _fail(
        entry,
        CommandFailure(
          key: entry.command.key,
          reason: CommandFailureReason.network,
          message: 'Sunucudan yanıt alınamadı. İşlem geri alındı.',
        ),
      );
      return;
    }
    final silent = entry.mode == CommandConfirmMode.delivery || entry.mode == CommandConfirmMode.settle;
    if (silent) {
      _remove(entry);
      if (!entry.completer.isCompleted) {
        entry.completer.complete(CommandDispatch.delivered(CommandResult.accepted));
      }
      _notify();
      return;
    }
    // İletildi ama cihaz pencere içinde doğrulamadı: görünür değer geri alınır; komut uygulanmış
    // olabileceğinden mesaj nötrdür ve arayüz durumu hemen yeniden eşitler.
    _fail(
      entry,
      CommandFailure(
        key: entry.command.key,
        reason: CommandFailureReason.timeout,
        message: 'Cihazdan onay alınamadı. İşlem geri alındı; durum yeniden kontrol ediliyor.',
      ),
    );
  }

  void _remove(_Entry entry) {
    entry.timer?.cancel();
    entry.timer = null;
    if (identical(_entries[entry.command.key], entry)) _entries.remove(entry.command.key);
  }

  void _fail(_Entry entry, CommandFailure failure) {
    _remove(entry);
    if (!entry.completer.isCompleted) entry.completer.complete(CommandDispatch.failed(failure));
    if (!_failures.isClosed) _failures.add(failure);
    _notify();
  }

  /// Cihazdan gelen her `state` anlık görüntüsünü (MQTT veya yoklama) bekleyen komutlara uygular:
  /// hedefi doğrulayan (veya `last_id` komut kimliğimizi yankılayan) kayıtların zamanlayıcısı iptal olur.
  /// `last_rej.id` komut kimliğimizse (ve yankı hedef panodansa) komut ANINDA geri alınır.
  void observe(DeviceStatus snapshot) {
    if (_entries.isEmpty) return;
    final rejection = snapshot.lastRej;
    if (rejection != null) {
      final snapshotUid = snapshot.uid?.toUpperCase();
      final rejected = <_Entry>[
        for (final entry in _entries.values)
          if (entry.command.commandId == rejection.id &&
              (entry.command.targetUid == null || snapshotUid == null || entry.command.targetUid == snapshotUid))
            entry,
      ];
      for (final entry in rejected) {
        _fail(
          entry,
          CommandFailure(
            key: entry.command.key,
            reason: CommandFailureReason.rejected,
            message: rejection.message,
            error: rejection,
            code: rejection.code,
          ),
        );
      }
      if (_entries.isEmpty) return;
    }
    final confirmed = <_Entry>[];
    for (final entry in _entries.values) {
      final echoed = snapshot.lastId != null && snapshot.lastId == entry.command.commandId;
      final matches = entry.confirms?.call(snapshot) ?? false;
      if (echoed || matches) confirmed.add(entry);
    }
    for (final entry in confirmed) {
      _remove(entry);
      if (!entry.completer.isCompleted) {
        entry.completer.complete(CommandDispatch.delivered(CommandResult.accepted));
      }
      if (!_confirmations.isClosed) _confirmations.add(entry.command.key);
    }
    if (confirmed.isNotEmpty) _notify();
  }

  /// Yerel olarak reddedilen bir komutu (yetki yok, geçersiz hedef ...) aynı [failures] akışına bildirir.
  void emitFailure(CommandFailure failure) {
    if (!_failures.isClosed) _failures.add(failure);
  }

  /// Belirli bir kaydı (olay üretmeden) iptal eder.
  void cancel(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    _remove(entry);
    if (!entry.completer.isCompleted) entry.completer.complete(const CommandDispatch.cancelled());
    _notify();
  }

  /// Tüm kayıtları (geri alma olayı üretmeden) iptal eder: `dispose` / çıkış / ev değişimi.
  void cancelAll() {
    if (_entries.isEmpty) return;
    final all = _entries.values.toList();
    for (final entry in all) {
      entry.timer?.cancel();
      entry.timer = null;
      if (!entry.completer.isCompleted) entry.completer.complete(const CommandDispatch.cancelled());
    }
    _entries.clear();
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    onChanged?.call();
  }

  void dispose() {
    if (_disposed) return;
    cancelAll();
    _disposed = true;
    _failures.close();
    _confirmations.close();
  }
}

class _Entry {
  _Entry({
    required this.command,
    required this.send,
    required this.confirms,
    required this.mode,
  });

  final PendingCommand command;
  CommandSender send;
  ConfirmPredicate? confirms;
  CommandConfirmMode mode;
  Timer? timer;
  bool inFlight = false;
  bool dirty = false;
  Completer<CommandDispatch> completer = Completer<CommandDispatch>();
}

/// Hazır onay koşulları (cihaz `state` anlık görüntüsüne göre).
class CommandConfirm {
  CommandConfirm._();

  /// Röle `channel` (1 tabanlı) hedef durumda.
  static ConfirmPredicate relay(int channel, bool on) => (s) {
        final r = s.relayById(channel);
        return r != null && r.state == on;
      };

  /// Panjur `pair` (1 tabanlı) hedef konuma gidiyor ya da orada durmuş.
  static ConfirmPredicate shutterPosition(int pair, int pos) => (s) {
        final sh = s.shutterByPair(pair);
        if (sh == null) return false;
        return sh.target == pos || (!sh.isMoving && sh.pos == pos);
      };

  /// Panjur yukarı hareket ediyor (veya zaten tam açık).
  static ConfirmPredicate shutterUp(int pair) => (s) {
        final sh = s.shutterByPair(pair);
        if (sh == null) return false;
        return (sh.isMoving && sh.direction == 1) || (!sh.isMoving && sh.pos >= 100);
      };

  /// Panjur aşağı hareket ediyor (veya zaten tam kapalı).
  static ConfirmPredicate shutterDown(int pair) => (s) {
        final sh = s.shutterByPair(pair);
        if (sh == null) return false;
        return (sh.isMoving && sh.direction == 2) || (!sh.isMoving && sh.pos <= 0);
      };

  /// Panjur durdu.
  static ConfirmPredicate shutterStopped(int pair) => (s) {
        final sh = s.shutterByPair(pair);
        return sh != null && !sh.isMoving;
      };

  /// Çocuk kilidi hedef durumda. **Bilinmeyen kilit durumu hiçbir zaman onay sayılmaz**: yükte
  /// `child_lock` yoksa (ör. REST'ten türetilmiş anlık görüntü) `false` varsayılan değeri hedefle
  /// karışmasın diye `childLockKnown` şarttır.
  static ConfirmPredicate childLock(bool enabled) => (s) => s.childLockKnown && s.childLock == enabled;

  /// Eylemci [id] bu panonun mu ([uid] verilmişse)? Güvenlik alanı olmayan (v:2 / REST türevi) görüntü onay sayılmaz.
  static ActuatorItem? _actuator(DeviceStatus s, String id, String? uid) {
    final safety = s.safety;
    if (!safety.supported) return null;
    if (uid != null && safety.deviceUid != null && safety.deviceUid != uid.toUpperCase()) return null;
    return safety.actuatorById(id);
  }

  /// Vana [id] hedef yönde: kapalı için `closed`/`cmd_closed`/`closing`, açık için `open`/`cmd_open`/`opening`.
  static ConfirmPredicate valvePos(String id, {required bool closed, String? uid}) => (s) {
        final pos = _actuator(s, id, uid)?.pos;
        if (pos == null) return false;
        return closed
            ? (pos == ValvePos.closed || pos == ValvePos.cmdClosed || pos == ValvePos.closing)
            : (pos == ValvePos.open || pos == ValvePos.cmdOpen || pos == ValvePos.opening);
      };

  /// Siren / fan / genel eylemci [id] hedef durumda.
  static ConfirmPredicate actuatorOn(String id, bool on, {String? uid}) => (s) {
        final value = _actuator(s, id, uid)?.on;
        return value != null && value == on;
      };

  /// Bölge [zone] alarmı susturuldu ya da kilit kalktı (bölge `normal`).
  static ConfirmPredicate alarmSilencedOrCleared(int zone, {String? uid}) => (s) {
        final safety = s.safety;
        if (!safety.supported) return false;
        if (uid != null && safety.deviceUid != null && safety.deviceUid != uid.toUpperCase()) return false;
        // Firmware normal bölgeyi yazmaz (CONTRACTS §2.6): listeden düşen bölge = kilit kalktı.
        final status = safety.zoneStatus(zone);
        if (status == ZoneStatus.normal) return true;
        return safety.alarmForZone(zone)?.silenced ?? false;
      };
}
