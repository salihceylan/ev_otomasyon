import 'package:flutter/material.dart';

import '../device_connection_panel.dart';
import '../logic/relay_logic.dart';
import '../service_setup_controller.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 7 - Röle Testi: Aç/Kapat -> panonun **gerçek** durum bildirimi -> "yük çalıştı mı?" teyidi.
class Step7Relays extends StatelessWidget {
  const Step7Relays({super.key, required this.controller});

  final ServiceSetupController controller;

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
          : 'Devam etmek için her röleyi test edin (pano cevabı + "yük çalıştı mı?") veya "Kullanılmıyor" işaretleyin.',
      statusText: r.loaded ? '${r.okCount + r.unusedCount}/${r.relays.length} tamam' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeviceConnectionPanel(controller: c),
          if (r.loaded) ...[
            SetupCard(
              key: const Key('relay_summary'),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${r.relays.length} röle: ${r.okCount} doğrulandı • ${r.unusedCount} kullanılmıyor • '
                      '${r.problemCount} sorunlu • ${r.untestedCount} bekliyor',
                      style: TextStyle(fontWeight: FontWeight.w700, color: SetupColors.text(context)),
                    ),
                  ),
                  IconButton(
                    key: const Key('btn_reload_relays'),
                    tooltip: 'Listeyi yenile',
                    onPressed: r.busy ? null : () => r.load(),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            for (final relay in r.relays) _RelayCard(logic: r, relay: relay),
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
    final readable = SetupColors.readable(context, color);
    return SetupCard(
      key: Key('card_relay_$id'),
      accent: verdict == RelayVerdict.untested ? null : color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${relay.name} (Röle $id)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: readable)),
              ),
            ],
          ),
          if (verdict == RelayVerdict.unused)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('btn_relay_unused_$id'),
                onPressed: busy ? null : () => logic.setUnused(id, false),
                child: const Text('Kullanılıyor olarak işaretle'),
              ),
            )
          else ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (relay.isImpulse)
                  ElevatedButton.icon(
                    key: Key('btn_relay_on_$id'),
                    onPressed: busy ? null : () => logic.command(id, true),
                    icon: const Icon(Icons.touch_app_rounded, size: 18),
                    label: const Text('Tetikle'),
                    style: ElevatedButton.styleFrom(minimumSize: const Size(96, 48)),
                  )
                else ...[
                  ElevatedButton.icon(
                    key: Key('btn_relay_on_$id'),
                    onPressed: busy ? null : () => logic.command(id, true),
                    icon: const Icon(Icons.lightbulb_rounded, size: 18),
                    label: const Text('Aç'),
                    style: ElevatedButton.styleFrom(minimumSize: const Size(96, 48)),
                  ),
                  OutlinedButton.icon(
                    key: Key('btn_relay_off_$id'),
                    onPressed: busy ? null : () => logic.command(id, false),
                    icon: const Icon(Icons.lightbulb_outline_rounded, size: 18),
                    label: const Text('Kapat'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
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
                if (!relay.isImpulse)
                  _FeedbackChip(
                    label: relay.sawOff ? 'Pano: kapandı ✔' : 'Pano: kapanma bekleniyor',
                    ok: relay.sawOff,
                  ),
              ],
            ),
            if (relay.awaitingLitAnswer) ...[
              const SizedBox(height: 8),
              Text(
                'Lamba / yük gerçekten çalıştı mı?',
                style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context)),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    key: Key('btn_relay_lit_yes_$id'),
                    onPressed: busy ? null : () => logic.confirmLit(id, true),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(96, 48),
                      backgroundColor: SetupColors.ok,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Evet, çalıştı'),
                  ),
                  OutlinedButton(
                    key: Key('btn_relay_lit_no_$id'),
                    onPressed: busy ? null : () => logic.confirmLit(id, false),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
                    child: const Text('Hayır, çalışmadı'),
                  ),
                ],
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
            Wrap(
              spacing: 8,
              children: [
                if (verdict == RelayVerdict.problem || verdict == RelayVerdict.ok)
                  TextButton(
                    key: Key('btn_relay_reset_$id'),
                    onPressed: busy ? null : () => logic.resetRelay(id),
                    child: const Text('Yeniden test et'),
                  ),
                TextButton(
                  key: Key('btn_relay_unused_$id'),
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
    return Text(
      label,
      style: TextStyle(fontSize: 12.5, fontWeight: ok ? FontWeight.w800 : FontWeight.w500, color: ok ? SetupColors.readable(context, SetupColors.ok) : color),
    );
  }
}
