import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';
import 'settings_card.dart';

/// Görünüm (tema) seçici kartı: Koyu / Açık / Sistem. Anahtarlar: `Key('card_theme')`,
/// `Key('btn_theme_dark')`, `Key('btn_theme_light')`, `Key('btn_theme_system')`.
class ThemeSelectorCard extends StatelessWidget {
  const ThemeSelectorCard({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AutomationState, ThemeMode>((s) => s.themeMode);
    final state = context.read<AutomationState>();

    return KeyedSubtree(
      key: const Key('card_theme'),
      child: SettingsCard(
        icon: Icons.palette_outlined,
        title: 'Görünüm & Tema Modu',
        accent: AppTheme.primaryBlue,
        children: [
          Text(
            switch (mode) {
              ThemeMode.dark => 'Karanlık Mod (Varsayılan)',
              ThemeMode.light => 'Aydınlık Mod',
              ThemeMode.system => 'Sistem Teması',
            },
            style: TextStyle(fontSize: 12.5, color: AppTheme.getTextMuted(context)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ThemeChoice(
                  choiceKey: const Key('btn_theme_dark'),
                  label: 'Koyu',
                  icon: Icons.dark_mode_outlined,
                  selected: mode == ThemeMode.dark,
                  onTap: () => unawaited(state.setThemeMode(ThemeMode.dark)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ThemeChoice(
                  choiceKey: const Key('btn_theme_light'),
                  label: 'Açık',
                  icon: Icons.light_mode_outlined,
                  selected: mode == ThemeMode.light,
                  onTap: () => unawaited(state.setThemeMode(ThemeMode.light)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ThemeChoice(
                  choiceKey: const Key('btn_theme_system'),
                  label: 'Sistem',
                  icon: Icons.brightness_auto_outlined,
                  selected: mode == ThemeMode.system,
                  onTap: () => unawaited(state.setThemeMode(ThemeMode.system)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.choiceKey,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final Key choiceKey;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.infoText(context);
    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: '$label tema',
      onTap: onTap,
      child: InkWell(
        key: choiceKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primaryBlue.withValues(alpha: 0.2) : AppTheme.getInsetColor(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppTheme.primaryBlue : AppTheme.getCardBorder(context),
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: selected ? accent : AppTheme.getTextMuted(context)),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? accent : AppTheme.getTextPrimary(context),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Biyometrik giriş kartı. **Açmak ve kapatmak kimlik doğrulaması ister**
/// (`AutomationState.toggleBiometric`); doğrulanamazsa ayar değişmez ve kullanıcıya söylenir.
///
/// Anahtarlar: `Key('card_biometric')`, `Key('switch_biometric')`, `Key('text_biometric_status')`.
class BiometricCard extends StatefulWidget {
  const BiometricCard({super.key});

  @override
  State<BiometricCard> createState() => _BiometricCardState();
}

class _BiometricCardState extends State<BiometricCard> {
  bool _busy = false;
  String? _message;

  Future<void> _toggle(bool value) async {
    final state = context.read<AutomationState>();
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = value
        ? await state.enableBiometricWithVerification()
        // Kapatmak da doğrulama ister (toggleBiometric içinde).
        : await state.toggleBiometric(false);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok
          ? null
          : (value
              ? 'Kimlik doğrulanamadı. Biyometrik giriş açılmadı.'
              : 'Kimlik doğrulanamadı. Biyometrik giriş açık kalıyor.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({bool supported, bool enabled, String label})>(
      (s) => (supported: s.isBiometricSupported, enabled: s.isBiometricEnabled, label: s.biometricLabel),
    );
    final green = AppTheme.accentGreen;

    return KeyedSubtree(
      key: const Key('card_biometric'),
      child: SettingsCard(
        icon: Icons.fingerprint_rounded,
        title: '${vm.label} Girişi',
        accent: green,
        children: [
          MergeSemantics(
            child: Semantics(
              label: '${vm.label} girişi',
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      vm.supported
                          ? 'Açılışta ${vm.label} ile anında giriş yapın'
                          : 'Cihazınızda biyometrik donanım bulunamadı',
                      key: const Key('text_biometric_status'),
                      style: TextStyle(fontSize: 12.5, color: AppTheme.getTextMuted(context)),
                    ),
                  ),
                  Switch(
                    key: const Key('switch_biometric'),
                    value: vm.enabled,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    activeThumbColor: green,
                    onChanged: (vm.supported && !_busy) ? (value) => unawaited(_toggle(value)) : null,
                  ),
                ],
              ),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 6),
            Text(
              _message!,
              key: const Key('text_biometric_message'),
              style: TextStyle(fontSize: 12.5, color: AppTheme.warningText(context)),
            ),
          ],
        ],
      ),
    );
  }
}
