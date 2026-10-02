import 'package:flutter/material.dart';

import 'setup_style.dart';

/// Tek seferlik gizli değer satırı (kurulum PIN'i, yerel anahtar ...): değer ekranda gösterilir, yanındaki
/// düğme [onCopy] çağırır (panoya kopyalama `SecretClipboard` ile 45 sn sonra silinir, arka planda silme
/// başarısızsa ön plana dönünce yeniden denenir). Değer bu widget'ta saklanmaz, loglanmaz.
///
/// Metin **seçilebilir değildir** (`Text`): sistemin "seç ve kopyala" menüsü silme zamanlayıcısını
/// atlayacağı için panoya tek giriş yolu, silinen yol olan [onCopy] düğmesidir.
class SecretValueRow extends StatelessWidget {
  const SecretValueRow({
    super.key,
    required this.label,
    required this.shown,
    required this.copyKey,
    required this.onCopy,
  });

  final String label;

  /// Ekranda görünen biçim (ör. "123 456").
  final String shown;
  final Key copyKey;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: SetupColors.muted(context))),
                Text(
                  shown,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: SetupColors.text(context),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: copyKey,
            tooltip: '$label kopyala',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
