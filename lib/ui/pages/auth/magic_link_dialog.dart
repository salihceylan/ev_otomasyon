import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../utils/magic_link_parser.dart';
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';
import 'magic_link_page.dart';

/// E-postadaki bağlantıyı elle yapıştırma (derin bağlantı açılmadığında yedek yol).
///
/// Bağlantı `MagicLinkParser` ile **sıkı** doğrulanır (https, izinli ana makine, belirteç yalnızca
/// `#token=` parçasında); geçerliyse `MagicLinkPage` açılır. Yapıştırılan metin/belirteç saklanmaz.
class MagicLinkDialog extends StatefulWidget {
  const MagicLinkDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(context: context, builder: (_) => const MagicLinkDialog());
  }

  @override
  State<MagicLinkDialog> createState() => _MagicLinkDialogState();
}

class _MagicLinkDialogState extends State<MagicLinkDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() {
      _controller.text = text.trim();
      _error = null;
    });
  }

  void _continue() {
    final result = MagicLinkParser.parseDetailed(_controller.text);
    final link = result.link;
    if (link == null) {
      setState(() => _error = result.error?.message ?? 'Bağlantı geçersiz.');
      return;
    }
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(MaterialPageRoute<void>(builder: (_) => MagicLinkPage(link: link)));
  }

  @override
  Widget build(BuildContext context) {
    // Giriş ekranı (ve onun diyalogları) her zaman koyu temadadır: kardeş diyaloglarla aynı palet.
    return AlertDialog(
      backgroundColor: AppTheme.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      title: const Text(
        'E-postadaki Bağlantı',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Size e-posta ile gelen giriş veya şifre sıfırlama bağlantısını buraya yapıştırın.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('field_magic_link'),
              controller: _controller,
              minLines: 2,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'https://.../reset-password#token=...',
                hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                filled: true,
                fillColor: AppTheme.cardDark,
                suffixIcon: IconButton(
                  key: const Key('btn_paste_link'),
                  tooltip: 'Panodan yapıştır',
                  icon: const Icon(Icons.content_paste_rounded, color: AppTheme.primaryBlueLight),
                  onPressed: _paste,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              InlineMessage.error(_error!, key: const Key('magic_link_error')),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_magic_link_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
        ),
        ElevatedButton(
          key: const Key('btn_magic_link_continue'),
          onPressed: _continue,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Devam', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
