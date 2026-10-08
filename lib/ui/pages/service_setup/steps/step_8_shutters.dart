import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../common/app_dialogs.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb.dart';
import '../../../widgets/settings/accent_button.dart';
import '../../../widgets/shutter_visual.dart';
import '../device_connection_panel.dart';
import '../logic/shutter_logic.dart';
import '../service_setup_controller.dart';
import '../setup_fields.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 8 - Panjur Testi ve Kalibrasyon: yön testi + kronometre ile tam açılma süresi ölçümü.
class Step8Shutters extends StatelessWidget {
  const Step8Shutters({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.shutters;
    final ready = s.shutters.where((x) => x.isReady).length;
    return stepScaffold(
      context,
      c,
      8,
      continueHint: s.loaded && !s.hasNoShutters && s.shutters.every((x) => x.unused) && !s.noMotorizedDeclared
          ? 'En az bir panjuru gerçekten test edin (yön + süre) ya da dairede motorlu panjur yoksa "Bu dairede motorlu '
              'panjur yok" ile beyan edin.'
          : 'Devam etmek için her panjurun yönünü onaylayın ve süresini kaydedin (veya "Kullanılmıyor" işaretleyin).',
      statusText: s.loaded ? (s.hasNoShutters ? 'Panjur yok' : '$ready/${s.shutters.length} hazır') : null,
      // Ekranda zaten gradyan birincil var ("Panoya Bağlan" / "Panjurları Listele"): hata kutusundaki "Tekrar dene" çerçeveli.
      retrySecondary: !c.conn.ready || !s.loaded,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeviceConnectionPanel(controller: c),
          if (s.hasNoShutters)
            const SetupCard(
              key: Key('shutter_none_card'),
              child: SetupInfoRow(
                icon: Icons.info_outline_rounded,
                text: 'Bu panoda panjur çıkışı yok. Bu adım tamamlanmış sayılır; "Devam"a basabilirsiniz.',
              ),
            )
          else if (s.loaded) ...[
            for (final shutter in s.shutters)
              _ShutterCard(key: Key('card_shutter_${shutter.pair}'), controller: c, pair: shutter.pair),
            // Tüm çiftler "kullanılmıyor": dairede motorlu panjur yoksa teknisyen beyanıyla adım tamamlanır (servis_kurulum-3).
            if (s.shutters.every((x) => x.unused) && !s.noMotorizedDeclared)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  key: const Key('btn_no_motorized_shutters'),
                  onPressed: s.busy ? null : () => _declareNoMotorized(context, s),
                  icon: const Icon(Icons.block_rounded, size: 18),
                  label: const Text('Bu dairede motorlu panjur yok'),
                ),
              ),
            if (s.noMotorizedDeclared)
              const SetupCard(
                key: Key('shutter_no_motor_note'),
                child: SetupInfoRow(
                  icon: Icons.info_outline_rounded,
                  text: 'Dairede motorlu panjur yok (teknisyen beyanı): teslim raporuna beyan olarak yazılır.',
                ),
              ),
          ]
          else if (!s.busy && c.conn.ready)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SetupPrimaryButton(
                key: const Key('btn_load_shutters'),
                label: 'Panjurları Listele',
                icon: Icons.list_alt_rounded,
                onPressed: () => s.load(),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Bu dairede motorlu panjur yok" beyanı onayla kaydedilir (servis_kurulum-3).
Future<void> _declareNoMotorized(BuildContext context, ShutterLogic s) async {
  final ok = await showAppDialog<bool>(
    context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Dairede motorlu panjur yok mu?'),
      content: const Text(
        'Panoda panjur çiftleri tanımlı ama dairede motorlu panjur yoksa onaylayın. Panjur testi yapılmaz; teslim raporuna '
        '"dairede motorlu panjur yok (teknisyen beyanı)" yazılır.',
      ),
      actions: [
        TextButton(
          key: const Key('btn_no_motor_cancel'),
          style: AppTheme.quietTextButtonStyle(ctx),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Vazgeç'),
        ),
        ElevatedButton(
          key: const Key('btn_no_motor_confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Onaylıyorum'),
        ),
      ],
    ),
  );
  if (ok == true) await s.declareNoMotorizedShutters();
}

class _ShutterCard extends StatefulWidget {
  const _ShutterCard({super.key, required this.controller, required this.pair});

  final ServiceSetupController controller;
  final int pair;

  @override
  State<_ShutterCard> createState() => _ShutterCardState();
}

class _ShutterCardState extends State<_ShutterCard> {
  final TextEditingController _manual = TextEditingController();
  bool _showManual = false;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  ShutterLogic get _logic => widget.controller.shutters;
  int get _pair => widget.pair;

  @override
  Widget build(BuildContext context) {
    final s = _logic.byPair(_pair);
    if (s == null) return const SizedBox.shrink();
    final busy = _logic.busy;
    final Color color;
    final String label;
    if (s.unused) {
      color = SetupColors.warn;
      label = 'Kullanılmıyor';
    } else if (s.isReady) {
      color = SetupColors.ok;
      label = 'Hazır • ${s.savedSeconds} sn';
    } else if (s.verdict == ShutterDirectionVerdict.reversed) {
      color = SetupColors.error;
      label = 'Yön ters';
    } else {
      color = SetupColors.info;
      label = 'Bekliyor';
    }
    final live = s.moving ? (s.direction == 1 ? 'yukarı gidiyor' : 'aşağı gidiyor') : 'duruyor';
    return SetupCard(
      accent: (s.isReady || s.unused || s.verdict == ShutterDirectionVerdict.reversed) ? color : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!s.unused) ...[
                // Mini panjur görseli: panonun bildirdiği konum; hareket sırasında yumuşak akar.
                ShutterVisual(
                  position: s.pos.toDouble(),
                  moving: s.moving,
                  muted: !s.moving && s.verdict == ShutterDirectionVerdict.unknown,
                  accent: s.moving ? (s.direction == 1 ? AppFamilies.emerald.base : AppFamilies.sky.base) : null,
                  width: 44,
                  height: 50,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // Ad zaten "Panjur N" ise parantez tekrarı gizlenir ("Panjur 1 (Panjur 1)" anlamsızdı).
                      s.name == 'Panjur ${s.pair}' ? s.name : '${s.name} (Panjur ${s.pair})',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                    ),
                    const SizedBox(height: 6),
                    SetupVerdictChip(key: Key('shutter_status_${s.pair}'), label: label, color: color),
                  ],
                ),
              ),
            ],
          ),
          if (s.unused)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('btn_shutter_unused_${s.pair}'),
                style: setupInlineActionStyle(),
                onPressed: busy ? null : () => _logic.setUnused(s.pair, false),
                child: const Text('Kullanılıyor olarak işaretle'),
              ),
            )
          else ...[
            const SizedBox(height: 8),
            Text(
              'Pano: $live • konum %${s.pos}',
              key: Key('shutter_live_${s.pair}'),
              style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
            ),
            const SizedBox(height: 8),
            _directionSection(context, s, busy),
            if (s.verdict == ShutterDirectionVerdict.ok) _calibrationSection(context, s, busy),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('btn_shutter_unused_${s.pair}'),
                style: setupInlineActionStyle(),
                onPressed: busy ? null : () => _confirmUnused(s.pair),
                child: const Text('Bu panjur kullanılmıyor'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "Kullanılmıyor" bir **beyandır** (test yapılmaz): onay istenir, teslim raporuna beyan olarak yazılır.
  Future<void> _confirmUnused(int pair) async {
    final ok = await showAppDialog<bool>(
      context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Bu panjur kullanılmıyor mu?'),
        content: const Text(
          'Panoda bu panjur için röle çıkışları tanımlı ama motor bağlı değilse işaretleyin. Bu panjur test edilmez; '
          'teslim raporuna "kullanılmıyor (teknisyen beyanı)" yazılır. Hiçbir panjur test edilmeyecekse adım yalnız '
          '"Bu dairede motorlu panjur yok" beyanıyla geçilir.',
        ),
        actions: [
          TextButton(
            key: const Key('btn_shutter_unused_cancel'),
            style: AppTheme.quietTextButtonStyle(ctx),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton(
            key: const Key('btn_shutter_unused_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Evet, kullanılmıyor'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _logic.setUnused(pair, true);
  }

  // ---------------------------------------------------------------------------
  // Yön testi
  // ---------------------------------------------------------------------------
  Widget _directionSection(BuildContext context, ShutterCheck s, bool busy) {
    final text = SetupColors.text(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('1) Yön testi', style: TextStyle(fontWeight: FontWeight.w800, color: text)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            SetupOrbAction(
              orbKey: Key('btn_shutter_up_${s.pair}'),
              icon: Icons.arrow_upward_rounded,
              family: AppFamilies.emerald,
              label: 'Yukarı',
              active: s.moving && s.direction == 1,
              onTap: busy ? null : () => _logic.move(s.pair, 'up'),
            ),
            SetupOrbAction(
              orbKey: Key('btn_shutter_stop_${s.pair}'),
              icon: Icons.stop_rounded,
              family: AppFamilies.rose,
              label: 'Dur',
              onTap: busy ? null : () => _logic.move(s.pair, 'stop'),
            ),
            SetupOrbAction(
              orbKey: Key('btn_shutter_down_${s.pair}'),
              icon: Icons.arrow_downward_rounded,
              family: AppFamilies.sky,
              label: 'Aşağı',
              active: s.moving && s.direction == 2,
              onTap: busy ? null : () => _logic.move(s.pair, 'down'),
            ),
          ],
        ),
        if (s.verdict == ShutterDirectionVerdict.unknown && s.upAcked) ...[
          const SizedBox(height: 10),
          Text('Panjur gerçekten YUKARI mı gitti?', style: TextStyle(fontWeight: FontWeight.w800, color: text)),
          const SizedBox(height: 6),
          SetupChoicePair(
            primary: ElevatedButton(
              key: Key('btn_dir_ok_${s.pair}'),
              onPressed: busy ? null : () => _logic.confirmDirection(s.pair, wentUp: true),
              style: accentButtonStyle(AppFamilies.emerald, minimumSize: const Size(96, 48)),
              child: const Text('Evet, yukarı gitti'),
            ),
            secondary: OutlinedButton(
              key: Key('btn_dir_wrong_${s.pair}'),
              onPressed: busy ? null : () => _logic.confirmDirection(s.pair, wentUp: false),
              style: accentOutlinedButtonStyle(context, AppFamilies.rose, minimumSize: const Size(96, 48)),
              child: const Text('Hayır, aşağı gitti'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Panjur hareket ediyorsa önce "Dur"a basın.',
            style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
          ),
        ],
        if (s.verdict == ShutterDirectionVerdict.reversed) ...[
          const SizedBox(height: 8),
          SetupCard(
            key: Key('shutter_reversed_${s.pair}'),
            accent: SetupColors.error,
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SetupInfoRow(
                  icon: Icons.swap_vert_rounded,
                  color: SetupColors.error,
                  bold: true,
                  text: s.note ?? 'Yön ters: YUKARI ve AŞAĞI kablolarını yer değiştirin.',
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  key: Key('btn_retest_dir_${s.pair}'),
                  onPressed: busy ? null : () => _logic.retestDirection(s.pair),
                  icon: Icon(Icons.replay_rounded, size: accentIconSize(context, base: 18)),
                  label: const Text('Düzelttim, yeniden dene'),
                  // Çerçeve + metin + simge AYNI aileden ve AA (tema varsayılan çerçevesi açıkta ≈ 2.4:1'di).
                  style: accentOutlinedButtonStyle(context, AppFamilies.rose),
                ),
              ],
            ),
          ),
        ],
        if (s.verdict == ShutterDirectionVerdict.ok)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: SetupInfoRow(icon: Icons.check_circle_rounded, color: SetupColors.ok, text: 'Yön doğrulandı.'),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Süre ölçümü
  // ---------------------------------------------------------------------------
  Widget _calibrationSection(BuildContext context, ShutterCheck s, bool busy) {
    final text = SetupColors.text(context);
    final children = <Widget>[
      const SizedBox(height: 12),
      Text('2) Tam açılma süresi', style: TextStyle(fontWeight: FontWeight.w800, color: text)),
      const SizedBox(height: 6),
    ];

    if (s.savedSeconds != null) {
      children.addAll([
        SetupInfoRow(
          icon: Icons.verified_rounded,
          color: SetupColors.ok,
          bold: true,
          text: 'Kayıtlı süre: ${s.savedSeconds} sn (sunucuya kaydedildi, panoda doğrulandı).',
        ),
        TextButton.icon(
          key: Key('btn_remeasure_${s.pair}'),
          style: setupInlineActionStyle(),
          onPressed: busy ? null : () => _logic.remeasure(s.pair),
          icon: Icon(Icons.timer_outlined, size: accentIconSize(context, base: 18)),
          label: const Text('Yeniden ölç'),
        ),
      ]);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    }

    switch (s.phase) {
      case MeasurePhase.idle:
        children.addAll([
          Text(
            'Önce "Ölçüme Hazırla": ölçüm sırasında panonun röleyi erken kapatmaması için süre geçici olarak 300 sn yapılır.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: SetupColors.muted(context)),
          ),
          const SizedBox(height: 8),
          SetupPrimaryButton(
            key: Key('btn_prepare_${s.pair}'),
            label: 'Ölçüme Hazırla',
            icon: Icons.timer_rounded,
            onPressed: busy ? null : () => _logic.prepareMeasure(s.pair),
          ),
          TextButton.icon(
            key: Key('btn_toggle_manual_${s.pair}'),
            style: setupInlineActionStyle(),
            onPressed: () => setState(() => _showManual = !_showManual),
            icon: Icon(
              _showManual ? Icons.expand_less_rounded : Icons.edit_rounded,
              size: accentIconSize(context, base: 18),
            ),
            label: Text(_showManual ? 'Elle girmeyi gizle' : 'Süreyi biliyorum: elle gireceğim'),
          ),
          if (_showManual) ...[
            SetupTextField(
              key: Key('field_runtime_${s.pair}'),
              controller: _manual,
              label: 'Tam açılma süresi (saniye, 1-300)',
              keyboardType: TextInputType.number,
              inputFormatters: [digitsOnly],
              maxLength: 3,
              prefixIcon: Icons.timer_outlined,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: Key('btn_manual_runtime_${s.pair}'),
              onPressed: busy
                  ? null
                  : () {
                      final value = int.tryParse(_manual.text.trim());
                      _logic.setManualSeconds(s.pair, value ?? 0);
                    },
              icon: Icon(Icons.check_rounded, size: accentIconSize(context, base: 18)),
              label: const Text('Bu Süreyi Kullan'),
              style: accentOutlinedButtonStyle(context, AppFamilies.sky),
            ),
          ],
        ]);
      case MeasurePhase.prepared:
        children.addAll([
          const SetupInfoRow(
            icon: Icons.check_circle_rounded,
            color: SetupColors.ok,
            text: 'Ölçüm süresi panoya yazıldı. Şimdi panjuru EN ALTA indirin.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                key: Key('btn_to_bottom_${s.pair}'),
                onPressed: busy ? null : () => _logic.driveToBottom(s.pair),
                icon: const Icon(Icons.keyboard_double_arrow_down_rounded),
                label: const Text('Alta İndir'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(96, 48)),
              ),
              ElevatedButton.icon(
                key: Key('btn_at_bottom_${s.pair}'),
                onPressed: busy ? null : () => _logic.bottomReached(s.pair),
                icon: const Icon(Icons.vertical_align_bottom_rounded),
                label: const Text('Alta indi'),
                style: accentButtonStyle(AppFamilies.emerald, minimumSize: const Size(96, 48)),
              ),
            ],
          ),
        ]);
      case MeasurePhase.atBottom:
        children.addAll([
          const SetupInfoRow(
            icon: Icons.vertical_align_bottom_rounded,
            text:
                'Panjur en altta. "Ölçümü Başlat"a basınca panjur yukarı çıkar ve kronometre başlar; '
                'panjur TAM AÇILINCA "Bitti"ye basın.',
          ),
          const SizedBox(height: 8),
          SetupPrimaryButton(
            key: Key('btn_start_measure_${s.pair}'),
            label: 'Ölçümü Başlat',
            icon: Icons.play_arrow_rounded,
            onPressed: busy ? null : () => _logic.startMeasure(s.pair),
          ),
        ]);
      case MeasurePhase.running:
        children.addAll([
          Center(
            child: ValueListenableBuilder<int>(
              valueListenable: widget.controller.clockTick,
              builder: (context, _, _) {
                final started = s.measureStartedAt;
                final elapsed = started == null
                    ? Duration.zero
                    : widget.controller.ctx.clock.now().difference(started);
                return _StopwatchRing(seconds: elapsed.inSeconds, textKey: Key('shutter_stopwatch_${s.pair}'));
              },
            ),
          ),
          const SizedBox(height: 8),
          SetupPrimaryButton(
            key: Key('btn_finish_measure_${s.pair}'),
            label: 'Bitti: panjur tam açıldı',
            icon: Icons.flag_rounded,
            color: SetupColors.ok,
            onPressed: busy ? null : () => _logic.finishMeasure(s.pair),
          ),
          TextButton(
            key: Key('btn_cancel_measure_${s.pair}'),
            style: setupInlineActionStyle(),
            onPressed: busy ? null : () => _logic.cancelMeasure(s.pair),
            child: const Text('Ölçümü iptal et'),
          ),
        ]);
      case MeasurePhase.measured:
        children.addAll([
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GlassIconButton(
                key: Key('btn_sec_minus_${s.pair}'),
                icon: Icons.remove_rounded,
                semanticLabel: '1 saniye azalt',
                onTap: busy ? null : () => _logic.adjustMeasured(s.pair, -1),
              ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    '${s.measuredSeconds ?? 0} sn',
                    key: Key('shutter_measured_${s.pair}'),
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: text,
                    ),
                  ),
                ),
              ),
              GlassIconButton(
                key: Key('btn_sec_plus_${s.pair}'),
                icon: Icons.add_rounded,
                semanticLabel: '1 saniye artır',
                onTap: busy ? null : () => _logic.adjustMeasured(s.pair, 1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SetupPrimaryButton(
            key: Key('btn_save_runtime_${s.pair}'),
            label: 'Kaydet ve Panoda Doğrula',
            icon: Icons.save_rounded,
            color: SetupColors.ok,
            busy: busy,
            onPressed: busy ? null : () => _logic.saveRuntime(s.pair),
          ),
        ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// Süre ölçümü kronometresi: büyük tabular saniye sayacı + çevresinde dakika halkası (her 60 sn'de bir tur;
/// saniyede bir yeniden çizilir, ambient/animasyon yok).
class _StopwatchRing extends StatelessWidget {
  const _StopwatchRing({required this.seconds, required this.textKey});

  final int seconds;
  final Key textKey;

  @override
  Widget build(BuildContext context) {
    final family = AppFamilies.sky;
    return SizedBox.square(
      dimension: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              size: const Size.square(132),
              painter: _MinuteRingPainter(
                fraction: (seconds % 60) / 60.0,
                color: SetupColors.isDark(context) ? family.light : family.base,
                track: SetupColors.border(context),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$seconds sn',
                key: textKey,
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: SetupColors.text(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MinuteRingPainter extends CustomPainter {
  const _MinuteRingPainter({required this.fraction, required this.color, required this.track});

  final double fraction;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 8.0;
    final rect = (Offset.zero & size).deflate(stroke);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track.withValues(alpha: 0.6),
    );
    final sweep = math.max(fraction, 0.02) * math.pi * 2;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_MinuteRingPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}
