import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../models/json_utils.dart';
import '../../services/automation_state.dart';
import '../../services/ev_cloud_api_service.dart';
import '../../utils/friendly_error.dart';
import '../common/confirm_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/circuit_background.dart';
import 'service_setup/panel/admin_account.dart';
import 'service_setup/panel/admin_account_dialogs.dart';
import 'service_setup/panel/service_tool_cards.dart';
import 'service_setup/setup_style.dart';
import 'service_setup/setup_widgets.dart';

/// Süper yönetici ve servis sorumlusu hesap yönetim paneli.
///
/// * **Hesaplar** sekmesi: sayfalı + gecikmeli aramalı liste; hata görünür kalır (hata -> boş liste
///   gösterilmez); oluşturma/düzenleme diyalogları yalnızca API başarısından sonra kapanır.
/// * Süper yönetici kendi hesabını ve **son aktif süper yöneticiyi donduramaz**; dondurma onaylanır.
///   Başka bir süper yöneticinin parolası için kendi mevcut parolası istenir.
/// * Servis sorumlusu hesap oluştururken **parola veremez**: hesap `pending_invite` olur ve
///   etkinleştirme / sıfırlama bağlantısı e-postayla gider.
/// * **Görevler ve Araçlar** sekmesi: servis araçlarına kısayollar.
class ServiceManagementPage extends StatefulWidget {
  const ServiceManagementPage({
    super.key,
    this.autoLoad = true,
    this.initialTabIndex = 0,
    this.pageSize = 30,
  });

  /// `false` ise açılışta sunucudan yüklenmez (yenile ile yüklenir).
  final bool autoLoad;

  /// 0: Hesaplar, 1: Görevler ve Araçlar (sınır dışı değerler sığdırılır).
  final int initialTabIndex;
  final int pageSize;

  @override
  State<ServiceManagementPage> createState() => _ServiceManagementPageState();
}

class _ServiceManagementPageState extends State<ServiceManagementPage> with SingleTickerProviderStateMixin {
  static const Duration _searchDebounce = Duration(milliseconds: 300);
  static const Duration _requestTimeout = Duration(seconds: 25);

  late final TabController _tabs;
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<AdminAccount> _items = const <AdminAccount>[];
  int? _total;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loaded = false;
  String? _error;
  int _seq = 0;
  Timer? _debounce;
  GlobalRole? _roleFilter;
  String _query = '';

  Map<String, dynamic>? _summary;
  String? _summaryError;
  bool _summaryLoading = false;

  final Set<String> _busyIds = <String>{};

  EvCloudApiService get _api => context.read<AutomationState>().cloudApi;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialTabIndex.clamp(0, 1));
    _scroll.addListener(_onScroll);
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_loadAccounts(reset: true));
        unawaited(_loadSummary());
      });
    } else {
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _hasMore {
    final total = _total;
    if (total != null) return _items.length < total;
    return _items.isNotEmpty && _items.length % widget.pageSize == 0;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 200 && _hasMore && !_loading && !_loadingMore && _error == null) {
      unawaited(_loadAccounts(reset: false));
    }
  }

  // ---------------------------------------------------------------------------
  // Yükleme
  // ---------------------------------------------------------------------------

  Future<void> _loadAccounts({required bool reset}) async {
    final state = context.read<AutomationState>();
    if (!state.capabilities.canOpenServiceManagement) return;
    final seq = ++_seq;
    setState(() {
      if (reset) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });
    try {
      final res = await _api
          .listAdminUsers(
            role: _roleFilter?.wire,
            search: _query.isEmpty ? null : _query,
            limit: widget.pageSize,
            offset: reset ? 0 : _items.length,
          )
          .timeout(_requestTimeout);
      if (!mounted || seq != _seq) return;
      final parsed = <AdminAccount>[
        for (final raw in asList(res['users']) ?? const <dynamic>[]) ?AdminAccount.tryParse(raw),
      ];
      setState(() {
        _items = reset ? parsed : <AdminAccount>[..._items, ...parsed];
        _total = asInt(res['total']);
        _loading = false;
        _loadingMore = false;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = friendlyError(e, fallback: 'Hesap listesi yüklenemedi. Lütfen tekrar deneyin.');
        _loading = false;
        _loadingMore = false;
        _loaded = true;
      });
    }
  }

  Future<void> _loadSummary() async {
    final state = context.read<AutomationState>();
    if (!state.capabilities.canManageAdminAccounts) return; // özet yalnızca süper yönetici içindir
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
    });
    try {
      final res = await _api.getServiceSummary().timeout(_requestTimeout);
      if (!mounted) return;
      setState(() {
        _summary = res;
        _summaryLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _summaryLoading = false;
        _summaryError = friendlyError(e, fallback: 'Özet bilgiler alınamadı.');
      });
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait<void>(<Future<void>>[_loadAccounts(reset: true), _loadSummary()]);
  }

  void _setFilter(GlobalRole? role) {
    if (_roleFilter == role) return;
    setState(() => _roleFilter = role);
    unawaited(_loadAccounts(reset: true));
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final clock = context.read<AutomationState>().clock;
    _debounce = clock.timer(_searchDebounce, () {
      if (!mounted) return;
      final next = value.trim();
      if (next == _query) return;
      _query = next;
      unawaited(_loadAccounts(reset: true));
    });
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Eylemler
  // ---------------------------------------------------------------------------

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: Key(error ? 'snack_account_error' : 'snack_account_info'),
          content: Text(message),
          backgroundColor: error ? SetupColors.error : null,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _create() async {
    final state = context.read<AutomationState>();
    final isSuper = state.capabilities.canManageAdminAccounts;
    final outcome = await CreateAccountDialog.show(context, actorIsSuper: isSuper);
    if (outcome == null || !mounted) return;
    if (outcome.withPassword) {
      _snack('${outcome.fullName} hesabı oluşturuldu. İlk girişte parolasını değiştirmesi istenecek.');
    } else if (outcome.inviteSent == false) {
      _snack(
        'Hesap oluşturuldu ama etkinleştirme e-postası gönderilemedi. Karttaki "Bağlantı gönder" ile tekrar deneyin.'
        '${outcome.inviteWarning == null ? '' : ' (${outcome.inviteWarning})'}',
        error: true,
      );
    } else {
      _snack('${outcome.fullName} hesabı oluşturuldu; etkinleştirme bağlantısı ${outcome.email} adresine gönderildi.');
    }
    unawaited(_refreshAll());
  }

  Future<void> _edit(AdminAccount account, {required bool isSelf}) async {
    final state = context.read<AutomationState>();
    final ok = await EditAccountDialog.show(
      context,
      account: account,
      actorIsSuper: state.capabilities.canManageAdminAccounts,
      isSelf: isSelf,
    );
    if (ok != true || !mounted) return;
    _snack('${account.fullName} hesabı güncellendi.');
    unawaited(_loadAccounts(reset: true));
  }

  bool get _allSupersLoaded {
    if (_roleFilter != null && _roleFilter != GlobalRole.superUser) return false;
    if (_query.isNotEmpty) return false;
    final total = _total;
    return total != null && _items.length >= total;
  }

  Future<void> _freeze(AdminAccount account) async {
    if (_busyIds.contains(account.id)) return;
    final me = context.read<AutomationState>().currentUser;
    final block = AccountRules.freezeBlock(
      target: account,
      currentUserId: me?.id,
      loaded: _items,
      allSupersLoaded: _allSupersLoaded,
    );
    if (block != null) {
      _snack(AccountRules.freezeBlockText(block), error: true);
      return;
    }
    final ok = await showSimpleConfirm(
      context,
      title: 'Hesap dondurulsun mu?',
      message: '${account.fullName} (${account.email}) hesabı dondurulacak: tüm oturumları kapanır, uygulamaya '
          'giriş yapamaz ve evlerdeki cihaz erişimi durur. Daha sonra yeniden aktifleştirebilirsiniz.',
      confirmLabel: 'Dondur',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _setActive(account, active: false);
  }

  Future<void> _activate(AdminAccount account) async {
    if (_busyIds.contains(account.id)) return;
    await _setActive(account, active: true);
  }

  Future<void> _setActive(AdminAccount account, {required bool active}) async {
    setState(() => _busyIds.add(account.id));
    try {
      await _api.updateAdminUser(account.id, isActive: active).timeout(_requestTimeout);
      if (!mounted) return;
      setState(() {
        _items = <AdminAccount>[
          for (final a in _items)
            a.id == account.id
                ? a.copyWith(
                    isActive: active,
                    status: active
                        ? (a.status == AccountStatus.suspended ? AccountStatus.active : a.status)
                        : AccountStatus.suspended,
                  )
                : a,
        ];
      });
      _snack(active ? '${account.fullName} hesabı aktifleştirildi.' : '${account.fullName} hesabı donduruldu.');
      unawaited(_loadSummary());
    } catch (e) {
      if (!mounted) return;
      showFriendlyError(context, e, fallback: 'İşlem tamamlanamadı. Lütfen tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _busyIds.remove(account.id));
    }
  }

  Future<void> _sendReset(AdminAccount account) async {
    if (_busyIds.contains(account.id)) return;
    setState(() => _busyIds.add(account.id));
    try {
      final res = await _api.sendAdminUserReset(account.id).timeout(_requestTimeout);
      if (!mounted) return;
      final purpose = asNonEmptyString(res['purpose']);
      final sent = asBool(res['sent']);
      if (sent == false) {
        _snack('Bağlantı gönderilemedi. E-posta sağlayıcısı yanıt vermedi; biraz sonra tekrar deneyin.', error: true);
      } else {
        _snack(
          purpose == 'account_setup'
              ? 'Hesap etkinleştirme bağlantısı ${account.email} adresine gönderildi.'
              : 'Parola sıfırlama bağlantısı ${account.email} adresine gönderildi.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      showFriendlyError(context, e, fallback: 'Bağlantı gönderilemedi. Lütfen tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _busyIds.remove(account.id));
    }
  }

  // ---------------------------------------------------------------------------
  // Arayüz
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final caps = state.capabilities;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0B1120) : const Color(0xFFF1F5F9),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              caps.canManageAdminAccounts ? 'Servis Yönetimi' : 'Servis ve Saha Konsolu',
              key: const Key('nav_service_management_title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              caps.canManageAdminAccounts ? 'Yöneticiler, servis sorumluları, müşteriler' : 'Müşteri hesapları ve araçlar',
              style: const TextStyle(fontSize: 11, color: AppTheme.accentCyan),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('btn_refresh'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: _loading ? null : _refreshAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(key: Key('tab_accounts'), icon: Icon(Icons.shield_outlined, size: 18), text: 'Hesaplar'),
            Tab(key: Key('tab_tools'), icon: Icon(Icons.task_alt_rounded, size: 18), text: 'Görevler ve Araçlar'),
          ],
        ),
      ),
      floatingActionButton: caps.canOpenServiceManagement
          ? FloatingActionButton.extended(
              key: const Key('btn_add_account'),
              onPressed: _create,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(caps.canManageAdminAccounts ? 'Hesap Ekle' : 'Müşteri Ekle'),
            )
          : null,
      body: CircuitBackground(
        child: SafeArea(
          child: !caps.canOpenServiceManagement
              ? const _Denied()
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _accountsTab(context, state),
                    ListView(
                      key: const Key('management_tools'),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                      children: const [ServiceToolCards(includeManagement: false, includeSetup: true)],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _accountsTab(BuildContext context, AutomationState state) {
    final caps = state.capabilities;
    final isSuper = caps.canManageAdminAccounts;
    return RefreshIndicator(
      onRefresh: _refreshAll,
      color: AppTheme.accentCyan,
      child: ListView(
        key: const Key('accounts_list'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          if (isSuper) _summaryCard(context),
          if (!isSuper)
            const SetupCard(
              margin: EdgeInsets.only(bottom: 4),
              child: SetupInfoRow(
                icon: Icons.info_outline_rounded,
                color: SetupColors.info,
                text: 'Servis sorumlusu ve yönetici hesaplarını yalnızca süper yönetici tanımlayabilir. Burada '
                    'oluşturduğunuz müşteri hesaplarını görür ve yönetirsiniz.',
              ),
            ),
          _filters(context, isSuper),
          ..._listBody(context, state, isSuper),
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    final users = asMap(_summary?['users']);
    final devices = asMap(_summary?['devices']);
    String n(Object? v) => (asInt(v)?.toString()) ?? '-';
    return SetupCard(
      key: const Key('management_summary'),
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sistem özeti',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: SetupColors.muted(context)),
          ),
          const SizedBox(height: 10),
          if (_summaryLoading && _summary == null)
            const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_summary != null)
            Row(
              children: [
                _MiniStat(label: 'Süper', value: n(users?['super_users']), color: AppTheme.accentPurple),
                const SizedBox(width: 8),
                _MiniStat(label: 'Servis', value: n(users?['service_users']), color: AppTheme.accentCyan),
                const SizedBox(width: 8),
                _MiniStat(label: 'Müşteri', value: n(users?['regular_users']), color: AppTheme.accentAmber),
                const SizedBox(width: 8),
                _MiniStat(label: 'Pano', value: n(devices?['total_devices']), color: AppTheme.accentGreen),
              ],
            ),
          if (_summaryError != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _summaryError!,
                    key: const Key('summary_error'),
                    style: const TextStyle(fontSize: 12.5, color: SetupColors.error),
                  ),
                ),
                TextButton(key: const Key('btn_summary_retry'), onPressed: _loadSummary, child: const Text('Tekrar dene')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _filters(BuildContext context, bool isSuper) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('field_search'),
          controller: _search,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: 'Ad, e-posta veya telefon ara',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    key: const Key('btn_search_clear'),
                    tooltip: 'Aramayı temizle',
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _search.clear();
                      _onSearchChanged('');
                    },
                  ),
            filled: true,
            fillColor: SetupColors.card(context),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        if (isSuper)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chip('chip_filter_all', 'Tümü', null),
                _chip('chip_filter_super', 'Süper', GlobalRole.superUser),
                _chip('chip_filter_service', 'Servis', GlobalRole.serviceUser),
                _chip('chip_filter_user', 'Müşteri', GlobalRole.user),
              ],
            ),
          ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _chip(String key, String label, GlobalRole? role) {
    return ChoiceChip(
      key: Key(key),
      label: Text(label),
      selected: _roleFilter == role,
      onSelected: (_) => _setFilter(role),
    );
  }

  List<Widget> _listBody(BuildContext context, AutomationState state, bool isSuper) {
    if (_loading && _items.isEmpty) {
      return const [
        SizedBox(height: 60),
        Center(child: CircularProgressIndicator(key: Key('accounts_loading'), color: AppTheme.accentCyan)),
      ];
    }
    if (_error != null && _items.isEmpty) {
      return [
        const SizedBox(height: 24),
        SetupCard(
          key: const Key('accounts_error'),
          accent: SetupColors.error,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SetupInfoRow(
                icon: Icons.error_outline_rounded,
                color: SetupColors.error,
                bold: true,
                text: 'Hesap listesi yüklenemedi',
              ),
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(_error!, style: TextStyle(color: SetupColors.text(context))),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                key: const Key('btn_retry'),
                onPressed: () => _loadAccounts(reset: true),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Tekrar Dene'),
              ),
            ],
          ),
        ),
      ];
    }
    if (_loaded && _items.isEmpty) {
      return [
        SetupCard(
          key: const Key('accounts_empty'),
          child: Text(
            _query.isNotEmpty || _roleFilter != null
                ? 'Aramanızla eşleşen hesap bulunamadı.'
                : 'Henüz hesap yok. "${isSuper ? 'Hesap Ekle' : 'Müşteri Ekle'}" ile başlayın.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SetupColors.muted(context)),
          ),
        ),
      ];
    }
    final me = state.currentUser;
    return [
      if (_error != null)
        SetupCard(
          key: const Key('accounts_stale'),
          accent: SetupColors.warn,
          margin: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Expanded(child: Text('Liste güncellenemedi (eski veriler gösteriliyor): $_error')),
              TextButton(
                key: const Key('btn_retry'),
                onPressed: () => _loadAccounts(reset: true),
                child: const Text('Tekrar dene'),
              ),
            ],
          ),
        ),
      for (final account in _items)
        _AccountCard(
          account: account,
          isSelf: me != null && me.id == account.id,
          actorIsSuper: isSuper,
          busy: _busyIds.contains(account.id),
          freezeBlock: AccountRules.freezeBlock(
            target: account,
            currentUserId: me?.id,
            loaded: _items,
            allSupersLoaded: _allSupersLoaded,
          ),
          onEdit: () => _edit(account, isSelf: me != null && me.id == account.id),
          onFreeze: () => _freeze(account),
          onActivate: () => _activate(account),
          onSendReset: () => _sendReset(account),
        ),
      if (_loadingMore)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
      else if (_hasMore && _error == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: OutlinedButton.icon(
            key: const Key('btn_load_more'),
            onPressed: () => _loadAccounts(reset: false),
            icon: const Icon(Icons.expand_more_rounded),
            label: const Text('Daha fazla yükle'),
          ),
        ),
    ];
  }
}

class _Denied extends StatelessWidget {
  const _Denied();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: SetupCard(
          key: Key('management_denied'),
          accent: SetupColors.warn,
          child: SetupInfoRow(
            icon: Icons.lock_outline_rounded,
            color: SetupColors.warn,
            bold: true,
            text: 'Servis yönetimi yalnızca süper yönetici ve servis personeli içindir.',
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: SetupColors.readable(context, color)),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: SetupColors.muted(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.isSelf,
    required this.actorIsSuper,
    required this.busy,
    required this.freezeBlock,
    required this.onEdit,
    required this.onFreeze,
    required this.onActivate,
    required this.onSendReset,
  });

  final AdminAccount account;
  final bool isSelf;
  final bool actorIsSuper;
  final bool busy;
  final FreezeBlock? freezeBlock;
  final VoidCallback onEdit;
  final VoidCallback onFreeze;
  final VoidCallback onActivate;
  final VoidCallback onSendReset;

  Color get _roleColor {
    switch (account.role) {
      case GlobalRole.superUser:
        return AppTheme.accentPurple;
      case GlobalRole.serviceUser:
        return AppTheme.accentCyan;
      default:
        return AppTheme.accentAmber;
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = SetupColors.text(context);
    final muted = SetupColors.muted(context);
    final roleColor = _roleColor;
    final frozen = account.isFrozen;
    final statusColor = frozen ? SetupColors.error : (account.isPendingInvite ? SetupColors.warn : SetupColors.ok);
    // Düzenleme/dondurma yetkisi: süper yönetici herkes için; servis personeli yalnızca müşteri hesapları için.
    final canManage = actorIsSuper || account.role == GlobalRole.user;
    final canSendReset = canManage && !frozen && !isSelf;
    return SetupCard(
      key: Key('card_account_${account.id}'),
      accent: frozen ? SetupColors.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isSelf ? '${account.fullName} (siz)' : account.fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: text),
                    ),
                    Text(
                      account.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _Badge(
                key: Key('role_${account.id}'),
                text: account.roleLabel,
                color: roleColor,
              ),
            ],
          ),
          if (account.phone.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(account.phone, style: TextStyle(fontSize: 12.5, color: muted)),
            ),
          if (account.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                account.notes,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: muted),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Badge(key: Key('status_${account.id}'), text: account.statusLabel, color: statusColor),
              if (account.createdByName != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Oluşturan: ${account.createdByName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: muted),
                  ),
                ),
              ],
            ],
          ),
          if (canManage || isSelf) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (canManage || isSelf)
                  OutlinedButton.icon(
                    key: Key('btn_edit_${account.id}'),
                    onPressed: busy ? null : onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Düzenle'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44)),
                  ),
                if (canSendReset)
                  OutlinedButton.icon(
                    key: Key('btn_send_reset_${account.id}'),
                    onPressed: busy ? null : onSendReset,
                    icon: const Icon(Icons.mark_email_read_outlined, size: 18),
                    label: Text(account.isPendingInvite ? 'Daveti yeniden gönder' : 'Bağlantı gönder'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44)),
                  ),
                if (canManage && !frozen)
                  OutlinedButton.icon(
                    key: Key('btn_freeze_${account.id}'),
                    onPressed: (busy || freezeBlock != null) ? null : onFreeze,
                    icon: const Icon(Icons.block_outlined, size: 18),
                    label: const Text('Dondur'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 44),
                      foregroundColor: SetupColors.readable(context, SetupColors.warn),
                    ),
                  ),
                if (canManage && frozen)
                  OutlinedButton.icon(
                    key: Key('btn_activate_${account.id}'),
                    onPressed: busy ? null : onActivate,
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                    label: const Text('Aktifleştir'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 44),
                      foregroundColor: SetupColors.readable(context, SetupColors.ok),
                    ),
                  ),
              ],
            ),
            if (canManage && !frozen && freezeBlock != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  AccountRules.freezeBlockText(freezeBlock!),
                  key: Key('note_freeze_block_${account.id}'),
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Salt okunur: bu hesabı yalnızca süper yönetici yönetebilir.',
                key: Key('note_readonly_${account.id}'),
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: SetupColors.readable(context, color)),
      ),
    );
  }
}
