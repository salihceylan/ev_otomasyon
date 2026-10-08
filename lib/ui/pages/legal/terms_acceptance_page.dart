import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/legal_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/auth_form.dart' show buttonSpinner;
import '../../common/confirm_dialogs.dart';
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/neon_app_bar.dart';
import '../../widgets/surface_card.dart';
import 'legal_document_view.dart';

/// Kullanıcı Sözleşmesi onay kapısı (tam ekran): sunucu kullanıcının güncel (kesinleşmiş) sözleşmeyi onaylamasını
/// istediğinde (`user.legal.needs_acceptance`) giriş kapısı (`AuthGate`) panodan ÖNCE bunu gösterir. Zorunlu parola
/// değişimi varsa önce o gelir; personel, servis PIN oturumu ve yerel ağ (LAN) kipinde gösterilmez
/// ([AutomationState.needsTermsAcceptance]).
///
/// * Metin sunucudan alınır; yüklenirken iskelet, alınamazsa hata + "Tekrar Dene". Metin görünmeden "Kabul Ediyorum"
///   pasiftir. Sunucu metni vermiyorsa (404) kullanıcı `GET /auth/me` ile yenilenir: saklı durum eskiyse kapı kalkar.
/// * "Kabul Ediyorum" -> `POST /legal/accept` -> `GET /auth/me`; onay kaydedilince kapı kendiliğinden kalkar ve pano açılır.
/// * `409 LEGAL_VERSION_MISMATCH` (bu arada yeni sürüm yayımlandı): güncel metin yüklenir ve yeniden sorulur.
/// * Ağ / sunucu hatası: Türkçe hata; düğmeler etkin kalır (yeniden denenebilir).
/// * "Çıkış Yap" (onaylı) her zaman çıkış yoludur: kullanıcı hiçbir durumda çıkmazda kalmaz. Geri tuşu kapıyı atlatmaz.
///
/// Anahtarlar: `Key('btn_terms_accept')`, `Key('btn_terms_logout')`, `Key('terms_error')`, `Key('terms_notice')`,
/// metin için [LegalDocumentView]'ınkiler ve `Key('legal_loading')`, `Key('legal_error')`, `Key('btn_legal_retry')`.
class TermsAcceptancePage extends StatefulWidget {
  const TermsAcceptancePage({super.key});

  @override
  State<TermsAcceptancePage> createState() => _TermsAcceptancePageState();
}

class _TermsAcceptancePageState extends State<TermsAcceptancePage> {
  LegalDocument? _document;
  bool _loading = true;
  String? _loadError;

  /// Onay gönderiminin hatası (ağ / sunucu).
  String? _error;

  /// Sürüm uyuşmazlığı bildirimi (metin güncellendi; yeniden onay istenir).
  String? _notice;
  bool _busy = false;
  int _request = 0;

  /// Sürüm uyuşmazlığında gösterilen metin (sunucu sürümünden bağımsız, tutarlı dil).
  static final String _updatedNotice = ApiException.clientMessages['LEGAL_VERSION_MISMATCH']!;

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
        _loadError = null;
      });
    }
    try {
      final document = await state.fetchLegalDocument(LegalDocumentKind.terms.id);
      if (!mounted || request != _request) return;
      setState(() {
        _document = document;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _document = null;
        _loadError = friendlyError(e, fallback: 'Kullanıcı Sözleşmesi yüklenemedi. Lütfen tekrar deneyin.');
        _loading = false;
      });
      // Sunucu sözleşmeyi vermiyor (404: yayından kaldırıldı / geçersiz): saklı "onay gerekir" durumu eski olabilir.
      // Kullanıcı sunucudan yenilenir; sunucu artık onay istemiyorsa kapı kendiliğinden kalkar ("Tekrar Dene" tek
      // başına açamazdı). Ağ hatasında denenmez: yeniden deneme düğmesi yeter.
      if (e is ApiException && e.isNotFound) unawaited(_resyncUser(state));
    }
  }

  /// `GET /auth/me` ile yasal durumu yeniler; hata sessizdir (metin hatası ve "Tekrar Dene" zaten görünür).
  Future<void> _resyncUser(AutomationState state) async {
    try {
      await state.refreshCurrentUser();
    } catch (_) {
      // Yenilenemedi: kapı ve "Çıkış Yap" yerinde kalır.
    }
  }

  Future<void> _accept() async {
    final document = _document;
    if (document == null || _busy || _loading) return;
    final state = context.read<AutomationState>();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await state.acceptTerms(document.version);
      if (!mounted) return;
      if (state.needsTermsAcceptance) {
        // Onay kaydedildi ama sunucu hâlâ onay istiyor (bu arada yeni sürüm yayımlandı): güncel metin yeniden sorulur.
        setState(() => _notice = _updatedNotice);
        await _load();
      }
      // Aksi halde kapı kalkar; giriş kapısı panoyu gösterir (bu sayfa ağaçtan çıkar).
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isLegalVersionMismatch) {
        setState(() => _notice = e.message);
        await _load();
      } else {
        setState(() => _error = friendlyError(e, fallback: 'Onayınız kaydedilemedi. Lütfen tekrar deneyin.'));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, fallback: 'Onayınız kaydedilemedi. Lütfen tekrar deneyin.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final document = _document;
    final loadError = _loadError;
    final url = legalPublicUrl(state.cloudApi.baseUrl, document?.url ?? LegalDocumentKind.terms.publicPath);
    final canAccept = document != null && !_loading && !_busy;

    final Widget content;
    if (document != null && !_loading) {
      content = LegalDocumentView(document: document, publicUrl: url);
    } else if (loadError != null && !_loading) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineMessage.error(
            loadError,
            key: const Key('legal_error'),
            trailing: TextButton(
              key: const Key('btn_legal_retry'),
              onPressed: _busy ? null : _load,
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

    return PopScope(
      // Geri tuşu kapıyı atlatmaz: tek çıkış yolu "Çıkış Yap"tır.
      canPop: false,
      child: Scaffold(
        appBar: const NeonAppBar(
          title: 'Kullanıcı Sözleşmesi',
          automaticallyImplyLeading: false,
          family: AppFamilies.sky,
          icon: Icons.gavel_rounded,
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const InlineMessage.info(
                            "Uygulamayı kullanmaya devam etmek için güncel Kullanıcı Sözleşmesi'ni okuyup onaylamanız gerekir.",
                            key: Key('terms_intro'),
                          ),
                          const SizedBox(height: 12),
                          SurfaceCard(padding: const EdgeInsets.fromLTRB(18, 18, 18, 14), child: content),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _ActionBar(
                notice: _notice,
                error: _error,
                busy: _busy,
                onAccept: canAccept ? _accept : null,
                onLogout: _busy ? null : () => confirmAndLogout(context, state),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Alt eylem çubuğu (her zaman görünür): bildirim / hata + "Kabul Ediyorum" (birincil) + "Çıkış Yap" (ikincil).
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.notice,
    required this.error,
    required this.busy,
    required this.onAccept,
    required this.onLogout,
  });

  final String? notice;
  final String? error;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final tokens = SurfaceTokens.of(Theme.of(context).brightness);
    final notice = this.notice;
    final error = this.error;
    return DecoratedBox(
      // Opak taban: kaydırılan metin düğmelerin arkasından okunmaz.
      decoration: BoxDecoration(
        color: tokens.cardBottom,
        border: Border(top: BorderSide(color: tokens.rimSolid)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (notice != null) ...[
                  InlineMessage.warning(notice, key: const Key('terms_notice')),
                  const SizedBox(height: 10),
                ],
                if (error != null) ...[
                  InlineMessage.error(error, key: const Key('terms_error')),
                  const SizedBox(height: 10),
                ],
                ElevatedButton(
                  key: const Key('btn_terms_accept'),
                  onPressed: onAccept,
                  child: busy ? buttonSpinner() : authPrimaryLabel('Kabul Ediyorum'),
                ),
                const SizedBox(height: 4),
                TextButton(
                  key: const Key('btn_terms_logout'),
                  onPressed: onLogout,
                  child: Text(
                    'Çıkış Yap',
                    style: TextStyle(fontWeight: FontWeight.w600, color: onLogout == null ? null : AppTheme.dangerText(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
