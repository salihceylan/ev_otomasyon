import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../services/api_exception.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';

/// Yıkıcı ve tekrarlanamaz bir sunucu işleminin (acil sıfırlama, pano değişimi) **sonucu bilinmiyor**:
/// istek zaman aşımına uğradı ya da bağlantı koptu, ama sunucu işlemi tamamlamış olabilir.
///
/// Kullanıcıya "tekrar dene" denmez (aynı işlemi körlemesine yinelemek yeni PIN/kimlik üretir, devredilen
/// sahibi bozabilir); önce **durumu kontrol etmesi** istenir ([onCheck]). Kontrol sonucu [checkResult] ile
/// gösterilir.
class UncertainOutcomeCard extends StatelessWidget {
  const UncertainOutcomeCard({
    super.key,
    required this.title,
    required this.message,
    required this.checkButtonKey,
    required this.onCheck,
    this.checking = false,
    this.checkResult,
  });

  final String title;
  final String message;
  final Key checkButtonKey;
  final VoidCallback onCheck;
  final bool checking;

  /// "Durumu Kontrol Et" sonucunun açıklaması (varsa).
  final String? checkResult;

  /// Hata, sonucu belirsiz bir kesinti mi (zaman aşımı / ağ yok)? Sunucunun açık bir hata yanıtı
  /// (4xx/5xx) işlemin yapılmadığını gösterir; ağ kesintisi ise işlem tamamlanmış olabilir.
  static bool isUncertain(Object error) =>
      error is TimeoutException || (error is ApiException && error.isNetwork);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: title,
      child: SetupCard(
        accent: SetupColors.warn,
        margin: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.help_outline_rounded,
                  color: SetupColors.warn,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: SetupColors.readable(context, SetupColors.warn),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.4,
                color: SetupColors.text(context),
              ),
            ),
            if (checkResult != null) ...[
              const SizedBox(height: 8),
              SetupInfoRow(
                icon: Icons.info_outline_rounded,
                color: SetupColors.info,
                bold: true,
                text: checkResult!,
              ),
            ],
            const SizedBox(height: 10),
            SetupPrimaryButton(
              key: checkButtonKey,
              label: 'Durumu Kontrol Et',
              icon: Icons.fact_check_outlined,
              busy: checking,
              onPressed: checking ? null : onCheck,
            ),
          ],
        ),
      ),
    );
  }
}
