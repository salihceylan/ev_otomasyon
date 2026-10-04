import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../motion/skeleton.dart';
import '../theme/app_theme.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import '../widgets/neon_app_bar.dart';
import '../widgets/orb/glass_icon_button.dart';
import '../widgets/orb/orb_icon_badge.dart';
import '../widgets/settings/accent_button.dart';
import 'service_setup/panel/assign_admin_dialog.dart';
import 'service_setup/panel/service_glass.dart';
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
///
/// Sayfa TEK kaydırma alanıdır: oturum bandı, sayaçlar ve arama kutusu listenin ilk öğeleridir (sabit bir üst bant büyük
/// yazıda ekranın yarısını yerdi ve opak zemin küresel devre kartı arka planını örterdi); arama kutusu her durumda
/// (yükleniyor/hata/boş/liste) AYNI ağaç konumunda kalır, böylece yazarken odak kaybolmaz.
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
        // Beyaz yazılı zemin AA kontrastlı tonda (ham amber/yeşil üstünde beyaz ≈ 2:1'di).
        backgroundColor: AppTheme.filledAccent(outcome.hasWarnings ? AppTheme.accentAmber : AppTheme.accentGreen),
        content: Text(outcome.message),
      ),
    );
    unawaited(_load(reset: true));
    if (outcome.hasWarnings) await AssignWarningsDialog.show(context, outcome);
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold arka planı temadan saydam gelir: küresel `CircuitBackground` (AppShell) görünür; opak zemin ve opak bant
    // yok (PF-15 c).
    return Scaffold(
      appBar: NeonAppBar(
        title: 'Abonelerim & Cihaz Atama',
        feature: AppFeature.subscribers,
        icon: Icons.people_alt_rounded,
        actions: [
          ServiceRefreshAction(key: const Key('btn_refresh'), onPressed: _loading ? null : () => _load(reset: true)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () => _load(reset: true),
          color: AppTheme.accentTone(context, AppFeature.subscribers.accentFamily),
          child: _list(context),
        ),
      ),
    );
  }

  /// Yükleniyor / hata / boş durum gövdesi; `null` ise kartlar gösterilir.
  Widget? _stateBody(BuildContext context) {
    if (_items.isEmpty && _error == null && (_loading || !_loaded)) {
      return Semantics(
        label: 'Aboneler yükleniyor',
        liveRegion: true,
        child: const ServiceListSkeleton(key: Key('subscribers_loading'), count: 4, lines: 3),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 32, 8, 0),
        child: ServiceEmptyState(
          key: const Key('subscribers_error'),
          icon: Icons.error_outline_rounded,
          family: AppFamilies.rose,
          size: OrbSize.xl,
          glow: true,
          title: 'Aboneler Yüklenemedi',
          message: _error!,
          action: ElevatedButton.icon(
            key: const Key('btn_retry'),
            onPressed: () => _load(reset: true),
            icon: Icon(Icons.refresh_rounded, size: accentIconSize(context, base: 18)),
            label: const Text('Tekrar Dene'),
          ),
        ),
      );
    }
    if (_loaded && _items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 32, 8, 0),
        child: ServiceEmptyState(
          key: const Key('subscribers_empty'),
          icon: _query.isNotEmpty ? Icons.search_off_rounded : Icons.holiday_village_rounded,
          family: AppFeature.subscribers.accentFamily,
          size: OrbSize.xl,
          glow: true,
          title: _query.isNotEmpty ? 'Aramanıza uygun daire veya pano bulunamadı' : 'Henüz kayıtlı bir daire veya pano bulunmuyor',
          message: _query.isNotEmpty
              ? 'Lütfen arama teriminizi kontrol edin.'
              : 'Devreye aldığınız cihazlar ve bağlı daireler burada listelenir.',
        ),
      );
    }
    return null;
  }

  Widget _list(BuildContext context) {
    final stateBody = _stateBody(context);
    final cards = stateBody == null;
    // Yenileme/ek sayfa hatası varsa listenin üstünde uyarı gösterilir (bayat liste sessiz kalmaz).
    final header = <Widget>[
      const Align(alignment: AlignmentDirectional.centerStart, child: ServiceSessionBanner()),
      Padding(padding: const EdgeInsets.only(top: 12), child: _stats(context)),
      Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: _searchField(context)),
      if (cards && _error != null)
        ServiceStaleBanner(
          key: const Key('subscribers_stale'),
          message: 'Liste güncellenemedi (eski veriler gösteriliyor): $_error',
          onRetry: () => _load(reset: true),
        ),
    ];
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: header.length + (cards ? _items.length + 1 : 1),
      itemBuilder: (context, index) {
        if (index < header.length) return header[index];
        final i = index - header.length;
        if (stateBody != null) return stateBody;
        if (i < _items.length) return _card(context, _items[i]);
        return _footer(context);
      },
    );
  }

  /// Sayaç şeridi: "Toplam" sunucu toplamıdır; "Home Admin Var" / "Atama Bekleyen" yalnızca yüklenen satırlardan sayılabilir.
  /// Daha yüklenmemiş kayıt varsa bu değerler "en az" anlamında "N+" yazılır (tutarsız kesin sayı gösterilmez). Yüklenirken
  /// iskelet, yüklenemediyse "—" (uydurma sıfır YOK).
  Widget _stats(BuildContext context) {
    final noData = _items.isEmpty;
    final loading = noData && _error == null && (_loading || !_loaded);
    final unknown = noData && _error != null;
    final hide = loading || unknown;
    final assigned = _items.where((s) => s.hasOwner).length;
    final pending = _items.length - assigned;
    final partial = _hasMore;
    String Function(int) fmt(bool plus) => (int n) => plus ? '$n+' : '$n';
    return ServiceStatStrip(
      tiles: [
        ServiceStatTile(
          valueKey: const Key('stat_total'),
          label: 'Toplam Abone',
          color: AppTheme.primaryBlue,
          icon: Icons.holiday_village_rounded,
          value: hide ? null : (_total ?? _items.length),
          loading: loading,
        ),
        ServiceStatTile(
          valueKey: const Key('stat_assigned'),
          label: 'Home Admin Var',
          color: AppTheme.accentGreen,
          icon: Icons.verified_user_rounded,
          value: hide ? null : assigned,
          format: fmt(partial),
          loading: loading,
        ),
        ServiceStatTile(
          valueKey: const Key('stat_pending'),
          label: 'Atama Bekleyen',
          color: AppTheme.accentAmber,
          icon: Icons.hourglass_top_rounded,
          value: hide ? null : pending,
          format: fmt(partial),
          loading: loading,
        ),
      ],
    );
  }

  Widget _searchField(BuildContext context) {
    return TextField(
      key: const Key('field_search'),
      controller: _search,
      onChanged: _onSearchChanged,
      style: TextStyle(fontSize: AppText.body, color: AppTheme.getTextPrimary(context)),
      decoration: InputDecoration(
        // Kısa etiket + kısa örnek ipucu (eskiden "Daire adı, adres, pano UUID veya müşter…" diye kesiliyordu); renkleri tema verir.
        labelText: 'Abone ara',
        floatingLabelBehavior: FloatingLabelBehavior.always,
        hintText: 'Daire, adres, UUID veya müşteri',
        // Tek satır: Flutter ipucunu alan DOLUYKEN de yerleşime kattığından iki satırlık ipucu büyük yazıda alanı gereksiz şişirir.
        hintMaxLines: 1,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: _search.text.isNotEmpty
            ? IconButton(
                key: const Key('btn_search_clear'),
                tooltip: 'Aramayı temizle',
                icon: const Icon(Icons.clear_rounded, size: 18),
                onPressed: () {
                  _search.clear();
                  _onSearchChanged('');
                },
              )
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    if (_loadingMore) {
      return const Padding(padding: EdgeInsets.only(top: 4, bottom: 16), child: SkeletonCard(lines: 2));
    }
    if (_hasMore && _error == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: OutlinedButton.icon(
          key: const Key('btn_load_more'),
          onPressed: () => _load(reset: false),
          icon: Icon(Icons.expand_more_rounded, size: accentIconSize(context, base: 20)),
          label: const Text('Daha fazla yükle'),
          // Çerçeve + metin + simge AYNI aileden ve AA (tema varsayılan çerçevesi açıkta ≈ 2.4:1'di; kart düğmeleriyle aynı dil).
          style: accentOutlinedButtonStyle(context, AppFeature.subscribers.accentFamily),
        ),
      );
    }
    return const SizedBox(height: 24);
  }

  Widget _card(BuildContext context, Subscriber s) {
    final owner = s.owner;
    final hasOwner = s.hasOwner;
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    final large = SetupText.isLargeText(context);
    final pill = _commissionBadge(s.isCommissioned);
    return ServiceCard(
      key: Key('card_subscriber_${s.homeId}'),
      accent: hasOwner ? null : AppTheme.accentAmber,
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OrbIconBadge(icon: Icons.home_rounded, family: AppFamilies.sky),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${s.homeName} (#${s.shortId})',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w800, color: primary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.address.isEmpty ? 'Adres belirtilmemiş' : s.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: AppText.caption, color: muted),
                    ),
                  ],
                ),
              ),
              // Büyük yazıda durum hapı adı sıkıştırmasın: başlığın altına iner.
              if (!large) ...[const SizedBox(width: 8), pill],
            ],
          ),
          if (large) Padding(padding: const EdgeInsets.only(top: 8), child: Wrap(children: [pill])),
          const SizedBox(height: 12),
          Divider(height: 1, color: AppTheme.getCardBorder(context)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Icon(Icons.developer_board_rounded, size: 18, color: muted),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pano UUID', style: TextStyle(fontSize: AppText.badge, fontWeight: FontWeight.w500, color: muted)),
                      if (s.deviceUuids.isEmpty)
                        Text('Pano tanımsız', style: TextStyle(fontSize: AppText.caption, color: muted))
                      else
                        for (final uid in s.deviceUuids)
                          // Kimlik tek satır: tireden bölünüp iki satıra yayılmaz, sığmazsa küçülür.
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              uid,
                              maxLines: 1,
                              softWrap: false,
                              style: SetupText.mono(fontSize: 13, fontWeight: FontWeight.w700, color: primary),
                            ),
                          ),
                      if (s.hiddenDeviceCount > 0)
                        Text('+${s.hiddenDeviceCount} pano daha', style: TextStyle(fontSize: AppText.caption, color: muted)),
                      if (s.deviceCount > 0)
                        Text(
                          '${s.deviceCount} pano • ${s.onlineCount} çevrimiçi',
                          key: Key('devices_summary_${s.homeId}'),
                          style: TextStyle(fontSize: AppText.caption, color: muted),
                        ),
                    ],
                  ),
                ),
              ),
              if (s.deviceUuid.isNotEmpty)
                // Küçük cam disk (36 dp görsel / 48 dp hedef): eskiden çıplak düz Material kopyala simgesiydi (üst çubuk ve kapat
                // düğmeleriyle aynı cam dil).
                GlassIconButton(
                  key: Key('btn_copy_uuid_${s.homeId}'),
                  icon: Icons.copy_rounded,
                  semanticLabel: 'UUID Kopyala',
                  size: 36,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: s.deviceUuid));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Pano UUID panoya kopyalandı'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          ServiceTintBox(
            color: hasOwner ? AppTheme.accentGreen : AppTheme.accentAmber,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OrbIconBadge(
                  icon: hasOwner ? Icons.workspace_premium_rounded : Icons.person_off_rounded,
                  family: hasOwner ? AppFamilies.emerald : AppFamilies.amber,
                  size: OrbSize.sm,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasOwner ? 'Home Admin: ${owner!.fullName}' : 'Home Admin henüz atanmadı',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppText.body,
                          fontWeight: FontWeight.w800,
                          color: SetupColors.readable(context, hasOwner ? AppTheme.accentGreen : AppTheme.accentAmber),
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Yönlendirici metin KESİLMEZ ("devredin." talimatı kaybolmasın); yalnız uzun iletişim bilgisi 2 satırla sınırlı.
                      Text(
                        hasOwner ? owner!.contact : 'Pano şu an servis kontrolünde. Daire sahibine devredin.',
                        maxLines: hasOwner ? 2 : null,
                        overflow: hasOwner ? TextOverflow.ellipsis : null,
                        style: TextStyle(fontSize: AppText.caption, height: 1.3, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Tek eylem tam genişlikte, tema hapı ve aile tonu (yerel backgroundColor/şekil kırpılmış yüzeyin altında "hayalet köşe"
          // bırakıyordu); yükseklik >= 48 dp.
          ServiceActionGrid(
            columns: 1,
            children: [
              if (hasOwner)
                OutlinedButton.icon(
                  key: Key('btn_assign_admin_${s.homeId}'),
                  style: accentOutlinedButtonStyle(context, AppFamilies.sky),
                  onPressed: () => _assign(s),
                  icon: Icon(Icons.swap_horiz_rounded, size: accentIconSize(context, base: 18)),
                  label: const Text('Yöneticiyi Devret', textAlign: TextAlign.center),
                )
              else
                ElevatedButton.icon(
                  key: Key('btn_assign_admin_${s.homeId}'),
                  style: accentButtonStyle(AppFamilies.sky),
                  onPressed: () => _assign(s),
                  icon: Icon(Icons.person_add_alt_1_rounded, size: accentIconSize(context, base: 18)),
                  label: const Text('Home Admin Ata', textAlign: TextAlign.center),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _commissionBadge(bool commissioned) {
    final color = commissioned ? AppTheme.accentGreen : AppTheme.accentAmber;
    return ServiceStatusPill(label: commissioned ? 'Devrede' : 'Bekliyor', color: color);
  }
}
