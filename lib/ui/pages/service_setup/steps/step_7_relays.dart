import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb.dart';
import '../../../widgets/settings/accent_button.dart';

import '../device_connection_panel.dart';
import '../logic/relay_logic.dart';
import '../panel/service_glass.dart';
import '../service_setup_controller.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_7_safety.dart';
import 'step_common.dart';

/// Adım 7 - Röle Testi: Aç/Kapat -> panonun **gerçek** durum bildirimi -> "yük çalıştı mı?" teyidi.
class Step7Relays extends StatelessWidget {
  const Step7Relays({super.key, required this.controller});

  final ServiceSetupController controller;

  /// Sayaç hapının rengi: sayı 0 ise nötr (slate), değilse anlamsal renk.
  static Color _tone(int count, Color color) => count == 0 ? AppFamilies.slate.base : color;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final r = c.relays;
    return stepScaffold(
      context,
      c,
      7,
      continueHint: r.problemCount > 0
          ? 'Sorunlu röle var: düzeltip yeniden test edin ya da "Kullanılmıyor" işaretleyin.'
          : (r.needsSafetySave
              ? 'Güvenlik cihazı atamalarını "Güvenlik Ayarlarını Panoya Yaz" ile kaydedin.'
              : 'Devam etmek için her röleyi test edin (pano cevabı + "yük çalıştı mı?") veya "Kullanılmıyor" işaretleyin.'),
      statusText: r.loaded ? '${r.okCount + r.unusedCount}/${r.relays.length} tamam' : null,
      // Ekranda zaten gradyan birincil var ("Panoya Bağlan" / "Röleleri Listele"): hata kutusundaki "Tekrar dene" aynı işi yapar,
      // çerçeveli ikincil olur (asıl kurtarma eylemi belli olsun).
      retrySecondary: !c.conn.ready || !r.loaded,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeviceConnectionPanel(controller: c),
          if (r.loaded) ...[
            SetupCard(
              key: const Key('relay_summary'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    // Dört sayaç AYRI hap (eskiden tek kalın cümle: "• 0" satır sonunda kalıp "sorunlu" alta düşüyordu).
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${r.relays.length} röle',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            // Sayacı 0 olan hap NÖTR (slate): "0 sorunlu" kırmızı olunca hiç sorun yokken bile "hata var"
                            // izlenimi veriyordu; renk anlamı yalnız sayı > 0 iken taşınır.
                            ServiceStatusPill(label: '${r.okCount} doğrulandı', color: _tone(r.okCount, SetupColors.ok)),
                            ServiceStatusPill(label: '${r.unusedCount} kullanılmıyor', color: _tone(r.unusedCount, SetupColors.warn)),
                            ServiceStatusPill(label: '${r.problemCount} sorunlu', color: _tone(r.problemCount, SetupColors.error)),
                            ServiceStatusPill(label: '${r.untestedCount} bekliyor', color: _tone(r.untestedCount, SetupColors.info)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassIconButton(
                    key: const Key('btn_reload_relays'),
                    icon: Icons.refresh_rounded,
                    semanticLabel: 'Listeyi yenile',
                    onTap: r.busy ? null : () => r.load(),
                  ),
                ],
              ),
            ),
            for (final relay in r.relays) _RelayCard(logic: r, relay: relay),
            SafetyInputsCard(logic: r),
            SafetySaveCard(logic: r),
          ] else if (!r.busy && c.conn.ready)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SetupPrimaryButton(
                key: const Key('btn_load_relays'),
                label: 'Röleleri Listele',
                icon: Icons.list_alt_rounded,
                onPressed: () => r.load(),
              ),
            ),
        ],
      ),
    );
  }
}

class _RelayCard extends StatelessWidget {
  const _RelayCard({required this.logic, required this.relay});

  final RelayLogic logic;
  final RelayCheck relay;

  @override
  Widget build(BuildContext context) {
    final id = relay.id;
    final busy = logic.busy;
    final verdict = relay.verdict;
    final Color color;
    final String label;
    switch (verdict) {
      case RelayVerdict.ok:
        color = SetupColors.ok;
        label = 'Doğrulandı';
      case RelayVerdict.problem:
        color = SetupColors.error;
        label = 'Sorun var';
      case RelayVerdict.unused:
        color = SetupColors.warn;
        label = 'Kullanılmıyor';
      case RelayVerdict.untested:
        color = SetupColors.info;
        label = 'Bekliyor';
    }
    return SetupCard(
      key: Key('card_relay_$id'),
      accent: verdict == RelayVerdict.untested ? null : color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OrbIconBadge(
                icon: relay.isImpulse ? Icons.bolt_rounded : Icons.lightbulb_rounded,
                // Kapalı röle koyu cam (slate) orb: etkileşimli "Aç" orb'uyla (amber) karışmaz; yanık ve sorunlu durum renklenir.
                family: verdict == RelayVerdict.problem
                    ? AppFamilies.rose
                    : (relay.state ? AppFamilies.amber : AppFamilies.slate),
                active: relay.state,
                status: verdict == RelayVerdict.ok ? OrbStatus.success : OrbStatus.none,
                enabled: verdict != RelayVerdict.unused,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${relay.name} (Röle $id)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SetupVerdictChip(label: label, color: color),
          ),
          if (verdict == RelayVerdict.unused)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('btn_relay_unused_$id'),
                style: setupInlineActionStyle(),
                onPressed: busy ? null : () => logic.setUnused(id, false),
                child: const Text('Kullanılıyor olarak işaretle'),
              ),
            )
          else ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                if (relay.boardActuator)
                  SetupOrbAction(
                    orbKey: Key('btn_relay_zone_test_$id'),
                    icon: Icons.science_outlined,
                    family: AppFamilies.sky,
                    label: 'Bölge Testi',
                    onTap: busy
                        ? null
                        : () async {
                            // F2.A.3: gaz vanalı bölgede test vanayı kapalı bırakır; önce sorulur.
                            final zone = logic.byId(id)?.assign.zone;
                            final gas = logic.assignments.values.any((a) => a.isGasValve && a.zone == zone);
                            if (await confirmGasValveTest(context, hasGasValve: gas)) await logic.testActuator(id);
                          },
                  )
                else if (relay.isImpulse)
                  SetupOrbAction(
                    orbKey: Key('btn_relay_on_$id'),
                    icon: Icons.bolt_rounded,
                    family: AppFamilies.amber,
                    label: 'Tetikle',
                    onTap: busy ? null : () => logic.command(id, true),
                  )
                else ...[
                  SetupOrbAction(
                    orbKey: Key('btn_relay_on_$id'),
                    icon: Icons.lightbulb_rounded,
                    family: AppFamilies.amber,
                    label: 'Aç',
                    active: relay.state,
                    onTap: busy ? null : () => logic.command(id, true),
                  ),
                  SetupOrbAction(
                    orbKey: Key('btn_relay_off_$id'),
                    icon: Icons.lightbulb_outline_rounded,
                    family: AppFamilies.slate,
                    label: 'Kapat',
                    onTap: busy ? null : () => logic.command(id, false),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                _FeedbackChip(
                  label: relay.sawOn
                      ? 'Pano: açıldı ✔'
                      : (relay.isImpulse && relay.cmdSent
                            ? 'Pano: komutu kabul etti (geri bildirim görülemedi)'
                            : 'Pano: açma bekleniyor'),
                  ok: relay.sawOn || (relay.isImpulse && relay.cmdSent),
                ),
                if (!relay.isImpulse && !relay.boardActuator)
                  _FeedbackChip(label: relay.sawOff ? 'Pano: kapandı ✔' : 'Pano: kapanma bekleniyor', ok: relay.sawOff),
              ],
            ),
            if (relay.awaitingLitAnswer) ...[
              const SizedBox(height: 8),
              Text(
                'Lamba / yük gerçekten çalıştı mı?',
                style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context)),
              ),
              const SizedBox(height: 6),
              SetupChoicePair(
                primary: ElevatedButton(
                  key: Key('btn_relay_lit_yes_$id'),
                  onPressed: busy ? null : () => logic.confirmLit(id, true),
                  style: accentButtonStyle(AppFamilies.emerald, minimumSize: const Size(96, 48)),
                  child: const Text('Evet, çalıştı'),
                ),
                secondary: OutlinedButton(
                  key: Key('btn_relay_lit_no_$id'),
                  onPressed: busy ? null : () => logic.confirmLit(id, false),
                  // Olumsuz yanıt gül (rose) çerçeveli: anlamsal renk metin + çerçevede aynı.
                  style: accentOutlinedButtonStyle(context, AppFamilies.rose, minimumSize: const Size(96, 48)),
                  child: const Text('Hayır, çalışmadı'),
                ),
              ),
            ],
            if (relay.info != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SetupInfoRow(
                  key: Key('relay_info_$id'),
                  icon: Icons.info_outline_rounded,
                  color: SetupColors.info,
                  text: relay.info!,
                ),
              ),
            if (relay.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SetupInfoRow(icon: Icons.warning_amber_rounded, color: SetupColors.error, text: relay.note!),
              ),
            RelayAssignmentPanel(logic: logic, relay: relay),
            Wrap(
              spacing: 8,
              children: [
                if (verdict == RelayVerdict.problem || verdict == RelayVerdict.ok)
                  TextButton(
                    key: Key('btn_relay_reset_$id'),
                    style: setupInlineActionStyle(),
                    onPressed: busy ? null : () => logic.resetRelay(id),
                    child: const Text('Yeniden test et'),
                  ),
                TextButton(
                  key: Key('btn_relay_unused_$id'),
                  style: setupInlineActionStyle(),
                  onPressed: busy ? null : () => logic.setUnused(id, true),
                  child: const Text('Kullanılmıyor'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FeedbackChip extends StatelessWidget {
  const _FeedbackChip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? SetupColors.ok : SetupColors.muted(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: 6),
          child: SizedBox.square(
            dimension: 12,
            child: Center(child: GlowDot(color: color, size: 7)),
          ),
        ),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: ok ? FontWeight.w800 : FontWeight.w500,
              color: ok ? SetupColors.readable(context, SetupColors.ok) : color,
            ),
          ),
        ),
      ],
    );
  }
}
