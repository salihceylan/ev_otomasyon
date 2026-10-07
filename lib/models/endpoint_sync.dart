import 'automation_models.dart';
import 'cloud_models.dart';

/// Panjurun cihazdan bildirilen anlık hareket bilgisi (REST uç nokta listesinde yoktur;
/// yalnızca MQTT `state` / LAN `status` ile gelir).
class ShutterRuntime {
  const ShutterRuntime({this.moving = false, this.direction = 0, this.target});

  final bool moving;

  /// 0 durdu, 1 yukarı, 2 aşağı.
  final int direction;

  /// Hedef konum (yoksa `null`).
  final int? target;
}

/// [applyStatusToEndpoints] sonucu.
class EndpointSyncResult {
  const EndpointSyncResult(this.endpoints, this.changed);

  final List<EndpointModel> endpoints;
  final bool changed;
}

/// Cihaz `state` anlık görüntüsünü uç noktalara uygular.
///
/// **Eşleştirme uç nokta tipi + kanal ile yapılır** (eski kod yalnızca kanala bakıyordu ve bir
/// panjur rölesinin durumunu lamba satırına, ya da yanlış panjur çiftine yazıyordu):
///
/// * röle `r` -> `!isShutter && channel == r.id` (panjur röleleri `r.isShutterRelay` ise atlanır),
/// * panjur `s` -> `isShutter && pair == s.pair` (birincil satır `channel == 2*pair-1`; varsa
///   aşağı-röle satırı da aynı konumu alır ki tek bir panjurun iki kartı çelişmesin).
///
/// [status.uid] biliniyorsa yalnızca o cihaza ait (veya cihaz kimliği bilinmeyen) satırlar güncellenir.
EndpointSyncResult applyStatusToEndpoints(List<EndpointModel> endpoints, DeviceStatus status) {
  final uid = status.uid?.toUpperCase();
  var changed = false;
  final out = <EndpointModel>[];
  for (final endpoint in endpoints) {
    final deviceUuid = endpoint.deviceUuid?.toUpperCase();
    final sameDevice = uid == null || deviceUuid == null || deviceUuid == uid;
    if (!sameDevice) {
      out.add(endpoint);
      continue;
    }
    var updated = endpoint;
    if (endpoint.isShutter) {
      final shutter = status.shutterByPair(endpoint.pair);
      if (shutter != null && shutter.pos != endpoint.shutterPosition) {
        updated = endpoint.copyWith(shutterPosition: shutter.pos);
      }
    } else {
      final relay = status.relayById(endpoint.channel);
      if (relay != null && !relay.isShutterRelay && relay.state != endpoint.currentState) {
        updated = endpoint.copyWith(currentState: relay.state);
      }
    }
    if (!identical(updated, endpoint)) changed = true;
    out.add(updated);
  }
  return EndpointSyncResult(changed ? out : endpoints, changed);
}

/// Bir panjur çiftini temsil eden tek uç nokta satırı (hayalet/yinelenen satırları atar).
///
/// Sunucu bir panjur için iki satır tutabilir (YUKARI ve AŞAĞI röleleri). Arayüzde yalnızca
/// birincil satır (`channel == 2*pair-1`) gösterilir; yoksa o çiftin en küçük kanallı satırı.
List<EndpointModel> primaryShutterEndpoints(List<EndpointModel> endpoints) {
  final byPair = <int, EndpointModel>{};
  for (final endpoint in endpoints) {
    if (!endpoint.isShutter) continue;
    final current = byPair[endpoint.pair];
    if (current == null) {
      byPair[endpoint.pair] = endpoint;
      continue;
    }
    final better = (endpoint.isPrimaryShutterRow && !current.isPrimaryShutterRow) ||
        (endpoint.isPrimaryShutterRow == current.isPrimaryShutterRow &&
            endpoint.channel < current.channel);
    if (better) byPair[endpoint.pair] = endpoint;
  }
  final pairs = byPair.keys.toList()..sort();
  return <EndpointModel>[for (final pair in pairs) byPair[pair]!];
}

/// Bulut uç noktalarından arayüz panjur öğeleri (benzersiz panjur başına bir tane).
List<ShutterItem> shutterItemsFromEndpoints(
  List<EndpointModel> endpoints,
  Map<int, ShutterRuntime> runtime,
) {
  return <ShutterItem>[
    for (final endpoint in primaryShutterEndpoints(endpoints))
      ShutterItem(
        pair: endpoint.pair,
        name: shutterBaseName(endpoint.name, fallback: 'Panjur ${endpoint.pair}'),
        isMoving: runtime[endpoint.pair]?.moving ?? false,
        direction: runtime[endpoint.pair]?.direction ?? 0,
        pos: endpoint.shutterPosition,
        target: runtime[endpoint.pair]?.target,
        runtimeSec: endpoint.shutterDurationSec,
      ),
  ];
}

/// Bulut uç noktalarından arayüz röle öğeleri (aydınlatma / priz / darbe; panjurlar hariç).
List<RelayItem> relayItemsFromEndpoints(List<EndpointModel> endpoints) {
  return <RelayItem>[
    for (final endpoint in endpoints)
      if (!endpoint.isShutter)
        RelayItem(
          id: endpoint.channel,
          name: endpoint.name,
          type: endpoint.isImpulse ? 3 : 0,
          state: endpoint.currentState,
          actuator: ActuatorKind.tryParse(endpoint.actuatorType),
        ),
  ];
}

/// REST uç nokta listesini `state` anlık görüntüsü biçimine çevirir (MQTT kopukken komut
/// onayını REST yoklamasıyla doğrulamak için). Hareket bilgisi (`moving`/`dir`/`target`) REST'te
/// yoktur; çocuk kilidi bilinmiyor sayılır.
DeviceStatus statusFromEndpoints(List<EndpointModel> endpoints) {
  return DeviceStatus(
    relays: relayItemsFromEndpoints(endpoints),
    shutters: shutterItemsFromEndpoints(endpoints, const <int, ShutterRuntime>{}),
    childLockKnown: false,
  );
}

// -----------------------------------------------------------------------------
// Pano yerleşimi ↔ uç nokta listesi uyuşmazlığı (WP-STATE2)
// -----------------------------------------------------------------------------

/// Sunucunun yerleşim eşitlemesinin kabul ettiği en çok röle sayısı (CONTRACTS §2.4b, N <= 40).
const int kMaxReportedRelays = 40;

/// [ReportedLayout.compareWith] sonucu.
enum EndpointLayoutVerdict {
  /// Uç noktalar panonun bildirdiği yerleşimi (tür, panjur çifti, kanal sayısı) yansıtıyor.
  match,

  /// Panonun bildirdiği yerleşim uç noktalarla uyuşmuyor: sunucu eşitlemesi sonrası liste değişecek.
  mismatch,

  /// Karar verilemez (satırlar kimlik bakımından belirsiz).
  unknown,
}

enum _RelayKind { light, impulse, shutterUp, shutterDown }

/// Bir uç nokta satırının arayüzde ÇİZİLEN sınıfı: lamba/priz, darbe ya da panjur.
enum _RowClass { light, impulse, shutter }

String _kindLetter(_RelayKind kind) {
  switch (kind) {
    case _RelayKind.light:
      return 'L';
    case _RelayKind.impulse:
      return 'I';
    case _RelayKind.shutterUp:
      return 'U';
    case _RelayKind.shutterDown:
      return 'D';
  }
}

/// Panonun canlı `state` iletisinde bildirdiği YERLEŞİM: her rölenin türü (lamba/priz, darbe, panjur YUKARI/AŞAĞI),
/// buradan çıkan panjur çiftleri ve kanal sayısı. **Adlar ve anlık değerler (açık/kapalı, konum) yerleşim değildir.**
///
/// Sunucu köprüsü bu yerleşimi ~1 sn içinde buluttaki uç noktalara otomatik eşitler (CONTRACTS §2.4b); açık duran
/// uygulama listeyi kendiliğinden yenilemez. Bu sınıf iletinin yerleşimini sunucunun **kabul koşullarıyla aynı
/// kurallarla** çözer ve uç nokta listesiyle karşılaştırır ([compareWith]). Sunucunun yok sayacağı (eşitlemeyeceği)
/// bir ileti için [from] `null` döner: ondan sonra liste değişmeyeceği için yenileme beklenmez.
///
/// Kabul koşulları (istemcide denetlenebilenler): kısıtlı özet değil; `relays` 1..N (N <= [kMaxReportedRelays])
/// boşluksuz ve yinelemesiz; her rölenin türü bildirilmiş ([RelayItem.typeKnown]); panjur röleleri tam çift
/// (röle `2p-1` YUKARI <=> röle `2p` AŞAĞI); `shutters[]` çift kümesi türlerden çıkan kümeyle aynı. (`v >= 2`
/// sürüm alanı [DeviceStatus]'ta tutulmaz; eski bellenim zaten `type` bildirmez ve yukarıdaki türden elenir.)
class ReportedLayout {
  ReportedLayout._(this._uid, this._kinds, this.shutterPairs, this._acts);

  final String? _uid;
  final List<_RelayKind> _kinds;

  /// Röle başına güvenlik eylemcisi türü (`act`, `null` = eylemci değil) [Y2].
  final List<ActuatorKind?> _acts;

  /// Türlerden çıkan panjur çiftleri (1 tabanlı).
  final Set<int> shutterPairs;

  /// Büyük harfli cihaz kimliği (`state.uid`); bilinmiyorsa `''`.
  String get device => _uid ?? '';

  /// Bildirilen röle sayısı (N): kanallar 1..N.
  int get relayCount => _kinds.length;

  /// Kararlı yerleşim imzası: `UID|` + röle başına bir harf (`L` lamba/priz, `I` darbe, `U` panjur YUKARI,
  /// `D` panjur AŞAĞI), ör. `AHBU-S3-AB12CD|UDUDLLLL`. Güvenlik eylemcisi rölesinde harfin ardına küçük bir eylemci
  /// harfi gelir (`v` vana, `s` siren, `f` fan, `g` genel, `x` bilinmeyen; ör. `UDUDLvLLL`): lambanın vanaya çevrilmesi
  /// eşitlemeyi tetikler [Y2]. Eylemcisiz panoda imza bugünküyle BİREBİR aynıdır. Yalnız tür dizisine ve cihaza
  /// bağlıdır; ad, açık/kapalı ve konum değişimi imzayı DEĞİŞTİRMEZ.
  late final String signature = '$device|${_letters()}';

  String _letters() {
    final out = StringBuffer();
    for (var i = 0; i < _kinds.length; i++) {
      out
        ..write(_kindLetter(_kinds[i]))
        ..write(_actLetter(_acts[i]));
    }
    return out.toString();
  }

  static String _actLetter(ActuatorKind? act) {
    switch (act) {
      case null:
        return '';
      case ActuatorKind.valve:
        return 'v';
      case ActuatorKind.siren:
        return 's';
      case ActuatorKind.fan:
        return 'f';
      case ActuatorKind.generic:
        return 'g';
      case ActuatorKind.unknown:
        return 'x';
    }
  }

  /// [status] bildirdiği yerleşimi çözer; sunucunun da eşitlemeyeceği (kısıtlı / boş / tutarsız) ileti için `null`.
  static ReportedLayout? from(DeviceStatus status) {
    if (status.restricted) return null;
    final relays = status.relays;
    final count = relays.length;
    if (count == 0 || count > kMaxReportedRelays) return null;

    final slots = List<_RelayKind?>.filled(count, null);
    final acts = List<ActuatorKind?>.filled(count, null);
    for (final relay in relays) {
      final id = relay.id;
      if (!relay.typeKnown || id < 1 || id > count || slots[id - 1] != null) return null;
      acts[id - 1] = relay.actuator;
      if (relay.isLight) {
        slots[id - 1] = _RelayKind.light;
      } else if (relay.isShutterUp) {
        slots[id - 1] = _RelayKind.shutterUp;
      } else if (relay.isShutterDown) {
        slots[id - 1] = _RelayKind.shutterDown;
      } else if (relay.isImpulse) {
        slots[id - 1] = _RelayKind.impulse;
      } else {
        return null; // tanınmayan tür: sunucu da eşitlemez
      }
    }
    // `count` kayıt, kimlikler 1..count aralığında ve yinelemesiz: her yuva dolu.
    final kinds = <_RelayKind>[for (final slot in slots) slot!];

    final pairs = <int>{};
    for (var i = 0; i < count; i++) {
      final id = i + 1;
      switch (kinds[i]) {
        case _RelayKind.shutterUp:
          if (id.isEven || i + 1 >= count || kinds[i + 1] != _RelayKind.shutterDown) return null;
          pairs.add((id + 1) ~/ 2);
        case _RelayKind.shutterDown:
          if (id.isOdd || kinds[i - 1] != _RelayKind.shutterUp) return null;
        case _RelayKind.light:
        case _RelayKind.impulse:
          break;
      }
    }

    // `shutters[]` çift kümesi türlerden çıkan kümeyle aynı olmalı (yinelenen çift de tutarsızlıktır).
    final reported = <int>{for (final shutter in status.shutters) shutter.pair};
    if (reported.length != status.shutters.length ||
        reported.length != pairs.length ||
        !reported.containsAll(pairs)) {
      return null;
    }
    return ReportedLayout._(
      status.uid?.toUpperCase(),
      List<_RelayKind>.unmodifiable(kinds),
      Set<int>.unmodifiable(pairs),
      List<ActuatorKind?>.unmodifiable(acts),
    );
  }

  /// [endpoints] listesinin bu yerleşimle uyuşup uyuşmadığı. **Yalnız aynı cihaza ait satırlar** değerlendirilir
  /// ([applyStatusToEndpoints] ile AYNI kural: iki taraftan biri kimliksizse aynı cihaz sayılır). Adlar, açık/kapalı
  /// ve konum karşılaştırılmaz.
  ///
  /// [EndpointLayoutVerdict.mismatch]:
  /// * panjur çiftleri kümesi farklı (yeni çift, kalkan çift, kayan çift);
  /// * panoda lamba/priz ya da darbe olan kanalda satır yok ya da satırın sınıfı farklı (lamba <-> darbe,
  ///   panjur satırı kalmış, ek modül kanalı hiç açılmamış);
  /// * panoda panjur rölesi olan kanalda lamba/darbe (panjur olmayan) satır var;
  /// * satırın kanalı panonun bildirdiği 1..N kanalının dışında (küçülme / ek modül kapandı);
  /// * lamba/darbe satırının eylemci türü (`actuator_type`) panonun `act` alanıyla aynı değil [Y2]. (Eski sunucu
  ///   `actuator_type` göndermez: eylemcili panoda uyuşmazlık sayılır ve imza başına en çok 3 sessiz yenileme yapılır.)
  ///
  /// Panjurun yalnız bir satırı eksikse (YUKARI ya da AŞAĞI) görünür bir fark yoktur; uyuşmazlık sayılmaz.
  EndpointLayoutVerdict compareWith(List<EndpointModel> endpoints) {
    final rowClasses = <int, _RowClass>{};
    final rowActs = <int, ActuatorKind?>{};
    final rowPairs = <int>{};
    for (final endpoint in endpoints) {
      final deviceUuid = endpoint.deviceUuid?.toUpperCase();
      if (_uid != null && deviceUuid != null && deviceUuid != _uid) continue;
      if (rowClasses.containsKey(endpoint.channel)) return EndpointLayoutVerdict.unknown; // bir kanalda iki satır: kimlik belirsiz
      if (endpoint.isShutter) {
        rowClasses[endpoint.channel] = _RowClass.shutter;
        rowPairs.add(endpoint.pair);
      } else {
        rowClasses[endpoint.channel] = endpoint.isImpulse ? _RowClass.impulse : _RowClass.light;
        rowActs[endpoint.channel] = ActuatorKind.tryParse(endpoint.actuatorType);
      }
    }

    if (rowPairs.length != shutterPairs.length || !rowPairs.containsAll(shutterPairs)) {
      return EndpointLayoutVerdict.mismatch;
    }
    final count = _kinds.length;
    for (var i = 0; i < count; i++) {
      final row = rowClasses[i + 1];
      switch (_kinds[i]) {
        case _RelayKind.shutterUp:
        case _RelayKind.shutterDown:
          if (row != null && row != _RowClass.shutter) return EndpointLayoutVerdict.mismatch;
        case _RelayKind.light:
          if (row != _RowClass.light || rowActs[i + 1] != _acts[i]) return EndpointLayoutVerdict.mismatch;
        case _RelayKind.impulse:
          if (row != _RowClass.impulse || rowActs[i + 1] != _acts[i]) return EndpointLayoutVerdict.mismatch;
      }
    }
    for (final channel in rowClasses.keys) {
      if (channel > count) return EndpointLayoutVerdict.mismatch;
    }
    return EndpointLayoutVerdict.match;
  }

  /// [compareWith] == [EndpointLayoutVerdict.mismatch].
  bool mismatches(List<EndpointModel> endpoints) => compareWith(endpoints) == EndpointLayoutVerdict.mismatch;
}

/// Panonun `state`'inde bildirdiği yerleşim, [endpoints] listesiyle (aynı cihazın satırları) uyuşmuyor mu?
/// Kısıtlı / boş / sunucunun eşitlemeyeceği tutarsız `state` için ve yalnız ad farkında `false` döner.
/// Ayrıntı: [ReportedLayout].
bool endpointLayoutMismatch(List<EndpointModel> endpoints, DeviceStatus status) =>
    ReportedLayout.from(status)?.mismatches(endpoints) ?? false;

/// [status] yerleşiminin kararlı imzası ([ReportedLayout.signature]); geçersiz / kısıtlı `state` için `null`.
String? deviceLayoutSignature(DeviceStatus status) => ReportedLayout.from(status)?.signature;

/// İki uç nokta listesi sırayla, alan alan aynı mı? Sessiz yenilemede değişmeyen listede gereksiz bildirimi
/// (yeniden çizimi) önlemek için.
bool sameEndpointList(List<EndpointModel> a, List<EndpointModel> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.id != y.id ||
        x.homeId != y.homeId ||
        x.deviceId != y.deviceId ||
        x.deviceUuid != y.deviceUuid ||
        x.channel != y.channel ||
        x.shutterPair != y.shutterPair ||
        x.name != y.name ||
        x.room != y.room ||
        x.endpointType != y.endpointType ||
        x.currentState != y.currentState ||
        x.shutterPosition != y.shutterPosition ||
        x.shutterDurationSec != y.shutterDurationSec ||
        x.deviceOnline != y.deviceOnline ||
        x.actuatorType != y.actuatorType ||
        x.dimmable != y.dimmable ||
        x.dimmerSource != y.dimmerSource) {
      return false;
    }
  }
  return true;
}
