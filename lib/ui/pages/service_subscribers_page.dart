import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../theme/app_theme.dart';
import 'service_setup/panel/assign_admin_dialog.dart';
import 'service_setup/panel/subscriber_models.dart';
import 'service_setup/session_banner.dart';
import 'service_setup/setup_style.dart';

/// Yetkili Servis Sorumlusu - Abonelerim & Cihaz Atama
///
/// Servis sorumlusunun devreye aldığı (ya da yetkili olduğu) daireleri listeler (**sayfalı**, **300 ms
/// gecikmeli arama**), pano durumunu gösterir ve ev sahibini "Home Admin" olarak atar/devreder:
/// bilgi formu -> ikinci onay penceresi -> (mevcut sahip varsa) sahibe giden onay kodu -> atama.
///
/// Yükleme hatası **görünür** kalır (bayat liste yenileme hatasıyla birlikte uyarılır); sonsuz
/// yükleme dönmez (zaman aşımı + hata + yeniden dene).
class ServiceSubscribersPage extends StatefulWidget {
  const ServiceSubscribersPage({super.key, this.pageSize = 30});

  /// Sayfa başına abone sayısı.
  final int pageSize;

  @override
  State<ServiceSubscribersPage> createState() => _ServiceSubscribersPageState();
}

class _ServiceSubscribersPageState extends State<ServiceSubscribersPage> {
  static const Duration _searchDebounce = Duration(milliseconds: 300);
  static const Duration _requestTimeout = Duration(seconds: 25);

  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<Subscriber> _items = const <Subscriber>[];
  int? _total;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loaded = false;
  String? _error;
  String _query = '';
  int _requestSeq = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(reset: true));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
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
      unawaited(_load(reset: false));
    }
  }

  Future<void> _load({required bool reset}) async {
    final state = context.read<AutomationState>();
    if (!state.capabilities.canViewInventory) {
      setState(() {
        _error = 'Bu sayfa yalnızca servis personeli ve süper yönetici içindir.';
        _loaded = true;
      });
      return;
    }
    final seq = ++_requestSeq;
    setState(() {
      if (reset) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });
    try {
      final page = await state.cloudApi
          .fetchServiceSubscribersPage(
            limit: widget.pageSize,
            offset: reset ? 0 : _items.length,
            search: _query.isEmpty ? null : _query,
          )
          .timeout(_requestTimeout);
      if (!mounted || seq != _requestSeq) return;
      final parsed = parseSubscribers(page.items);
      setState(() {
        _items = reset ? parsed : <Subscriber>[..._items, ...parsed];
        _total = page.total;
        _loading = false;
        _loadingMore = false;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = friendlyError(e, fallback: 'Aboneler yüklenemedi. Lütfen tekrar deneyin.');
        _loading = false;
        _loadingMore = false;
        _loaded = true;
      });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final clock = context.read<AutomationState>().clock;
    _debounce = clock.timer(_searchDebounce, () {
      if (!mounted) return;
      final next = value.trim();
      if (next == _query) return;
      _query = next;
      unawaited(_load(reset: true));
    });
    setState(() {});
  }

  Future<void> _assign(Subscriber s) async {
    final outcome = await AssignAdminDialog.show(context, s);
    if (outcome == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('snack_assign_done'),
        backgroundColor: outcome.hasWarnings ? AppTheme.accentAmber : AppTheme.accentGreen,
        content: Text(outcome.message),
      ),
    );
    unawaited(_load(reset: true));
    if (outcome.hasWarnings) await AssignWarningsDialog.show(context, outcome);
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _total ?? _items.length;
    final assigned = _items.where((s) => s.hasOwner).length;
    final pending = _items.length - assigned;
    // Liste sayfalıdır: "Toplam" sunucu toplamıdır, ama "Home Admin Var" / "Atama Bekleyen" yalnızca yüklenen
    // satırlardan sayılabilir. Daha yüklenmemiş kayıt varsa bu değerler "en az" anlamında "N+" yazılır
    // (tutarsız / yanıltıcı kesin sayı gösterilmez).
    final partial = _hasMore;
    String atLeast(int n) => partial ? '$n+' : '$n';

    return Scaffold(
      backgroundColor: AppTheme.getScaffoldBg(context),
      appBar: AppBar(
        title: Text(
          'Abonelerim & Cihaz Atama',
          style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
        ),
        backgroundColor: AppTheme.getSurfaceColor(context),
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.getTextPrimary(context)),
        actions: [
          IconButton(
            key: const Key('btn_refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Yenile',
            onPressed: _loading ? null : () => _load(reset: true),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: AppTheme.getSurfaceColor(context),
            child: Column(
              children: [
                const Align(alignment: Alignment.centerLeft, child: ServiceSessionBanner()),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _statChip(context, 'Toplam Abone', '$totalCount', Icons.holiday_village_outlined, AppTheme.primaryBlue,
                          valueKey: 'stat_total'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _statChip(context, 'Home Admin Var', atLeast(assigned), Icons.verified_user_outlined, AppTheme.accentGreen,
                          valueKey: 'stat_assigned'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _statChip(context, 'Atama Bekleyen', atLeast(pending), Icons.hourglass_top_outlined, AppTheme.accentAmber,
                          valueKey: 'stat_pending'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('field_search'),
                  controller: _search,
                  onChanged: _onSearchChanged,
                  style: TextStyle(fontSize: 14, color: AppTheme.getTextPrimary(context)),
                  decoration: InputDecoration(
                    hintText: 'Daire adı, adres, pano UUID veya müşteri ara...',
                    hintStyle: TextStyle(fontSize: 13, color: AppTheme.getTextMuted(context)),
                    prefixIcon: Icon(Icons.search, size: 20, color: AppTheme.getTextMuted(context)),
                    suffixIcon: _search.text.isNotEmpty
                        ? IconButton(
                            key: const Key('btn_search_clear'),
                            tooltip: 'Aramayı temizle',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _search.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppTheme.getCardColor(context),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.getCardBorder(context)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: RefreshIndicator(onRefresh: () => _load(reset: true), child: _body(context))),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator(key: Key('subscribers_loading'))),
        ],
      );
    }
    if (_error != null && _items.isEmpty) {
      return _centered(
        context,
        key: const Key('subscribers_error'),
        icon: Icons.error_outline,
        color: AppTheme.accentRed,
        title: 'Aboneler Yüklenemedi',
        text: _error!,
        action: ElevatedButton.icon(
          key: const Key('btn_retry'),
          onPressed: () => _load(reset: true),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Tekrar Dene'),
        ),
      );
    }
    if (_loaded && _items.isEmpty) {
      return _centered(
        context,
        key: const Key('subscribers_empty'),
        icon: _query.isNotEmpty ? Icons.search_off : Icons.group_off_outlined,
        color: AppTheme.getTextMuted(context),
        title: _query.isNotEmpty ? 'Aramanıza uygun daire veya pano bulunamadı' : 'Henüz kayıtlı bir daire veya pano bulunmuyor',
        text: _query.isNotEmpty
            ? 'Lütfen arama teriminizi kontrol edin.'
            : 'Devreye aldığınız cihazlar ve bağlı daireler burada listelenir.',
      );
    }
    // Yenileme/ek sayfa hatası varsa listenin üstünde uyarı gösterilir (bayat liste sessiz kalmaz).
    final offset = _error != null ? 1 : 0;
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      itemCount: offset + _items.length + 1,
      itemBuilder: (context, index) {
        if (index < offset) return _staleBanner(context);
        final i = index - offset;
        if (i < _items.length) return _card(context, _items[i]);
        return _footer(context);
      },
    );
  }

  Widget _staleBanner(BuildContext context) {
    return Container(
      key: const Key('subscribers_stale'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.accentAmber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppTheme.accentAmber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Liste güncellenemedi (eski veriler gösteriliyor): $_error',
              style: TextStyle(fontSize: 12.5, color: AppTheme.getTextPrimary(context)),
            ),
          ),
          TextButton(
            key: const Key('btn_retry'),
            onPressed: () => _load(reset: true),
            child: const Text('Tekrar dene'),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_hasMore && _error == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: OutlinedButton.icon(
          key: const Key('btn_load_more'),
          onPressed: () => _load(reset: false),
          icon: const Icon(Icons.expand_more_rounded),
          label: const Text('Daha fazla yükle'),
        ),
      );
    }
    return const SizedBox(height: 40);
  }

  Widget _centered(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required Color color,
    required String title,
    required String text,
    Widget? action,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 60),
        Padding(
          key: key,
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(icon, size: 52, color: color),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
              ),
              const SizedBox(height: 6),
              Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppTheme.getTextMuted(context))),
              if (action != null) ...[const SizedBox(height: 16), action],
            ],
          ),
        ),
      ],
    );
  }

  Widget _statChip(BuildContext context, String title, String value, IconData icon, Color color, {required String valueKey}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.getCardBorder(context)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  value,
                  key: Key(valueKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: AppTheme.getTextMuted(context)),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, Subscriber s) {
    final owner = s.owner;
    final hasOwner = s.hasOwner;
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    return Container(
      key: Key('card_subscriber_${s.homeId}'),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasOwner ? AppTheme.getCardBorder(context) : AppTheme.accentAmber.withValues(alpha: 0.4),
          width: hasOwner ? 1 : 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.home_outlined, color: AppTheme.primaryBlue, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${s.homeName} (#${s.shortId})',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: primary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.address.isEmpty ? 'Adres belirtilmemiş' : s.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _commissionBadge(s.isCommissioned),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.developer_board, size: 15, color: muted),
                ),
                const SizedBox(width: 6),
                Text('Pano UUID: ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: muted)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (s.deviceUuids.isEmpty)
                        Text('Pano tanımsız', style: TextStyle(fontSize: 12, color: muted))
                      else
                        for (final uid in s.deviceUuids)
                          Text(
                            uid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: primary),
                          ),
                      if (s.hiddenDeviceCount > 0)
                        Text('+${s.hiddenDeviceCount} pano daha', style: TextStyle(fontSize: 11.5, color: muted)),
                      if (s.deviceCount > 0)
                        Text(
                          '${s.deviceCount} pano • ${s.onlineCount} çevrimiçi',
                          key: Key('devices_summary_${s.homeId}'),
                          style: TextStyle(fontSize: 11.5, color: muted),
                        ),
                    ],
                  ),
                ),
                if (s.deviceUuid.isNotEmpty)
                  IconButton(
                    key: Key('btn_copy_uuid_${s.homeId}'),
                    icon: const Icon(Icons.copy, size: 14),
                    tooltip: 'UUID Kopyala',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: s.deviceUuid));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Pano UUID panoya kopyalandı'), duration: Duration(seconds: 1)),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (hasOwner ? AppTheme.accentGreen : AppTheme.accentAmber).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: (hasOwner ? AppTheme.accentGreen : AppTheme.accentAmber).withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(
                    hasOwner ? Icons.workspace_premium : Icons.person_off_outlined,
                    color: hasOwner ? AppTheme.accentGreen : AppTheme.accentAmber,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasOwner ? 'Home Admin: ${owner!.fullName}' : 'Home Admin henüz atanmadı',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: SetupColors.readable(context, hasOwner ? AppTheme.accentGreen : AppTheme.accentAmber),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasOwner ? owner!.contact : 'Pano şu an servis kontrolünde. Daire sahibine devredin.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: hasOwner
                  ? OutlinedButton.icon(
                      key: Key('btn_assign_admin_${s.homeId}'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        side: BorderSide(color: AppTheme.getCardBorder(context)),
                      ),
                      onPressed: () => _assign(s),
                      icon: const Icon(Icons.swap_horiz, size: 16),
                      label: const Text('Yöneticiyi Devret', style: TextStyle(fontSize: 12)),
                    )
                  : ElevatedButton.icon(
                      key: Key('btn_assign_admin_${s.homeId}'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(48, 44),
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => _assign(s),
                      icon: const Icon(Icons.person_add_alt_1, size: 16),
                      label: const Text('Home Admin Ata', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commissionBadge(bool commissioned) {
    final color = commissioned ? AppTheme.accentGreen : AppTheme.accentAmber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(commissioned ? Icons.check_circle : Icons.pending_outlined, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            commissioned ? 'Devrede' : 'Bekliyor',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}
