import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../models/endpoint_sync.dart';
import '../../services/automation_state.dart';
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../pages/alarm_history_page.dart';
import '../widgets/actuator_card.dart';
import '../widgets/app_pill.dart';
import '../widgets/orb/orb.dart';
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

    // Ortak çip ([AppChip]): seçili = cyan tonlu dolgu + parlak kenar + onay işareti (yalnız renkle anlatılmaz); seçili değil =
    // nötr cam; basınca ölçek geri bildirimi, dokunma hedefi >= 48 dp, anlam: button + selected. Çipler arası 8 dp.
    Widget chip(Key key, String label, bool isSelected, VoidCallback onTap) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: AppChip(key: key, label: label, selected: isSelected, onTap: onTap),
        );

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

/// Bölüm başlığı: küçük **mini orb** (32 dp; panodaki diğer orb'larla aynı radyal gövde + speküler + rim) + 15/800 başlık
/// + isteğe bağlı sağ öğe: sayaç rozeti ([badge]; ör. "3 Motor") ya da eylem ([action]; ör. konsolda "Tüm Paneli Aç"
/// bağlantısı). [family] orb rengidir (varsayılan marka camgöbeği).
///
/// TEK bölüm başlığı bileşenidir: pano (Panjurlar / Aydınlatma / Hızlı Senaryolar) ve süper/servis konsolları (Hızlı Yönetici
/// İşlemleri / Saha Servis & Devreye Alma Görevleri) aynı başlığı kullanır (konsollarda eskiden orb'suz çıplak 16/700 metin vardı).
/// Rozet de eylem de verilmezse yalnız orb + başlık çizilir.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.badge,
    this.action,
    this.family = AppFamilies.cyan,
  }) : assert(badge == null || action == null, 'rozet ve eylem birlikte verilmez');

  final IconData icon;
  final String title;

  /// Sağdaki sayaç rozeti; `null` ise çizilmez.
  final String? badge;

  /// Sağdaki eylem (genelde 48 dp'lik bir `TextButton`); `null` ise çizilmez. Başlığa sığmazsa başlığın ALTINA iner ve
  /// başlık metniyle sol kenarda hizalanır.
  final Widget? action;
  final AccentFamily family;

  /// Bu yazı ölçeğinin (dahil) üstünde rozet/eylem başlığın ALTINA iner: başlık + rozet yan yana sığmaz (320 dp + 2.0
  /// ölçekte rozet tek başına satırın yarısından fazlasını alırdı ve başlık 0 dp'ye inerdi).
  static const double stackBadgeFromScale = 1.3;

  /// [action] verildiğinde başlık satırının bu genişliğin (dp) altında eylem başlığın altına iner (≈ başlık + 130 dp'lik bağlantı).
  static const double actionInlineMinWidth = 480;

  @override
  Widget build(BuildContext context) {
    final bigText = MediaQuery.textScalerOf(context).scale(10) / 10 >= stackBadgeFromScale;
    final titleText = Text(
      title,
      style: TextStyle(
        fontSize: AppText.cardTitle,
        fontWeight: FontWeight.w800,
        color: AppTheme.getTextPrimary(context),
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    // Sayaç rozeti ("3 Motor"): ortak rozet dili ([AppPill]), nötr cam (tonsuz) + soluk etiket.
    final Widget? trailing = action ?? (badge == null ? null : AppPill(label: badge!, family: AppFamilies.slate, active: false));
    if (trailing == null) {
      return Row(
        children: [
          _MiniOrb(icon: icon, family: family),
          const SizedBox(width: 10),
          Expanded(child: titleText),
        ],
      );
    }

    Widget stackedRow() => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MiniOrb(icon: icon, family: family),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  titleText,
                  const SizedBox(height: 4),
                  trailing,
                ],
              ),
            ),
          ],
        );
    Widget inlineRow() => Row(
          children: [
            _MiniOrb(icon: icon, family: family),
            const SizedBox(width: 10),
            Expanded(child: titleText),
            const SizedBox(width: 8),
            trailing,
          ],
        );

    if (action == null) return bigText ? stackedRow() : inlineRow();
    // Eylem (48 dp'lik bağlantı) telefon genişliğinde başlıkla yan yana sığmaz: genişliğe de bakılır.
    return LayoutBuilder(
      builder: (context, constraints) =>
          bigText || constraints.maxWidth < actionInlineMinWidth ? stackedRow() : inlineRow(),
    );
  }
}

/// Bölüm başlığı için 32 dp mini orb: [paintOrbBody] ile (büyük orb'larla aynı gövde); açık temada renkli statik
/// gölge, koyuda gölge yok (şartname §2.2). Etkileşimsiz ve anlamdan hariçtir (başlık metni anlamı taşır).
class _MiniOrb extends StatelessWidget {
  const _MiniOrb({required this.icon, required this.family});

  static const double diameter = 32;

  final IconData icon;
  final AccentFamily family;

  @override
  Widget build(BuildContext context) {
    final colors = OrbColors.family(family);
    final dark = AppTheme.isDark(context);
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: dark
                ? null
                : [BoxShadow(color: family.base.withValues(alpha: 0.30), blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: SizedBox.square(
            dimension: diameter,
            child: CustomPaint(
              painter: _MiniOrbPainter(colors),
              child: Center(child: Icon(icon, size: diameter * 0.52, color: colors.icon)),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniOrbPainter extends CustomPainter {
  const _MiniOrbPainter(this.colors);

  final OrbColors colors;

  @override
  void paint(Canvas canvas, Size size) => paintOrbBody(canvas, size.center(Offset.zero), size.width / 2, colors);

  @override
  bool shouldRepaint(_MiniOrbPainter old) => old.colors != colors;
}

/// Karşılaştırma imzası: bölümün yeniden kurulması gerekip gerekmediğine karar verir (kartlar kendi
/// canlı değerlerini seçtiğinden değerler değil, **hangi kartların** gösterildiği önemlidir).
String _signature(AutomationState s, String? roomKeyFilter) {
  final items = itemsForRoom(s, roomKeyFilter);
  final dis = s.mode == AppMode.direct ? (s.status?.dis ?? const <DIItem>[]) : const <DIItem>[];
  final safety = safetyItemsForRoom(s, roomKeyFilter);
  return '${items.relays.map((r) => '${r.id}:${r.type}:${r.name}').join('|')}#'
      '${items.shutters.map((x) => '${x.pair}:${x.name}').join('|')}#'
      '${dis.map((d) => d.id).join(',')}#'
      '${safety.actuators.map((a) => '${a.deviceUid}:${a.id}').join(',')}#'
      '${safety.sensors.map((x) => '${x.id}:${x.kind}:${x.ok}:${x.active}:${x.name}').join(',')}#'
      '${s.capabilities.canAckAlarm}';
}

/// Oda filtresine göre güvenlik eylemcileri ve sensörleri (tasarım §5.3.3). Eylemcinin odası, rölesinin uç noktasından
/// gelir (bulut); sensörlerin odası yoktur: oda süzgeci seçiliyken gizlenir. Doğrudan (LAN) kipte süzgeç yoktur.
({List<ActuatorItem> actuators, List<SensorItem> sensors}) safetyItemsForRoom(AutomationState s, String? roomKeyFilter) {
  final actuators = s.actuatorItems;
  final sensors = s.sensorItems;
  if (s.mode == AppMode.direct || roomKeyFilter == null) return (actuators: actuators, sensors: sensors);
  String? roomOf(ActuatorItem a) {
    for (final e in s.cloudEndpoints) {
      if (e.isShutter || e.channel != a.relay) continue;
      final uid = e.deviceUuid?.toUpperCase();
      if (a.deviceUid == null || uid == null || uid == a.deviceUid) return roomKey(e.room);
    }
    return null;
  }

  return (
    actuators: actuators.where((a) => roomOf(a) == roomKeyFilter).toList(growable: false),
    sensors: const <SensorItem>[],
  );
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
    final safety = safetyItemsForRoom(state, roomKeyFilter);
    final hasSafety = safety.actuators.isNotEmpty || safety.sensors.isNotEmpty;

    if (items.relays.isEmpty && items.shutters.isEmpty && dis.isEmpty && !hasSafety) {
      return Container(
        key: const Key('empty_devices'),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Column(
          children: [
            const OrbIconBadge(icon: Icons.inbox_rounded, family: AppFamilies.slate, size: OrbSize.lg),
            const SizedBox(height: 12),
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
        if (hasSafety) ...[
          _SafetySection(actuators: safety.actuators, sensors: safety.sensors, showHistory: state.capabilities.canAckAlarm),
          const SizedBox(height: 24),
        ],
        if (items.shutters.isNotEmpty) ...[
          // Bölüm başlığı orb'u bölümün anlam ailesinde: panjur = sky, lamba = amber, duvar butonu = emerald (kartlarla aynı).
          SectionHeader(
            icon: Icons.blinds,
            title: 'Panjurlar',
            badge: '${items.shutters.length} Motor',
            family: AppFamilies.sky,
          ),
          const SizedBox(height: 10),
          CardGrid(
            children: [
              for (var i = 0; i < items.shutters.length; i++)
                StaggeredEntrance(
                  key: ValueKey('enter_shutter_${items.shutters[i].pair}'),
                  index: i,
                  child: ShutterCard(key: ValueKey('shutter_${items.shutters[i].pair}'), shutter: items.shutters[i]),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        if (items.relays.isNotEmpty) ...[
          SectionHeader(
            icon: Icons.lightbulb_outline,
            title: 'Aydınlatma & Çıkışlar',
            badge: '${items.relays.length} Çıkış',
            family: AppFamilies.amber,
          ),
          const SizedBox(height: 10),
          CardGrid(
            children: [
              for (var i = 0; i < items.relays.length; i++)
                StaggeredEntrance(
                  key: ValueKey('enter_relay_${items.relays[i].id}'),
                  index: i,
                  child: RelaySwitchCard(key: ValueKey('relay_${items.relays[i].id}'), relay: items.relays[i]),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        if (dis.isNotEmpty) ...[
          const SectionHeader(
            icon: Icons.touch_app_outlined,
            title: 'Duvar Butonları & Girişler',
            badge: 'Kuru kontak',
            family: AppFamilies.emerald,
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

/// "Güvenlik ve Eylemciler" bölümü (panjurlardan önce): eylemci kartları + sensör hapları + alarm geçmişi bağlantısı.
/// Kartlar canlı değerlerini kendileri seçer; bölüm yalnız kart kümesi değişince kurulur ([_signature]).
class _SafetySection extends StatelessWidget {
  const _SafetySection({required this.actuators, required this.sensors, required this.showHistory});

  final List<ActuatorItem> actuators;
  final List<SensorItem> sensors;
  final bool showHistory;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('section_safety'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          icon: Icons.shield_outlined,
          title: 'Güvenlik ve Eylemciler',
          family: AppFamilies.rose,
          action: showHistory
              ? TextButton.icon(
                  key: const Key('btn_alarm_history'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const AlarmHistoryPage()),
                  ),
                  icon: const Icon(Icons.history_rounded, size: 18),
                  label: const Text('Alarm Geçmişi'),
                )
              : null,
        ),
        const SizedBox(height: 10),
        if (actuators.isNotEmpty)
          CardGrid(
            children: [
              for (var i = 0; i < actuators.length; i++)
                StaggeredEntrance(
                  key: ValueKey('enter_actuator_${actuators[i].deviceUid}_${actuators[i].id}'),
                  index: i,
                  child: ActuatorCard(actuatorId: actuators[i].id, deviceUid: actuators[i].deviceUid),
                ),
            ],
          ),
        if (sensors.isNotEmpty) ...[
          if (actuators.isNotEmpty) const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [for (final x in sensors) SensorStatusPill(key: ValueKey('pill_sensor_${x.id}'), sensor: x)],
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
    return StaggeredEntrance(
      index: 0,
      offset: 8,
      child: Padding(
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
      ),
    );
  }
}

/// Kartları genişliğe göre 1 / 2 / 3 sütunda dizer (<= 600 dp: 1; <= 840 dp: 2; üstü: 3) ve **kart sayısına
/// göre dengeler**: kart sayısı sütundan azsa sütun sayısı kart sayısına iner (tek kart 3 sütunun 1'ini
/// kaplayıp yarı boş bölüm bırakmaz), 4 kart 3 sütunda 3+1 yetim bırakmaz (2x2). Kartlar **mevcut genişliği DOLDURUR**
/// (sütunlar eşit genişlikte): ızgara, aynı içerik sütunundaki hero / huzur bandı / senaryo satırı / bölüm başlıklarıyla AYNI
/// sağ kenarda biter (içerik sütununun üst sınırı `kDashboardMaxWidth`'tir). Eskiden kart genişliği 560 dp'de kesilirdi:
/// masaüstünde lamba ızgarası diğer bloklardan ~68 dp kısa kalıyor, tek panjur kartı sola yaslı 560 dp'de duruyordu ve sağında
/// ~960 px boşluk kalıyordu. Tek kart tam genişliktedir (panjur kartı geniş kipte iki panele geçer: [ShutterCardView]).
/// Eager [Wrap]: tüm kartlar kaydırmadan ağaçtadır (testler kartları doğrudan bulur).
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.children});

  final List<Widget> children;

  /// Kartlar arası boşluk (dp).
  static const double gap = 12;

  /// Genişliğe ve kart sayısına göre sütun sayısı ([count] verilmezse yalnız genişlik kuralı).
  static int columnsFor(double width, {int count = 3}) {
    var columns = width > 840 ? 3 : (width > 600 ? 2 : 1);
    if (count < columns) columns = count < 1 ? 1 : count;
    if (columns == 3 && count == 4) columns = 2;
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = columnsFor(constraints.maxWidth, count: children.length);
        final itemWidth = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final child in children) SizedBox(width: itemWidth, child: child)],
        );
      },
    );
  }
}
