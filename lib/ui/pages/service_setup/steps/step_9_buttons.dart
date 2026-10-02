import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../device_connection_panel.dart';
import '../logic/button_logic.dart';
import '../service_setup_controller.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 9 - Duvar Butonları: dinleme açıkken butona basılınca pano giriş durumunu bildirir -> işaretlenir.
class Step9Buttons extends StatelessWidget {
  const Step9Buttons({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final b = c.buttons;
    final done = b.detectedCount + b.noneCount;
    return stepScaffold(
      context,
      c,
      9,
      continueHint: 'Devam etmek için her girişe bağlı butona basın (algılanır) ya da "Buton yok" işaretleyin.',
      statusText: b.loaded ? (b.hasNoInputs ? 'Giriş yok' : '$done/${b.buttons.length} tamam') : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeviceConnectionPanel(controller: c),
          if (b.childLockOn)
            const SetupCard(
              key: Key('button_childlock_card'),
              accent: SetupColors.warn,
              child: SetupInfoRow(
                icon: Icons.child_care_rounded,
                color: SetupColors.warn,
                text: 'Çocuk kilidi AÇIK: duvar butonları röleleri tetiklemez. Basışlar yine de algılanır; '
                    'butonların ışığı/rölesi çalışmayabilir.',
              ),
            ),
          if (b.hasNoInputs)
            const SetupCard(
              key: Key('button_none_card'),
              child: SetupInfoRow(
                icon: Icons.info_outline_rounded,
                text: 'Pano duvar butonu girişi bildirmedi. Bu adım tamamlanmış sayılır; "Devam"a basabilirsiniz.',
              ),
            )
          else if (b.loaded) ...[
            SetupCard(
              key: const Key('button_listen_card'),
              accent: b.listening ? SetupColors.ok : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    b.listening
                        ? 'Dinleniyor: şimdi duvardaki butonlara sırayla basın (1 saniye basılı tutun).'
                        : 'Dinlemeyi başlatın, sonra duvardaki butonlara sırayla basın.',
                    style: TextStyle(fontWeight: FontWeight.w700, height: 1.35, color: SetupColors.text(context)),
                  ),
                  const SizedBox(height: 10),
                  SetupPrimaryButton(
                    key: const Key('btn_listen_toggle'),
                    label: b.listening ? 'Dinlemeyi Durdur' : 'Dinlemeyi Başlat',
                    icon: b.listening ? Icons.stop_circle_rounded : Icons.sensors_rounded,
                    color: b.listening ? SetupColors.error : SetupColors.primary,
                    onPressed: () => b.listening ? b.stopListening() : b.startListening(),
                  ),
                ],
              ),
            ),
            for (final button in b.buttons) _ButtonCard(logic: b, button: button),
          ] else if (!b.busy && c.conn.ready)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SetupPrimaryButton(
                key: const Key('btn_load_buttons'),
                label: 'Girişleri Listele',
                icon: Icons.list_alt_rounded,
                onPressed: () => b.load(),
              ),
            ),
        ],
      ),
    );
  }
}

class _ButtonCard extends StatelessWidget {
  const _ButtonCard({required this.logic, required this.button});

  final ButtonLogic logic;
  final ButtonCheck button;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    switch (button.verdict) {
      case ButtonVerdict.detected:
        color = SetupColors.ok;
        label = 'Algılandı';
      case ButtonVerdict.none:
        color = SetupColors.warn;
        label = 'Buton yok';
      case ButtonVerdict.untested:
        color = SetupColors.info;
        label = 'Bekliyor';
    }
    final at = button.detectedAt;
    return SetupCard(
      key: Key('card_button_${button.id}'),
      accent: button.verdict == ButtonVerdict.untested ? null : color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                button.pressed ? Icons.touch_app_rounded : Icons.radio_button_unchecked_rounded,
                color: button.pressed ? SetupColors.ok : SetupColors.muted(context),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${button.name} (Giriş ${button.id})',
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
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: SetupColors.readable(context, color)),
                ),
              ),
            ],
          ),
          if (button.pressed)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Şu an basılı görünüyor', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          if (at != null && button.verdict == ButtonVerdict.detected)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Basış algılandı: ${DateFormat('HH:mm:ss').format(at.toLocal())}',
                style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (button.verdict == ButtonVerdict.none)
                TextButton(
                  key: Key('btn_button_none_${button.id}'),
                  onPressed: () => logic.markNone(button.id, false),
                  child: const Text('Buton var, tekrar dene'),
                )
              else
                TextButton(
                  key: Key('btn_button_none_${button.id}'),
                  onPressed: () => logic.markNone(button.id, true),
                  child: const Text('Bu girişte buton yok'),
                ),
              if (button.verdict == ButtonVerdict.detected)
                TextButton(
                  key: Key('btn_button_reset_${button.id}'),
                  onPressed: () => logic.reset(button.id),
                  child: const Text('Yeniden dene'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
