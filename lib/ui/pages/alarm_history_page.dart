import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../dashboard/dashboard_states.dart';
import '../motion/staggered_entrance.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_pill.dart';
import '../widgets/neon_app_bar.dart';
import '../widgets/orb/orb.dart';
import '../widgets/safety_labels.dart';
import '../widgets/surface_card.dart';

/// Alarm geçmişi ekranı (plan 2.6; tasarım §3.5, §5.2.4).
///
/// * Bulut kipinde sunucunun alarm kayıtları (`GET /homes/:id/alarms?state=all`): tür, bölge, durum (metin + simge),
///   açılış zamanı.
/// * Doğrudan (LAN) kipte panonun son 32 olayı (`GET /api/events`): internetsiz geçmiş (K5).
/// * Yükleniyor / hata + yeniden dene / boş durumları ayrıdır. Hareket v3: satırlar tek seferlik kademeli girer
///   (`MotionScope.off`'ta anında).
///
/// Anahtarlar: `Key('page_alarm_history')`, `Key('alarm_history_error')`, hata kartının `Key('btn_retry')`'i,
/// `Key('alarm_history_empty')`, `Key('row_alarm_<id>')`, `Key('row_event_<eid>')`.
class AlarmHistoryPage extends StatefulWidget {
  const AlarmHistoryPage({super.key, this.note});

  /// Sayfanın üstündeki alt bilgi (bildirimden gelinip alarm kapanmışsa "Bu alarm kapanmış."; F2.C.6).
  final String? note;

  @override
  State<AlarmHistoryPage> createState() => _AlarmHistoryPageState();
}

class _AlarmHistoryPageState extends State<AlarmHistoryPage> {
  AlarmHistory? _history;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final state = context.read<AutomationState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final history = await state.fetchAlarmHistory();
      if (!mounted) return;
      setState(() {
        _history = history;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    final history = _history;
    if (_loading && history == null) {
      body = const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
    } else if (_error != null) {
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: KeyedSubtree(
          key: const Key('alarm_history_error'),
          child: ErrorRetryCard(
            title: 'Alarm geçmişi alınamadı',
            message: friendlyError(_error, fallback: 'Lütfen bağlantınızı kontrol edip tekrar deneyin.'),
            onRetry: () => unawaited(_load()),
            actions: const <Widget>[],
          ),
        ),
      );
    } else if (history == null || history.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.all(16),
        child: InfoCard(
          cardKey: Key('alarm_history_empty'),
          icon: Icons.verified_user_outlined,
          title: 'Kayıtlı alarm yok',
          message: 'Güvenlik sensörlerinden gelen alarmlar burada listelenir.',
        ),
      );
    } else {
      final now = context.read<AutomationState>().clock.now();
      final rows = history.local
          ? <Widget>[for (final e in history.events) _EventRow(key: Key('row_event_${e.eid}'), event: e, now: now)]
          : <Widget>[for (final r in history.records) _RecordRow(key: Key('row_alarm_${r.id}'), record: r, now: now)];
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: rows.length + (history.local ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (history.local && i == 0) {
            return Text(
              'Yerel bağlantı: panonun son olayları gösteriliyor (internet gerekmez).',
              style: TextStyle(fontSize: AppText.caption, color: AppTheme.getTextMuted(context)),
            );
          }
          final index = history.local ? i - 1 : i;
          return StaggeredEntrance(index: index, offset: 8, child: rows[index]);
        },
      );
    }
    return Scaffold(
      key: const Key('page_alarm_history'),
      appBar: NeonAppBar(
        title: 'Alarm Geçmişi',
        icon: Icons.history_rounded,
        family: AppFamilies.rose,
        actions: [
          NeonBarAction(
            key: const Key('btn_alarm_history_refresh'),
            icon: Icons.refresh_rounded,
            tooltip: 'Yenile',
            onTap: () => unawaited(_load()),
          ),
        ],
      ),
      body: widget.note == null
          ? body
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      widget.note!,
                      key: const Key('alarm_history_note'),
                      style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w700, color: AppTheme.getTextPrimary(context)),
                    ),
                  ),
                ),
                Expanded(child: body),
              ],
            ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({super.key, required this.record, required this.now});

  final AlarmRecord record;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final status = alarmRecordStatusOf(record);
    final raised = record.raisedAt;
    return _Row(
      icon: safetyKindIcon(record.kind),
      family: status.family,
      title: safetyKindTitle(record.kind),
      subtitle: <String>[
        'Bölge ${record.zone}',
        if (raised != null) elapsedLabel(raised, now),
      ].join(' · '),
      pill: AppPill(label: status.label, family: status.family, icon: status.icon, maxLines: 1),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({super.key, required this.event, required this.now});

  final DeviceEventRecord event;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final at = epochToDate(event.atEpoch);
    final upMin = event.atUptime == null ? null : event.atUptime! ~/ 60;
    final alarmish = event.type == 'alarm_raised' || event.type == 'valve_fault' || event.type == 'safe_mode';
    return _Row(
      icon: event.type == 'alarm_raised' ? safetyKindIcon(event.kind ?? '') : Icons.event_note_outlined,
      family: alarmish ? AppFamilies.rose : AppFamilies.slate,
      title: deviceEventLabel(event),
      subtitle: <String>[
        if (event.zone != null) 'Bölge ${event.zone}',
        if (at != null) elapsedLabel(at, now) else if (upMin != null) 'açılıştan $upMin dk sonra',
      ].join(' · '),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.family, required this.title, required this.subtitle, this.pill});

  final IconData icon;
  final AccentFamily family;
  final String title;
  final String subtitle;
  final Widget? pill;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      accent: family.base,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          OrbIconBadge(icon: icon, family: family, size: OrbSize.sm),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context)),
                ),
                if (subtitle.isNotEmpty)
                  Text(subtitle, style: TextStyle(fontSize: AppText.caption, color: AppTheme.getTextMuted(context))),
              ],
            ),
          ),
          if (pill != null) ...[const SizedBox(width: 8), pill!],
        ],
      ),
    );
  }
}
