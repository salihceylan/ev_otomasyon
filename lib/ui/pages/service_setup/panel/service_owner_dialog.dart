import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../models/api_models.dart';
import '../../../../models/json_utils.dart';
import '../../../../services/automation_state.dart';
import '../../../../utils/friendly_error.dart';
import '../../../common/app_dialogs.dart';
import '../../../common/arc_spinner.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'admin_account.dart';
import 'service_glass.dart';

/// Aktarılacak kayıt türü.
enum ServiceOwnerTarget {
  /// Daire (ev): `PATCH /admin/homes/:homeId/service-owner`. Dairedeki kartlar da yeni kapsama geçer.
  home,

  /// Stoktaki kart: `PATCH /admin/inventory/:uuid/service-owner`. Kurulu kart evini izler (sunucu 409).
  inventory,
}

/// Aktarım sonucunu kısa bir kullanıcı iletisine çevirir (sunucunun Türkçe iletisi esastır; yoksa yedek metin). Daire
/// aktarımında taşınan kart sayısı eklenir.
String serviceOwnerResultMessage(ServiceOwnerTransferResult result, {required ServiceOwnerTarget target}) {
  final subject = target == ServiceOwnerTarget.home ? 'Daire' : 'Kart';
  final server = result.message.trim();
  final base = server.isNotEmpty
      ? server
      : !result.changed
          ? '$subject zaten bu kapsamda.'
          : result.toRoot
              ? '$subject kök yönetici kapsamına alındı.'
              : '$subject yeni servis sorumlusunun kapsamına aktarıldı.';
  if (target == ServiceOwnerTarget.home && result.changed && result.cardsMoved > 0) {
    return '$base ${result.cardsMoved} kart ${result.toRoot ? 'kök stoğuna' : 'yeni servisin stoğuna'} geçti.';
  }
  return base;
}

/// "Servisi Değiştir" penceresi (**yalnız kök**; `Capabilities.canTransferServiceScope`): bir daireyi ya da stoktaki kartı
/// başka bir servis sorumlusuna ya da köke ("Kök (servissiz)") aktarır.
///
/// İki adım: (1) hedefi seç (servis hesapları `GET /admin/users?role=service_user` ile listelenir; yalnız **aktif**
/// hesaplar seçilebilir), (2) sonuçları okuyarak onayla. API çağrısı pencerededir: hata pencerede kalır, pencere yalnızca
/// sunucu başarısından sonra kapanır ve [ServiceOwnerTransferResult] döndürür; vazgeçilirse `null`.
class ServiceOwnerDialog extends StatefulWidget {
  const ServiceOwnerDialog({
    super.key,
    required this.target,
    required this.targetId,
    required this.targetLabel,
    this.currentOwnerId,
    this.currentOwnerLabel,
  });

  final ServiceOwnerTarget target;

  /// Daire kimliği (`home`) ya da cihaz UUID'si (`inventory`).
  final String targetId;

  /// Pencerede gösterilen kayıt adı (ör. "Daire 5 (#a1b2c3d4)" / "AHBU-S3-A1B2C3").
  final String targetLabel;

  /// Mevcut servis sorumlusu; `null` = kök kapsamı (ya da sunucu bildirmedi).
  final String? currentOwnerId;

  /// Mevcut servisin görünen adı; boşsa "Kök (servissiz)".
  final String? currentOwnerLabel;

  static Future<ServiceOwnerTransferResult?> show(
    BuildContext context, {
    required ServiceOwnerTarget target,
    required String targetId,
    required String targetLabel,
    String? currentOwnerId,
    String? currentOwnerLabel,
  }) {
    return showAppDialog<ServiceOwnerTransferResult>(
      context,
      barrierDismissible: false,
      builder: (_) => ServiceOwnerDialog(
        target: target,
        targetId: targetId,
        targetLabel: targetLabel,
        currentOwnerId: currentOwnerId,
        currentOwnerLabel: currentOwnerLabel,
      ),
    );
  }

  @override
  State<ServiceOwnerDialog> createState() => _ServiceOwnerDialogState();
}

class _ServiceOwnerDialogState extends State<ServiceOwnerDialog> {
  static const Duration _timeout = Duration(seconds: 30);
  static const Duration _searchDebounce = Duration(milliseconds: 300);

  /// Sunucu sayfa başına en çok 100 kayıt verir; servis hesabı sayısı küçüktür, arama ile daraltılır.
  static const int _pageSize = 100;

  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  int _seq = 0;

  List<AdminAccount> _accounts = const <AdminAccount>[];
  int? _total;
  bool _loading = true;
  String? _loadError;

  bool _hasPick = false;
  String? _pickedId;
  String? _pickedLabel;
  bool _confirming = false;
  bool _busy = false;
  String? _error;

  bool get _isHome => widget.target == ServiceOwnerTarget.home;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadAccounts());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    final api = context.read<AutomationState>().cloudApi;
    final query = _search.text.trim();
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final res = await api
          .listAdminUsers(role: 'service_user', search: query.isEmpty ? null : query, limit: _pageSize)
          .timeout(_timeout);
      if (!mounted || seq != _seq) return;
      final parsed = <AdminAccount>[
        for (final raw in asList(res['users']) ?? const <dynamic>[]) ?AdminAccount.tryParse(raw),
      ];
      setState(() {
        _accounts = parsed;
        _total = asInt(res['total']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _loadError = friendlyError(e, fallback: 'Servis hesapları yüklenemedi. Lütfen tekrar deneyin.');
      });
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    final clock = context.read<AutomationState>().clock;
    _debounce = clock.timer(_searchDebounce, () {
      if (mounted) unawaited(_loadAccounts());
    });
    setState(() {});
  }

  /// Yalnız aktif ve etkinleştirilmiş servis hesapları hedef olabilir (sunucu: aktif değilse 409).
  List<AdminAccount> get _selectable => <AdminAccount>[
        for (final a in _accounts)
          if (a.isServiceStaff && a.isActive && a.status == AccountStatus.active) a,
      ];

  void _pickRoot() {
    if (_busy) return;
    setState(() {
      _hasPick = true;
      _pickedId = null;
      _pickedLabel = null;
      _error = null;
    });
  }

  void _pick(AdminAccount account) {
    if (_busy) return;
    setState(() {
      _hasPick = true;
      _pickedId = account.id;
      _pickedLabel = account.fullName;
      _error = null;
    });
  }

  /// Seçim mevcut kapsamla aynı mı? (Yalnız sunucu mevcut sahibi bildirdiyse karşılaştırılır; aynıysa "Devam" kapalı.)
  bool get _samePick {
    if (!_hasPick) return false;
    final current = widget.currentOwnerId;
    return current == _pickedId;
  }

  Future<void> _submit() async {
    if (_busy || !_hasPick) return;
    final state = context.read<AutomationState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ServiceOwnerTransferResult result;
      if (_isHome) {
        result = await state.transferHomeServiceOwner(widget.targetId, serviceUserId: _pickedId).timeout(_timeout);
      } else {
        result = await state.transferInventoryServiceOwner(widget.targetId, serviceUserId: _pickedId).timeout(_timeout);
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e, fallback: 'Aktarım tamamlanamadı. Bağlantınızı kontrol edip tekrar deneyin.');
      });
    }
  }

  /// Onay adımında kullanıcıya yazılan sonuçlar (sunucu davranışı: `service_scope_service`).
  List<String> _consequences() {
    final toRoot = _pickedId == null;
    if (_isHome) {
      return <String>[
        if (toRoot)
          'Daire kök yönetici kapsamına alınır; hiçbir servis sorumlusu bu daireyi yönetemez.'
        else
          'Dairedeki kartlar da bu servisin stoğuna geçer.',
        'Önceki servisin dairedeki üyeliği ve uygulama bağlantı kimlikleri iptal edilir. Tek panolu dairede panonun bulut '
            'kimliği ve yerel anahtarı da yenilenir.',
      ];
    }
    return <String>[
      if (toRoot)
        'Kart kök stoğuna alınır; servis sorumluları bu kartı yalnızca kurabilir, yönetemez.'
      else
        'Kart bu servisin stoğuna geçer; önceki servis artık bu kartı göremez ve yönetemez.',
    ];
  }

  String get _currentLabel {
    final label = widget.currentOwnerLabel?.trim();
    return (label == null || label.isEmpty) ? 'Kök (servissiz)' : label;
  }

  String get _pickedName => _pickedId == null ? 'Kök (servissiz)' : (_pickedLabel ?? 'Servis sorumlusu');

  @override
  Widget build(BuildContext context) {
    final muted = SetupColors.muted(context);
    final confirming = _confirming && _hasPick;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const Key('dialog_service_owner'),
        scrollable: true,
        title: Row(
          children: [
            OrbIconBadge(icon: Icons.swap_horiz_rounded, family: AppFamilies.violet, pending: _busy),
            const SizedBox(width: 12),
            const Expanded(child: Text('Servisi Değiştir')),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.targetLabel,
                key: const Key('service_owner_subject'),
                style: TextStyle(fontSize: AppText.caption, fontWeight: FontWeight.w700, color: muted),
              ),
              const SizedBox(height: 8),
              if (!confirming) ..._pickStep(context) else ..._confirmStep(context),
              if (_error != null)
                ServiceCard(
                  key: const Key('service_owner_error'),
                  accent: SetupColors.error,
                  child: SetupInfoRow(icon: Icons.error_outline_rounded, color: SetupColors.error, bold: true, text: _error!),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('btn_service_owner_cancel'),
            style: AppTheme.quietTextButtonStyle(context),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
          if (confirming) ...[
            TextButton(
              key: const Key('btn_service_owner_back'),
              style: AppTheme.quietTextButtonStyle(context),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _confirming = false;
                        _error = null;
                      }),
              child: const Text('Geri'),
            ),
            ElevatedButton(
              key: const Key('btn_service_owner_confirm'),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const ArcSpinner(size: 18, color: Colors.white, strokeWidth: 2.4)
                  : const Text('Aktar'),
            ),
          ] else
            ElevatedButton(
              key: const Key('btn_service_owner_next'),
              onPressed: (!_hasPick || _samePick) ? null : () => setState(() => _confirming = true),
              child: const Text('Devam'),
            ),
        ],
      ),
    );
  }

  List<Widget> _pickStep(BuildContext context) {
    final muted = SetupColors.muted(context);
    final options = _selectable;
    return [
      Text('Mevcut servis: $_currentLabel', key: const Key('service_owner_current')),
      const SizedBox(height: 10),
      TextField(
        key: const Key('field_service_owner_search'),
        controller: _search,
        onChanged: _onSearchChanged,
        decoration: const InputDecoration(
          labelText: 'Servis ara',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          hintText: 'Ad, e-posta veya telefon',
          hintMaxLines: 1,
          prefixIcon: Icon(Icons.search_rounded, size: 20),
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
      const SizedBox(height: 10),
      Text('Yeni servis', style: TextStyle(fontSize: AppText.caption, color: muted)),
      const SizedBox(height: 6),
      _OwnerOption(
        optionKey: const Key('opt_service_owner_root'),
        icon: Icons.shield_rounded,
        title: 'Kök (servissiz)',
        subtitle: _isHome ? 'Daire kök yönetici kapsamında kalır' : 'Kart kök stoğunda kalır',
        selected: _hasPick && _pickedId == null,
        current: widget.currentOwnerId == null,
        onTap: _busy ? null : _pickRoot,
      ),
      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: ArcSpinner(size: 22, strokeWidth: 2.6, color: AppTheme.accentCyan, key: Key('service_owner_loading'))),
        )
      else if (_loadError != null)
        ServiceCard(
          key: const Key('service_owner_load_error'),
          accent: SetupColors.error,
          margin: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SetupInfoRow(icon: Icons.error_outline_rounded, color: SetupColors.error, bold: true, text: _loadError!),
              TextButton(
                key: const Key('btn_service_owner_retry'),
                onPressed: _loadAccounts,
                child: const Text('Tekrar dene'),
              ),
            ],
          ),
        )
      else ...[
        for (final account in options)
          _OwnerOption(
            optionKey: Key('opt_service_owner_${account.id}'),
            icon: Icons.engineering_rounded,
            title: account.fullName,
            subtitle: account.email,
            selected: _hasPick && _pickedId == account.id,
            current: widget.currentOwnerId == account.id,
            onTap: _busy ? null : () => _pick(account),
          ),
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _search.text.trim().isEmpty
                  ? 'Aktif servis sorumlusu hesabı yok.'
                  : 'Aramanızla eşleşen aktif servis sorumlusu yok.',
              key: const Key('service_owner_empty'),
              style: TextStyle(fontSize: AppText.caption, color: muted),
            ),
          ),
        if ((_total ?? 0) > _accounts.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'İlk ${_accounts.length} hesap gösteriliyor; listeyi daraltmak için arayın.',
              key: const Key('service_owner_more'),
              style: TextStyle(fontSize: AppText.caption, color: muted),
            ),
          ),
      ],
    ];
  }

  List<Widget> _confirmStep(BuildContext context) {
    return [
      Text(
        '${widget.targetLabel}: "$_currentLabel" kapsamından "$_pickedName" kapsamına aktarılacak.',
        key: const Key('service_owner_confirm_text'),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      for (final line in _consequences())
        SetupInfoRow(icon: Icons.info_outline_rounded, color: SetupColors.warn, text: line),
    ];
  }
}

/// Seçilebilir servis satırı (tek seçim; en az 48 dp dokunma hedefi). Mevcut kapsam "Mevcut" etiketiyle işaretlenir.
class _OwnerOption extends StatelessWidget {
  const _OwnerOption({
    required this.optionKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.current,
    required this.onTap,
  });

  final Key optionKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = SetupColors.text(context);
    final muted = SetupColors.muted(context);
    final accent = SetupColors.readable(context, AppTheme.accentCyan);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        label: current ? '$title, mevcut servis' : title,
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          key: optionKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.r12),
              border: Border.all(color: selected ? accent : SetupColors.border(context), width: selected ? 1.6 : 1),
              color: selected ? AppTheme.accentCyan.withValues(alpha: SetupColors.isDark(context) ? 0.14 : 0.08) : null,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                        size: 20, color: selected ? accent : muted),
                    const SizedBox(width: 10),
                    Icon(icon, size: 20, color: muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: AppText.body, fontWeight: FontWeight.w700, color: text),
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: AppText.caption, color: muted),
                            ),
                        ],
                      ),
                    ),
                    if (current) ...[
                      const SizedBox(width: 8),
                      Text('Mevcut', style: TextStyle(fontSize: AppText.badge, fontWeight: FontWeight.w700, color: muted)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
