import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../models/endpoint_sync.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../widgets/di_status_pill.dart';
import '../widgets/relay_switch_card.dart';
import '../widgets/shutter_card.dart';
import 'labels.dart';

/// Oda filtresi seçeneği (`key` karşılaştırma anahtarı, `label` okunur ad).
@immutable
class RoomOption {
  const RoomOption(this.key, this.label);

  final String key;
  final String label;

  @override
  bool operator ==(Object other) => other is RoomOption && other.key == key && other.label == label;

  @override
  int get hashCode => Object.hash(key, label);
}

/// Oda seçenekleri listesi (değer eşitliği: `context.select` ile kullanılır).
@immutable
class RoomOptions {
  const RoomOptions(this.items);

  final List<RoomOption> items;

  @override
  bool operator ==(Object other) => other is RoomOptions && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}

/// Bulutta oda çipleri **uç noktalardan türetilir** (`yatak_odasi` -> `Yatak Odası`; yinelenen
/// yazımlar tek odada birleşir). Doğrudan (LAN) modda oda bilgisi yoktur: liste boştur.
RoomOptions roomOptionsOf(AutomationState s) {
  if (s.mode == AppMode.direct) return const RoomOptions(<RoomOption>[]);
  final byKey = <String, String>{};
  for (final endpoint in s.cloudEndpoints) {
    byKey.putIfAbsent(roomKey(endpoint.room), () => roomLabel(endpoint.room));
  }
  final entries = byKey.entries.toList()
    ..sort((a, b) {
      // "Genel" en sona, diğerleri alfabetik.
      if (a.key == 'genel') return b.key == 'genel' ? 0 : 1;
      if (b.key == 'genel') return -1;
      return a.value.compareTo(b.value);
    });
  return RoomOptions(<RoomOption>[for (final e in entries) RoomOption(e.key, e.value)]);
}

/// Oda filtresine göre görünen röle/panjur öğeleri ([roomKeyFilter] `null` = tümü).
({List<RelayItem> relays, List<ShutterItem> shutters}) itemsForRoom(AutomationState s, String? roomKeyFilter) {
  final relays = s.relayItems;
  final shutters = s.shutterItems;
  if (s.mode == AppMode.direct || roomKeyFilter == null) {
    return (relays: relays, shutters: shutters);
  }
  final endpoints = s.cloudEndpoints;
  final relayRoom = <int, String>{
    for (final e in endpoints)
      if (!e.isShutter) e.channel: roomKey(e.room),
  };
  final shutterRoom = <int, String>{
    for (final e in primaryShutterEndpoints(endpoints)) e.pair: roomKey(e.room),
  };
  return (
    relays: relays.where((r) => relayRoom[r.id] == roomKeyFilter).toList(growable: false),
    shutters: shutters.where((x) => shutterRoom[x.pair] == roomKeyFilter).toList(growable: false),
  );
}

/// Oda filtre çipleri (≥ 2 oda varsa gösterilir). Anahtarlar: `Key('chip_room_<anahtar>')`,
/// `Key('chip_room_all')`.
class RoomFilterChips extends StatelessWidget {
  const RoomFilterChips({super.key, required this.selected, required this.onSelected});

  /// Seçili oda anahtarı; `null` = "Tümü".
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final rooms = context.select<AutomationState, RoomOptions>(roomOptionsOf).items;
    if (rooms.length < 2) return const SizedBox.shrink();

    final isDark = AppTheme.isDark(context);
    Widget chip(Key key, String label, bool isSelected, VoidCallback onTap) {
      final accent = isDark ? AppTheme.primaryBlueLight : AppTheme.primaryBlue;
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: ChoiceChip(
          key: key,
          label: Text(label),
          selected: isSelected,
          onSelected: (_) => onTap(),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          backgroundColor: AppTheme.getCardColor(context),
          selectedColor: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.25 : 0.15),
          showCheckmark: false,
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? accent : AppTheme.getTextPrimary(context),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: isSelected ? accent : AppTheme.getCardBorder(context)),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          chip(const Key('chip_room_all'), 'Tümü', selected == null, () => onSelected(null)),
          for (final room in rooms)
            chip(
              Key('chip_room_${room.key.replaceAll(' ', '_')}'),
              room.label,
              selected == room.key,
              () => onSelected(room.key),
            ),
        ],
      ),
    );
  }
}

/// Bölüm başlığı + sağda rozet (ör. "3 Motor").
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.icon, required this.title, required this.badge});

  final IconData icon;
  final String title;
  final String badge;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.infoText(context)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.getTextPrimary(context),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.getInsetColor(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.getCardBorder(context)),
          ),
          child: Text(
            badge,
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.getTextMuted(context),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Karşılaştırma imzası: bölümün yeniden kurulması gerekip gerekmediğine karar verir (kartlar kendi
/// canlı değerlerini seçtiğinden değerler değil, **hangi kartların** gösterildiği önemlidir).
String _signature(AutomationState s, String? roomKeyFilter) {
  final items = itemsForRoom(s, roomKeyFilter);
  final dis = s.mode == AppMode.direct ? (s.status?.dis ?? const <DIItem>[]) : const <DIItem>[];
  return '${items.relays.map((r) => '${r.id}:${r.type}:${r.name}').join('|')}#'
      '${items.shutters.map((x) => '${x.pair}:${x.name}').join('|')}#'
      '${dis.map((d) => d.id).join(',')}';
}

/// Panjur / aydınlatma / DI bölümleri. Yalnızca **yapılandırılmış** panjur çiftleri (`shutterItems`)
/// ve kontrol edilebilir çıkışlar (`relayItems`; panjur röleleri hariç) gösterilir. Doğrudan modda
/// duvar butonları (DI) da listelenir.
class DeviceSections extends StatelessWidget {
  const DeviceSections({super.key, this.roomKeyFilter, this.roomLabelText});

  /// Seçili oda anahtarı (`null` = tümü).
  final String? roomKeyFilter;

  /// Boş durum mesajı için oda adı.
  final String? roomLabelText;

  @override
  Widget build(BuildContext context) {
    // Yalnızca gösterilen kart kümesi değişince yeniden kur.
    context.select<AutomationState, String>((s) => _signature(s, roomKeyFilter));
    final state = context.read<AutomationState>();
    final items = itemsForRoom(state, roomKeyFilter);
    final dis = state.mode == AppMode.direct ? (state.status?.dis ?? const <DIItem>[]) : const <DIItem>[];

    if (items.relays.isEmpty && items.shutters.isEmpty && dis.isEmpty) {
      return Container(
        key: const Key('empty_devices'),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Column(
          children: [
            Icon(Icons.inbox_outlined, size: 40, color: AppTheme.getTextMuted(context)),
            const SizedBox(height: 8),
            Text(
              roomLabelText == null
                  ? 'Kontrol edilebilir cihaz bulunamadı'
                  : '$roomLabelText odasında cihaz bulunamadı',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (items.shutters.isNotEmpty) ...[
          SectionHeader(
            icon: Icons.blinds,
            title: 'Panjurlar',
            badge: '${items.shutters.length} Motor',
          ),
          const SizedBox(height: 10),
          CardGrid(
            children: [for (final s in items.shutters) ShutterCard(key: ValueKey('shutter_${s.pair}'), shutter: s)],
          ),
          const SizedBox(height: 24),
        ],
        if (items.relays.isNotEmpty) ...[
          SectionHeader(
            icon: Icons.lightbulb_outline,
            title: 'Aydınlatma & Çıkışlar',
            badge: '${items.relays.length} Çıkış',
          ),
          const SizedBox(height: 10),
          CardGrid(
            children: [for (final r in items.relays) RelaySwitchCard(key: ValueKey('relay_${r.id}'), relay: r)],
          ),
          const SizedBox(height: 24),
        ],
        if (dis.isNotEmpty) ...[
          const SectionHeader(
            icon: Icons.touch_app_outlined,
            title: 'Duvar Butonları & Girişler',
            badge: 'Kuru kontak',
          ),
          const SizedBox(height: 10),
          const _ChildLockWallNote(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final d in dis) DIStatusPill(key: ValueKey('di_${d.id}'), di: d)],
          ),
        ],
      ],
    );
  }
}

/// Çocuk kilidi açıkken duvar anahtarlarının neden çalışmadığını açıklar.
class _ChildLockWallNote extends StatelessWidget {
  const _ChildLockWallNote();

  @override
  Widget build(BuildContext context) {
    final locked = context.select<AutomationState, bool>(
      (s) => s.childLockStatus == ChildLockStatus.locked,
    );
    if (!locked) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        key: const Key('note_child_lock_wall'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 16, color: AppTheme.warningText(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Kilitli: duvar anahtarları devre dışı. Uygulamadan kontrol edebilirsiniz.',
              style: TextStyle(fontSize: 12, color: AppTheme.warningText(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kartları genişliğe göre 1 ya da 2 sütunda dizer.
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 600;
        final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final child in children) SizedBox(width: itemWidth, child: child)],
        );
      },
    );
  }
}
