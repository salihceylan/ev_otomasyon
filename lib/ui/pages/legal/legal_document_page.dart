import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/legal_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/inline_message.dart';
import '../../theme/tokens.dart';
import '../../widgets/neon_app_bar.dart';
import '../../widgets/surface_card.dart';
import 'legal_document_view.dart';

/// Tek yasal metnin sayfası (Kullanıcı Sözleşmesi ya da Gizlilik Politikası ve KVKK Aydınlatma Metni).
///
/// Metin her açılışta sunucudan alınır (`GET /legal/:id`; güncel sürüm). Yüklenirken iskelet; alınamazsa (çevrimdışı)
/// Türkçe hata + "Tekrar Dene" ve herkese açık adres (internet gelince tarayıcıdan da okunabilir). Kayıt ekranı,
/// ayarlardaki "Yasal Metinler" ve giriş ekranının alt bağlantıları bu sayfayı açar; oturum gerektirmez.
///
/// Anahtarlar: `Key('legal_loading')`, `Key('legal_error')`, `Key('btn_legal_retry')` ve [LegalDocumentView]'ınkiler.
class LegalDocumentPage extends StatefulWidget {
  const LegalDocumentPage({super.key, required this.kind});

  final LegalDocumentKind kind;

  /// Sayfayı yığına iter.
  static Future<void> open(BuildContext context, LegalDocumentKind kind) =>
      Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => LegalDocumentPage(kind: kind)));

  @override
  State<LegalDocumentPage> createState() => _LegalDocumentPageState();
}

class _LegalDocumentPageState extends State<LegalDocumentPage> {
  LegalDocument? _document;
  String? _error;
  bool _loading = true;

  /// Yalnız EN SON isteğin sonucu uygulanır (hızlı "Tekrar Dene" dokunuşlarında eski yanıt yenisini ezmez).
  int _request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(initial: true));
  }

  Future<void> _load({bool initial = false}) async {
    final request = ++_request;
    final state = context.read<AutomationState>();
    if (!initial) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final document = await state.fetchLegalDocument(widget.kind.id);
      if (!mounted || request != _request) return;
      setState(() {
        _document = document;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = friendlyError(e, fallback: 'Metin yüklenemedi. Lütfen tekrar deneyin.');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final error = _error;
    final url = legalPublicUrl(context.read<AutomationState>().cloudApi.baseUrl, document?.url ?? widget.kind.publicPath);

    final Widget content;
    if (document != null) {
      content = LegalDocumentView(document: document, publicUrl: url);
    } else if (error != null && !_loading) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineMessage.error(
            error,
            key: const Key('legal_error'),
            trailing: TextButton(
              key: const Key('btn_legal_retry'),
              onPressed: _load,
              child: const Text('Tekrar Dene'),
            ),
          ),
          const SizedBox(height: 16),
          LegalPublicAddress(url: url),
        ],
      );
    } else {
      content = const LegalLoadingSkeleton(key: Key('legal_loading'));
    }

    return Scaffold(
      appBar: NeonAppBar(title: widget.kind.shortLabel, family: AppFamilies.slate, icon: Icons.gavel_rounded),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Center(
            // Uzun metin geniş ekranda okunur satır uzunluğunda kalır.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              // Metin cam plakada durur: arkadaki devre fotoğrafı satırların altından geçmez.
              child: SurfaceCard(padding: const EdgeInsets.fromLTRB(18, 18, 18, 14), child: content),
            ),
          ),
        ),
      ),
    );
  }
}
