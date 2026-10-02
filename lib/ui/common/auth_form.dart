import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Kimlik doğrulama formları için ortak alan görünümü.
///
/// [onDarkBackground] `true` ise (giriş ekranı kendi koyu arka planını çizer) sabit koyu renkler,
/// aksi halde temaya duyarlı renkler kullanılır (açık temada okunabilir).
InputDecoration authInputDecoration(
  BuildContext context, {
  required String label,
  required IconData prefixIcon,
  Widget? suffixIcon,
  String? hint,
  String? helper,
  bool onDarkBackground = false,
}) {
  final muted = onDarkBackground ? AppTheme.textMuted : AppTheme.getTextMuted(context);
  final fill = onDarkBackground ? AppTheme.cardDark : AppTheme.getCardColor(context);
  final border = onDarkBackground ? AppTheme.cardBorder : AppTheme.getCardBorder(context);
  OutlineInputBorder outline(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    helperMaxLines: 3,
    errorMaxLines: 3,
    labelStyle: TextStyle(color: muted, fontSize: 14),
    hintStyle: TextStyle(color: muted, fontSize: 13),
    prefixIcon: Icon(prefixIcon, color: muted),
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: fill,
    border: outline(border),
    enabledBorder: outline(border),
    focusedBorder: outline(AppTheme.primaryBlue, 1.8),
    errorBorder: outline(AppTheme.accentRed),
    focusedErrorBorder: outline(AppTheme.accentRed, 1.8),
  );
}

/// Parola alanındaki göster/gizle düğmesi.
Widget passwordVisibilityButton({
  required BuildContext context,
  required bool obscured,
  required VoidCallback onToggle,
  bool onDarkBackground = false,
  Key? key,
}) {
  return IconButton(
    key: key,
    tooltip: obscured ? 'Şifreyi göster' : 'Şifreyi gizle',
    icon: Icon(
      obscured ? Icons.visibility_off : Icons.visibility,
      color: onDarkBackground ? AppTheme.textMuted : AppTheme.getTextMuted(context),
    ),
    onPressed: onToggle,
  );
}

/// Yükleme göstergeli birincil düğme içeriği.
Widget buttonSpinner({Color color = Colors.white}) =>
    SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: color));
