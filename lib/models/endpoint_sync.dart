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
