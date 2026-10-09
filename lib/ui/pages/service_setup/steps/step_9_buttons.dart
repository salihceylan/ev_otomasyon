import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../motion/pulse_ring.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb.dart';
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
    // Tüm girişler tamamlandı: asıl ilerleme eylemi alttaki "Devam"dır; dinleme düğmesi gradyan olmaz (aksi halde iki doygun
    // gradyan yarışır: kırmızı "Dinlemeyi Durdur" + zümrüt "Devam").
    final allDone = b.loaded && b.buttons.isNotEmpty && done >= b.buttons.length;
    // Dinleme düğmesi, pano bağlıyken ve işimiz bitmemişken sayfanın birincil eylemidir; pano bağlı değilken birincil
    // "Panoya Bağlan"dır ve dinleme düğmesi çerçeveli kalır.
    final listenIsPrimary = c.conn.ready && !allDone;
    return stepScaffold(
      context,
      c,
      9,
      continueHint: 'Devam etmek için her girişe bağlı butona basın (algılanır) ya da "Buton yok" işaretleyin.',
      statusText: b.loaded ? (b.hasNoInputs ? 'Giriş yok' : '$done/${b.buttons.length} tamam') : null,
      // Ekranda zaten gradyan birincil var ("Panoya Bağlan" / dinleme / "Girişleri Listele"): "Tekrar dene" çerçeveli.
      retrySecondary: !c.conn.ready || !b.loaded || b.listening,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeviceConnectionPanel(controller: c),
          if (b.loaded && b.safetyInputCount > 0)
            SetupInfoRow(
              key: const Key('button_safety_inputs_note'),
              icon: Icons.shield_outlined,
              color: SetupColors.info,
              text: 'Güvenlik girişleri (${b.safetyInputCount}) bu adımda gösterilmez.',
            ),
          if (b.childLockOn)
            const SetupCard(
              key: Key('button_childlock_card'),
              accent: SetupColors.warn,
              child: SetupInfoRow(
                icon: Icons.child_care_rounded,
                color: SetupColors.warn,
                text:
                    'Çocuk kilidi AÇIK: duvar butonları röleleri tetiklemez. Basışlar yine de algılanır; '
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4, right: 10),
                        child: SizedBox.square(
                          dimension: 28,
                          child: b.listening
                              ? Center(child: GlowDot(color: AppFamilies.emerald.base, size: 12, breathing: true))
                              : const SetupMiniOrb(family: AppFamilies.slate, icon: Icons.sensors_off_rounded, size: 28),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          b.listening
                              ? 'Dinleniyor: şimdi duvardaki butonlara sırayla basın (1 saniye basılı tutun).'
                              : 'Dinlemeyi başlatın, sonra duvardaki butonlara sırayla basın.',
                          style: TextStyle(fontWeight: FontWeight.w700, height: 1.35, color: SetupColors.text(context)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (listenIsPrimary)
                    SetupPrimaryButton(
                      key: const Key('btn_listen_toggle'),
                      label: b.listening ? 'Dinlemeyi Durdur' : 'Dinlemeyi Başlat',
                      icon: b.listening ? Icons.stop_circle_rounded : Icons.sensors_rounded,
                      color: b.listening ? SetupColors.error : SetupColors.primary,
                      onPressed: () => b.listening ? b.stopListening() : b.startListening(),
                    )
                  else
                    SetupSecondaryButton(
                      key: const Key('btn_listen_toggle'),
                      label: b.listening ? 'Dinlemeyi Durdur' : 'Dinlemeyi Başlat',
                      icon: b.listening ? Icons.stop_circle_rounded : Icons.sensors_rounded,
                      family: b.listening ? AppFamilies.rose : AppFamilies.sky,
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

  /// "Basış algılandı" saati biçimi (her kurulumda yeniden oluşturulmaz).
  static final DateFormat _timeFormat = DateFormat('HH:mm:ss');

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
              _ButtonIndicator(verdict: button.verdict, pressed: button.pressed, listening: logic.listening),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${button.name} (Giriş ${button.id})',
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
          if (button.pressed)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Şu an basılı görünüyor', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          if (at != null && button.verdict == ButtonVerdict.detected)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Basış algılandı: ${_timeFormat.format(at.toLocal())}',
                style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (button.verdict == ButtonVerdict.none)
                TextButton(
                  key: Key('btn_button_none_${button.id}'),
                  style: setupInlineActionStyle(),
                  onPressed: () => logic.markNone(button.id, false),
                  child: const Text('Buton var, tekrar dene'),
                )
              else
                TextButton(
                  key: Key('btn_button_none_${button.id}'),
                  style: setupInlineActionStyle(),
                  onPressed: () => logic.markNone(button.id, true),
                  child: const Text('Bu girişte buton yok'),
                ),
              if (button.verdict == ButtonVerdict.detected)
                TextButton(
                  key: Key('btn_button_reset_${button.id}'),
                  style: setupInlineActionStyle(),
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

/// Giriş göstergesi: tüm adım kartlarıyla (röle/panjur 44 dp) AYNI boyutta orb rozeti. Bekleyen giriş koyu cam orb (dinlenmiyorsa
/// soluk, dinlenirken parlak), şu an basılı olan amber parlak, yakalanan giriş ✓ zümrüt, "buton yok" amber ⛔; yakalandığı anda
/// tek seferlik nabız halkası atar. Renk tek ipucu değildir (yanında durum hapı yazar). (Eskiden bekleyen giriş 12-16 dp'lik gri
/// boncuktu ve durum değişince 30 dp orba sıçrıyordu.)
class _ButtonIndicator extends StatelessWidget {
  const _ButtonIndicator({required this.verdict, required this.pressed, required this.listening});

  final ButtonVerdict verdict;
  final bool pressed;
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final detected = verdict == ButtonVerdict.detected;
    final none = verdict == ButtonVerdict.none;
    final AccentFamily family;
    final IconData icon;
    if (detected) {
      family = AppFamilies.emerald;
      icon = Icons.check_rounded;
    } else if (none) {
      family = AppFamilies.amber;
      icon = Icons.block_rounded;
    } else if (pressed) {
      family = AppFamilies.amber;
      icon = Icons.touch_app_rounded;
    } else {
      family = listening ? AppFamilies.sky : AppFamilies.slate;
      icon = Icons.touch_app_rounded;
    }
    final waiting = !detected && !none && !pressed;
    return SizedBox.square(
      dimension: OrbSize.sm.footprint,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          PulseRing(color: AppTheme.accentTone(context, AppFamilies.emerald), diameter: OrbSize.sm.diameter, trigger: detected ? 1 : 0),
          OrbIconBadge(
            icon: icon,
            family: family,
            size: OrbSize.sm,
            active: pressed && !detected && !none,
            // Dinlenmeyen bekleyen giriş soluk (parıltısız); dinlenirken normal parlaklıkta.
            dimmed: waiting && !listening,
            status: detected ? OrbStatus.success : OrbStatus.none,
          ),
        ],
      ),
    );
  }
}
