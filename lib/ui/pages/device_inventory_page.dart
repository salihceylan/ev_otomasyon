import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/cloud_models.dart';
import '../../models/json_utils.dart';
import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../common/app_dialogs.dart';
import '../common/confirm_dialogs.dart';
import '../common/date_format.dart';
import '../motion/skeleton.dart';
import '../theme/app_theme.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import '../widgets/app_pill.dart';
import '../widgets/neon_app_bar.dart';
import '../widgets/settings/accent_button.dart';
import 'service_setup/panel/service_glass.dart';
import 'service_setup/panel/label_reissue_dialog.dart';
import 'service_setup/secret_clipboard.dart';
import 'service_setup/setup_style.dart';

/// AHBU Akıllı Ev & Bina Otomasyonu
/// Cihaz Envanteri ve Karekod Yönetim Paneli (Süper Yönetici & Yetkili Servis)
///
/// * Liste **sayfalı** ve aramada 300 ms gecikmelidir; yenileme hatası görünür kalır (bayat liste
///   uyarılır, sessizce eski veri gösterilmez).
/// * Durum geçişleri kısıtlıdır: yalnızca **Stokta <-> Askıda**. Devrede (CLAIMED) cihaz için
///   "Askıya Al" ve "Sil" gösterilmez; iptal edilmiş cihaz yalnızca **UID yazarak** silinir.
/// * Silme ve etiket yeniden üretimi **cihaz seri numarasını yazarak** onaylanır.
/// * Panoya kopyalanan her değer 45 sn sonra silinir.
/// * Hiçbir PIN / QR / e-posta bilgisi loglanmaz.
class DeviceInventoryPage extends StatefulWidget {
  /// [autoLoad] `false` ise sunucudan otomatik yüklenmez; durumda hâlihazırda bulunan envanter
  /// gösterilir (yenile ile yüklenir).
  const DeviceInventoryPage({super.key, this.autoLoad = true, this.pageSize = 50});

  final bool autoLoad;
  final int pageSize;

  @override
  State<DeviceInventoryPage> createState() => _DeviceInventoryPageState();
}

class _DeviceInventoryPageState extends State<DeviceInventoryPage> {
  static const Duration _searchDebounce = Duration(milliseconds: 300);
  static const Duration _requestTimeout = Duration(seconds: 25);

  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String _statusFilter = 'ALL';
  String _query = '';
  List<InventoryDeviceModel> _items = const <InventoryDeviceModel>[];
  Map<String, int> _stats = const <String, int>{};
  int? _total;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loaded = false;
  String? _error;
  int _requestSeq = 0;
  Timer? _debounce;
  final Set<String> _busyDevices = <String>{};

  /// Etiket yeniden üretimi sürüyor: tek seferlik PIN/anahtar gelene kadar sayfadan çıkılamaz.
  bool _reissuing = false;

  /// Yeniden üretim isteği YANITI bekleniyor (ilerleme göstergesi): [_reissuing]'den farklı olarak sonuç penceresi
  /// açıkken `false`'tur, böylece pencerenin arkasında sonsuz animasyon dönmez.
  bool _reissueWaiting = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final state = context.read<AutomationState>();
    _items = state.inventoryDevices;
    // `AutomationState.inventoryStats` başlangıçta (oturum açılışı/çıkışı) dört anahtarı da SIFIR olan bir haritadır: "henüz
    // yüklenmedi" ile "gerçekten 0 cihaz" ayırt edilemez. Envanter listesi durumda dolu geldiyse sayaçları da gerçektir
    // (`fetchInventory` ikisini birlikte yazar); liste boşsa sayaçlar BİLİNMİYOR sayılır ve sayfanın kendi yanıtı gelene kadar
    // iskelet gösterilir (eskiden "0 Toplam / 0 Stokta / 0 Devrede / 0 Askıda" uydurma sıfırları yükleme sırasında çıkıyordu).
    _stats = _items.isEmpty ? const <String, int>{} : state.inventoryStats;
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(reset: true));
      });
    } else {
      _loaded = true;
    }
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
        _error = 'Cihaz envanteri yalnızca süper yönetici ve servis personeli içindir.';
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
      final res = await state.cloudApi
          .fetchDeviceInventory(
            status: _statusFilter == 'ALL' ? null : _statusFilter,
            search: _query.isEmpty ? null : _query,
            limit: widget.pageSize,
            offset: reset ? 0 : _items.length,
          )
          .timeout(_requestTimeout);
      if (!mounted || seq != _requestSeq) return;
      final parsed = parseList(res['items'], InventoryDeviceModel.fromJson, label: 'Inventory');
      final stats = asMap(res['stats']);
      setState(() {
        _items = reset ? parsed : <InventoryDeviceModel>[..._items, ...parsed];
        _total = asInt(res['total']);
        if (stats != null) {
          _stats = <String, int>{
            'total': asInt(stats['total']) ?? _items.length,
            'in_stock': asInt(stats['in_stock']) ?? 0,
            'claimed': asInt(stats['claimed']) ?? 0,
            'suspended': asInt(stats['suspended']) ?? 0,
            'revoked': asInt(stats['revoked']) ?? 0,
          };
        }
        _loading = false;
        _loadingMore = false;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = friendlyError(e, fallback: 'Envanter yüklenemedi. Lütfen tekrar deneyin.');
        _loading = false;
        _loadingMore = false;
        _loaded = true;
      });
    }
  }

  void _onFilterChanged(String status) {
    if (status == _statusFilter) return;
    setState(() => _statusFilter = status);
    unawaited(_load(reset: true));
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

  // ---------------------------------------------------------------------------
  // Yetkiler (durum geçiş matrisi)
  // ---------------------------------------------------------------------------

  static bool canSuspend(InventoryDeviceModel d) => d.isInStock;
  /// Askıdaki ya da iptal edilmiş cihaz stoğa alınabilir (sunucu geçişleri: SUSPENDED/REVOKED -> IN_STOCK).
  static bool canRestore(InventoryDeviceModel d) => d.isSuspended || d.isRevoked;

  /// Devrede (CLAIMED/INSTALLED) cihaz silinemez.
  static bool canDelete(InventoryDeviceModel d) => !d.isClaimed;

  /// Etiket yeniden üretimi yalnızca **stoktaki** (IN_STOCK), henüz hiçbir daireye bağlı olmayan cihaz için
  /// (sunucu askıdaki/devredeki cihazda 409 döner).
  static bool canReissue(InventoryDeviceModel d) => d.isInStock;

  @override
  Widget build(BuildContext context) {
    // Sayfa kökü tüm durumu izlemez (PF-06): yalnızca yönetim yetkisi görünümü değiştirir. Her bildirimde
    // (canlı durum, çevrimiçi/çevrimdışı geçişleri) sayfa ve tüm envanter kartları yeniden kurulmaz.
    final manage = context.select<AutomationState, bool>((s) => s.capabilities.canManageInventory);

    return PopScope(
      canPop: !_reissuing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _reissuing) {
          _snack('Yeni etiket bilgileri alınıyor. Bu bilgiler yalnızca bir kez gösterilir: işlem bitene kadar sayfadan çıkılamaz.');
        }
      },
      child: _scaffold(context, manage),
    );
  }

  Widget _scaffold(BuildContext context, bool manage) {
    // Scaffold arka planı temadan saydam gelir: küresel `CircuitBackground` (AppShell) görünür. Burada ikinci bir
    // `CircuitBackground` + opak zemin, küresel katmanı tamamen örtüyordu; tam ekran katmanlar (düz renk, JPEG,
    // gradyan, PCB boyası) yine de ikinci kez çizilirdi (PF-15 c).
    return Scaffold(
      appBar: NeonAppBar(
        title: 'Cihaz Envanteri',
        // Metin pinli (`neon_app_bar_test`: sayfa alt başlığı). 360 dp'de yenile diski yüzünden 2 satıra sarıp yetim sözcük
        // ("Takibi") bırakır: çözüm NeonAppBar'ın dengeli sarması (BalancedText) / tek satır seçeneğidir (temel ajana istek).
        subtitle: 'Karekodlar, Seri No & Donanım Takibi',
        feature: AppFeature.inventory,
        icon: Icons.inventory_2_rounded,
        actions: [
          ServiceRefreshAction(key: const Key('btn_refresh'), onPressed: _loading ? null : () => _load(reset: true)),
        ],
        // Etiket yeniden üretimi sürerken (tek seferlik PIN/anahtar gelene kadar sayfadan çıkılamaz) ilerleme
        // göstergesi: kilidin neden sürdüğü görünür (PF-50). 3 dp'lik yer her zaman ayrılır: gösterge çıkıp
        // kalkarken içerik kaymaz.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _reissueWaiting
              ? LinearProgressIndicator(
                  key: const Key('inventory_reissue_progress'),
                  minHeight: 3,
                  color: AppTheme.accentTone(context, AppFeature.inventory.accentFamily),
                  semanticsLabel: 'Yeni etiket bilgileri alınıyor',
                )
              : const SizedBox(height: 3),
        ),
      ),
      // Sayfa TEK kaydırma alanıdır: sayaçlar, arama ve filtre çipleri listenin ilk öğeleridir (sabit bir üst bant büyük yazıda
      // ekranın yarısını yerdi); arama kutusu her durumda AYNI ağaç konumunda kalır, yazarken odak kaybolmaz.
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () => _load(reset: true),
          color: AppTheme.accentTone(context, AppFeature.inventory.accentFamily),
          child: _list(context, manage),
        ),
      ),
    );
  }

  /// Sayaç şeridi: iskelet yer tutucu / "—" / gerçek değer (UYDURMA SIFIR YOK). Yüklenirken eskiden "0 Toplam / 0 Stokta ..."
  /// yazılıyordu ve boş envanter gibi okunuyordu; konsol sayaç kalıbı: iskelet + hata/bilinmiyorsa "—".
  Widget _statsHeader(BuildContext context) {
    final noData = _stats.isEmpty && _items.isEmpty;
    final statsLoading = noData && (_loading || (!_loaded && widget.autoLoad));
    final statsUnknown = noData && !statsLoading && _error != null;
    final hide = statsLoading || statsUnknown;
    int? pick(String key, {int? fallback}) => hide ? null : (_stats[key] ?? fallback ?? 0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: ServiceStatStrip(
        tiles: [
          ServiceStatTile(
            key: const Key('stat_inventory_total'),
            label: 'Toplam',
            color: AppTheme.primaryBlue,
            value: pick('total', fallback: _items.length),
            loading: statsLoading,
          ),
          ServiceStatTile(
            key: const Key('stat_inventory_in_stock'),
            label: 'Stokta',
            color: AppTheme.accentGreen,
            value: pick('in_stock'),
            loading: statsLoading,
          ),
          ServiceStatTile(
            key: const Key('stat_inventory_claimed'),
            label: 'Devrede',
            color: AppTheme.accentCyan,
            value: pick('claimed'),
            loading: statsLoading,
          ),
          ServiceStatTile(
            key: const Key('stat_inventory_suspended'),
            label: 'Askıda',
            color: AppTheme.accentAmber,
            value: pick('suspended'),
            loading: statsLoading,
          ),
        ],
      ),
    );
  }

  Widget _searchAndFilters(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: TextField(
            key: const Key('field_search'),
            controller: _search,
            onChanged: _onSearchChanged,
            style: TextStyle(color: primary, fontSize: 14),
            decoration: InputDecoration(
              // Kısa etiket + kısa örnek ipucu (eskiden "UUID, MAC, Seri No veya D…" diye kesiliyordu); renkleri tema verir.
              labelText: 'Cihaz ara',
              floatingLabelBehavior: FloatingLabelBehavior.always,
              hintText: 'UUID, MAC, seri no, daire',
              // Tek satır: Flutter ipucunu alan DOLUYKEN de yerleşime kattığından iki satırlık ipucu büyük yazıda alanı gereksiz şişirir.
              hintMaxLines: 1,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _search.text.isNotEmpty
                  ? IconButton(
                      tooltip: 'Aramayı temizle',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _search.clear();
                        _onSearchChanged('');
                      },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            ),
          ),
        ),
        // Filtre çipleri: yatay dolgu kaydırma alanının İÇİNDE (çipler ekran kenarına kadar kayar; eskiden 16 dp'lik dış
        // dolguda sert kırpılıp "As" diye kesik görünüyordu). Çip stilini (seçili dolgu/kenar/etiket) TEMA verir.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _filterChip('ALL', 'Tümü'),
              const SizedBox(width: 8),
              _filterChip('IN_STOCK', 'Stokta Hazır'),
              const SizedBox(width: 8),
              _filterChip('CLAIMED', 'Devrede / Aktif'),
              const SizedBox(width: 8),
              _filterChip('SUSPENDED', 'Askıya Alınan'),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Durum filtre çipi: ortak [AppChip] (seçili = cyan tonlu dolgu + parlak kenar + onay işareti, AA okunur etiket; dokunma
  /// hedefi >= 48 dp). Anahtar `chip_filter_<DURUM>` korunur.
  Widget _filterChip(String value, String label) {
    return AppChip(
      key: Key('chip_filter_$value'),
      label: label,
      selected: _statusFilter == value,
      onTap: () => _onFilterChanged(value),
    );
  }

  /// Yükleniyor / hata / boş durum gövdesi; `null` ise kartlar gösterilir.
  Widget? _stateBody(BuildContext context) {
    if (_loading && _items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Semantics(
          label: 'Envanter yükleniyor',
          liveRegion: true,
          child: const ServiceListSkeleton(key: Key('inventory_loading'), count: 4, lines: 3),
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
        child: ServiceEmptyState(
          key: const Key('inventory_error'),
          icon: Icons.error_outline_rounded,
          family: AppFamilies.rose,
          size: OrbSize.xl,
          glow: true,
          title: 'Envanter Yüklenemedi',
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
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: ServiceEmptyState(
          key: const Key('inventory_empty'),
          icon: Icons.inventory_2_rounded,
          family: AppFeature.inventory.accentFamily,
          size: OrbSize.xl,
          glow: true,
          title: 'Envanterde Cihaz Bulunmuyor',
          message: 'Masaüstü servis yazılımından "Karekod Üret & Etiket Bas" sekmesiyle cihaza etiket basıp '
              'kaydettiğinizde burada tüm detaylarıyla listelenecektir.',
          action: OutlinedButton.icon(
            onPressed: () => _load(reset: true),
            icon: Icon(Icons.refresh_rounded, size: accentIconSize(context, base: 18)),
            label: const Text('Yenile'),
            style: accentOutlinedButtonStyle(context, AppFeature.inventory.accentFamily, minimumSize: const Size(64, AppTouch.minTarget)),
          ),
        ),
      );
    }
    return null;
  }

  Widget _list(BuildContext context, bool manage) {
    final stateBody = _stateBody(context);
    // Yenileme/ek sayfa hatası varsa listenin üstünde uyarı gösterilir (bayat liste sessiz kalmaz).
    final header = <Widget>[
      _statsHeader(context),
      _searchAndFilters(context),
      if (stateBody == null && _error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: ServiceStaleBanner(
            key: const Key('inventory_stale'),
            message: 'Liste güncellenemedi (eski veriler gösteriliyor): $_error',
            onRetry: () => _load(reset: true),
          ),
        ),
    ];
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 80),
      itemCount: header.length + (stateBody != null ? 1 : _items.length + 1),
      itemBuilder: (context, index) {
        if (index < header.length) return header[index];
        if (stateBody != null) return stateBody;
        final i = index - header.length;
        // Filtre çipleri ekran kenarına kadar kayabilsin diye liste yatay dolgusuz; kartlar kendi 16 dp'lerini alır.
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: i < _items.length ? _card(context, _items[i], manage) : _footer(context),
        );
      },
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
          style: accentOutlinedButtonStyle(context, AppFeature.inventory.accentFamily),
        ),
      );
    }
    return const SizedBox(height: 24);
  }

  // ---------------------------------------------------------------------------
  // Kart
  // ---------------------------------------------------------------------------

  /// Durum hapı metni: başlık harfiyle (büyük harf değil; yönetim/aboneler ekranlarıyla aynı rozet dili). `statusLabel`
  /// modelde BÜYÜK HARF kalır (başka yerler kullanır); Türkçe i/İ dönüşümü tuzağına girmemek için açık eşleme.
  static String _statusText(InventoryDeviceModel d) {
    if (d.isInStock) return 'Stokta';
    if (d.isClaimed) return d.status.toUpperCase() == 'INSTALLED' ? 'Montajlandı' : 'Devrede';
    if (d.isSuspended) return 'Askıda';
    if (d.isRevoked) return 'İptal';
    return d.statusLabel;
  }

  Widget _card(BuildContext context, InventoryDeviceModel device, bool manage) {
    final Color statusColor;
    if (device.isInStock) {
      statusColor = AppTheme.accentGreen;
    } else if (device.isClaimed) {
      statusColor = AppTheme.accentCyan;
    } else if (device.isSuspended) {
      statusColor = AppTheme.accentAmber;
    } else {
      statusColor = AppTheme.accentRed;
    }
    // Satır başına `DateFormat` kurmak yerine hafif biçimleyici (PF-25); çıktı `dd.MM.yyyy HH:mm` ile aynıdır.
    final dateText = formatLocalDateTime(device.createdAt);
    final busy = _busyDevices.contains(device.deviceUuid);
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    final home = device.claimedHomeName;
    final email = device.claimedUserEmail;
    // "Sahipli: Daire 5 (Sahipsiz)" çelişkisi: e-posta yoksa parantez hiç yazılmaz.
    final ownerText = 'Sahipli: ${home ?? 'Bilinmeyen Daire'}${email == null ? '' : ' ($email)'}';

    return ServiceCard(
      key: Key('card_inventory_${device.deviceUuid}'),
      accent: device.isSuspended ? AppTheme.accentAmber : null,
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Başlık: seri no hapı (nötr slate: amber uyarı/askı anlamına ayrılmıştır) ... durum hapı. Model adı AŞAĞIDA tam
          // genişlikte (eskiden iki hapın arasında sıkışıp "ESP32-S3-POE-ETH-8DI…" diye kesiliyordu; kesim noktası kartlara göre
          // değişiyordu).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ServicePillShell(
                color: AppFamilies.slate.base,
                animate: false,
                child: Text(
                  device.formattedSerial,
                  style: TextStyle(
                    fontSize: AppText.badge,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    height: 1.2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: SetupColors.readable(context, AppFamilies.slate.base),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: ServiceStatusPill(label: _statusText(device), color: statusColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            device.model.isEmpty ? 'Model bilgisi yok' : device.model,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppText.cardTitle, fontWeight: FontWeight.w700, color: primary),
          ),
          Divider(color: AppTheme.getCardBorder(context), height: 18),
          _copyRow(context, Icons.fingerprint, 'Cihaz UUID', device.deviceUuid, AppFamilies.sky),
          _copyRow(context, Icons.memory, 'MAC Adresi', device.macAddress, AppFamilies.cyan),
          const SizedBox(height: 4),
          // Parti No / Kayıt Tarihi: sığıyorsa yan yana, sığmıyorsa (büyük yazı) alt alta (eskiden "24.09.2026 13…" kesiliyordu).
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _infoItem(context, Icons.tag, 'Parti No', device.batchNo.isEmpty ? '-' : device.batchNo),
              _infoItem(context, Icons.calendar_today_outlined, 'Kayıt Tarihi', dateText),
            ],
          ),
          if (home != null || email != null) ...[
            const SizedBox(height: 10),
            ServiceTintBox(
              color: AppTheme.accentCyan,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.home_work_rounded, color: AppTheme.readableAccent(context, AppTheme.accentCyan), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ownerText,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: AppText.caption, height: 1.3, color: muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Eylemler eşit genişlikte iki sütun; çerçeve + metin + simge AYNI aileden ve AA (ham amber/yeşil metin açık temada
          // ≈ 2:1'di). Yerel şekil/renk/yazı stili YOK: tema hapı, etiket tipografisi temadan (ailesiz textStyle yazı tipini
          // platforma düşürüyordu).
          ServiceActionGrid(
            // Etiketler uzundur ("Etiketi Yeniden Üret", "Envanterden Sil"): telefon genişliğinde tek sütun (yarım genişlikte
            // "Envanter / den Sil" diye sözcük ortasından kırılıyordu); geniş ekranda iki sütun (ızgara eşiği 156 dp).
            children: [
              // "Karekod Gör" İKİNCİL (çerçeveli cyan): eskiden her kartta gradyanlı birincil hap'ti (3-4 özdeş gradyan CTA: sayfada
              // odak noktası yoktu). Bu sayfada gradyan birincil eylem yok; kart eylemleri çerçevelidir.
              OutlinedButton.icon(
                key: Key('btn_qr_${device.deviceUuid}'),
                onPressed: () => _showQrDialog(device),
                icon: Icon(Icons.qr_code_rounded, size: accentIconSize(context, base: 18)),
                label: const Text('Karekod Gör', textAlign: TextAlign.center),
                style: accentOutlinedButtonStyle(context, AppFeature.inventory.accentFamily, minimumSize: const Size(64, AppTouch.minTarget)),
              ),
              if (manage && canSuspend(device))
                OutlinedButton.icon(
                  key: Key('btn_suspend_${device.deviceUuid}'),
                  onPressed: busy ? null : () => _changeStatus(device, 'SUSPENDED'),
                  icon: Icon(Icons.pause_rounded, size: accentIconSize(context, base: 18)),
                  label: const Text('Askıya Al', textAlign: TextAlign.center),
                  style: accentOutlinedButtonStyle(context, AppFamilies.amber),
                ),
              if (manage && canRestore(device))
                OutlinedButton.icon(
                  key: Key('btn_restore_${device.deviceUuid}'),
                  onPressed: busy ? null : () => _changeStatus(device, 'IN_STOCK'),
                  icon: Icon(Icons.play_arrow_rounded, size: accentIconSize(context, base: 18)),
                  label: const Text('Stoğa Al', textAlign: TextAlign.center),
                  style: accentOutlinedButtonStyle(context, AppFamilies.emerald),
                ),
              if (manage && canReissue(device))
                OutlinedButton.icon(
                  key: Key('btn_reissue_label_${device.deviceUuid}'),
                  onPressed: busy ? null : () => _reissueLabel(device),
                  icon: Icon(Icons.print_rounded, size: accentIconSize(context, base: 18)),
                  label: const Text('Etiketi Yeniden Üret', textAlign: TextAlign.center),
                  style: accentOutlinedButtonStyle(context, AppFamilies.sky),
                ),
              if (manage && canDelete(device))
                OutlinedButton.icon(
                  key: Key('btn_delete_${device.deviceUuid}'),
                  onPressed: busy ? null : () => _confirmDelete(device),
                  icon: Icon(Icons.delete_outline_rounded, size: accentIconSize(context, base: 18)),
                  label: const Text('Envanterden Sil', textAlign: TextAlign.center),
                  style: accentOutlinedButtonStyle(context, AppFamilies.rose),
                ),
            ],
          ),
          if (manage && device.isClaimed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Devredeki cihaz askıya alınamaz veya silinemez. Daire değişikliği için acil sıfırlama kullanın.',
                key: Key('note_claimed_${device.deviceUuid}'),
                style: TextStyle(fontSize: AppText.badge, color: muted),
              ),
            ),
        ],
      ),
    );
  }

  /// Kopyalanabilir değer satırı (UUID / MAC): tüm satır dokunma hedefidir (≥ 48 dp); etiket üstte, değer ALTTA tam genişlikte
  /// ve tek satır (sığmazsa küçülür): kimlik tireden bölünüp iki satıra yayılmaz.
  Widget _copyRow(BuildContext context, IconData icon, String label, String value, AccentFamily family) {
    return InkWell(
      onTap: () => _copy(label, value),
      borderRadius: BorderRadius.circular(AppRadius.r12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.readableFamily(context, family), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: TextStyle(fontSize: AppText.badge, color: AppTheme.getTextMuted(context))),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        value,
                        maxLines: 1,
                        softWrap: false,
                        style: SetupText.mono(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.getTextPrimary(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.copy_rounded, color: AppTheme.getTextMuted(context), size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoItem(BuildContext context, IconData icon, String label, String value) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Simge 18 dp + 10 dp boşluk: UUID/MAC satırlarıyla (_copyRow) AYNI metin sütunu (eskiden 16 + 6: metin 6 dp solda
          // başlıyor, aynı kartta iki farklı sol kenar çıkıyordu).
          Icon(icon, color: AppTheme.getTextMuted(context), size: 18),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: AppText.badge, color: AppTheme.getTextMuted(context))),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: AppTheme.getTextPrimary(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Eylemler
  // ---------------------------------------------------------------------------

  void _snack(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), backgroundColor: color, behavior: SnackBarBehavior.floating));
  }

  Future<void> _copy(String label, String value) async {
    final clock = context.read<AutomationState>().clock;
    await SecretClipboard.copy(value, clock: clock);
    _snack('$label panoya kopyalandı (45 sn sonra silinir).');
  }

  Future<void> _changeStatus(InventoryDeviceModel device, String next) async {
    final suspending = next == 'SUSPENDED';
    final bool confirm;
    if (!suspending && device.isRevoked) {
      // İptal edilmiş (arıza / iade / güvenlik) cihazı stoğa geri almak, askıdakini geri almaktan çok daha
      // risklidir: tekrar saha kurulumuna açılır. Basit onay yetmez, cihaz kimliği yazılarak onaylanır.
      confirm = await ConfirmDestructiveDialog.show(
        context,
        title: 'İptal edilmiş cihaz stoğa alınsın mı?',
        message: '${device.deviceUuid} cihazı arıza, iade ya da güvenlik gerekçesiyle İPTAL EDİLMİŞTİ. Stoğa '
            'alınırsa yeniden saha kurulumuna açılır. Devam etmeden önce iptal gerekçesini kontrol edin.',
        confirmPhrase: device.deviceUuid,
        confirmLabel: 'Evet, Stoğa Al',
      );
    } else {
      confirm = await showAppDialog<bool>(
            context,
            builder: (ctx) => AlertDialog(
              title: Text(suspending ? 'Cihaz askıya alınsın mı?' : 'Cihaz stoğa alınsın mı?'),
              content: Text(
                suspending
                    ? '${device.deviceUuid} cihazı askıya alınacak; eşleştirme ve yetkilendirme durdurulacak.'
                    : '${device.deviceUuid} cihazı tekrar stoğa alınacak ve saha kurulumuna açılacak.',
              ),
              actions: [
                TextButton(
                  key: const Key('btn_status_cancel'),
                  style: AppTheme.quietTextButtonStyle(ctx),
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Vazgeç'),
                ),
                ElevatedButton(
                  key: const Key('btn_status_confirm'),
                  onPressed: () => Navigator.pop(ctx, true),
                  // Anlamsal renk ortak ton yüzeyiyle (yerel `backgroundColor` kırpılmış yüzeyin altında gökmavisi gölge çıkarıyordu).
                  style: accentButtonStyle(suspending ? AppFamilies.amber : AppFamilies.emerald),
                  child: Text(suspending ? 'Askıya Al' : 'Stoğa Al'),
                ),
              ],
            ),
          ) ??
          false;
    }
    if (!confirm || !mounted) return;
    final state = context.read<AutomationState>();
    setState(() => _busyDevices.add(device.deviceUuid));
    try {
      await state.updateInventoryStatus(device.deviceUuid, next);
      if (!mounted) return;
      setState(() {
        _items = <InventoryDeviceModel>[
          for (final d in _items) d.deviceUuid == device.deviceUuid ? d.copyWith(status: next) : d,
        ];
      });
      _snack('${device.deviceUuid} durumu güncellendi: ${suspending ? 'Askıda' : 'Stokta'}.');
      unawaited(_load(reset: true));
    } catch (e) {
      _snack(friendlyError(e), color: AppTheme.filledAccent(AppTheme.accentRed));
    } finally {
      if (mounted) setState(() => _busyDevices.remove(device.deviceUuid));
    }
  }

  Future<void> _confirmDelete(InventoryDeviceModel device) async {
    final ok = await ConfirmDestructiveDialog.show(
      context,
      title: 'Cihaz envanterden silinsin mi?',
      message: '${device.deviceUuid} (${device.formattedSerial}) envanterden tamamen silinecek. Bu işlem geri alınamaz.',
      confirmPhrase: device.deviceUuid,
      confirmLabel: 'Evet, Sil',
    );
    if (!ok || !mounted) return;
    final state = context.read<AutomationState>();
    setState(() => _busyDevices.add(device.deviceUuid));
    try {
      await state.deleteDeviceFromInventory(device.deviceUuid);
      if (!mounted) return;
      setState(() {
        _items = _items.where((d) => d.deviceUuid != device.deviceUuid).toList();
        _total = _total == null ? null : (_total! > 0 ? _total! - 1 : 0);
      });
      _snack('${device.deviceUuid} envanterden silindi.');
      unawaited(_load(reset: true));
    } catch (e) {
      _snack(friendlyError(e), color: AppTheme.filledAccent(AppTheme.accentRed));
    } finally {
      if (mounted) setState(() => _busyDevices.remove(device.deviceUuid));
    }
  }

  Future<void> _reissueLabel(InventoryDeviceModel device) async {
    final ok = await ConfirmDestructiveDialog.show(
      context,
      title: 'Etiket yeniden üretilsin mi?',
      message: '${device.deviceUuid} için yeni kurulum PIN\'i ve yerel anahtar üretilecek. ESKİ ETİKET GEÇERSİZ olur; '
          'yeni bilgiler yalnızca bir kez gösterilir.',
      confirmPhrase: device.deviceUuid,
      confirmLabel: 'Yeniden Üret',
    );
    if (!ok || !mounted || _reissuing) return;
    final state = context.read<AutomationState>();
    // Yeni PIN ve anahtar yalnızca BU yanıtta gelir (eski etiket sunucuda zaten geçersiz): istek sürerken sayfadan
    // çıkılırsa değerler hiç gösterilmeden kaybolurdu. Bu yüzden istek bitene kadar geri dönüş engellenir
    // ([PopScope]); yine de sayfa başka bir yolla kapanırsa (oturum bitişi ...) diyalog kök gezginde gösterilir.
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    setState(() {
      _busyDevices.add(device.deviceUuid);
      _reissuing = true;
      _reissueWaiting = true;
    });
    try {
      final Map<String, dynamic> res;
      try {
        res = await state.cloudApi.reissueInventoryLabel(device.deviceUuid);
      } finally {
        // Yanıt (ya da hata) geldi: ilerleme göstergesi kalkar. Sayfadan çıkma kilidi ([_reissuing]) sonuç penceresi
        // kapanana kadar sürer; gösterge ise yalnızca istek sürerken döner.
        if (mounted) setState(() => _reissueWaiting = false);
      }
      final result = LabelReissueResult.fromJson(res);
      if (result.isEmpty) {
        _snack('Sunucu yeni etiket bilgisini vermedi. Lütfen tekrar deneyin.', color: AppTheme.filledAccent(AppTheme.accentRed));
      } else if (mounted) {
        await LabelReissueDialog.show(context, deviceUuid: device.deviceUuid, result: result);
      } else if (rootContext.mounted) {
        await LabelReissueDialog.show(rootContext, deviceUuid: device.deviceUuid, result: result);
      }
    } catch (e) {
      _snack(friendlyError(e), color: AppTheme.filledAccent(AppTheme.accentRed));
    } finally {
      if (mounted) {
        setState(() {
          _busyDevices.remove(device.deviceUuid);
          _reissuing = false;
          _reissueWaiting = false;
        });
      }
    }
  }

  void _showQrDialog(InventoryDeviceModel device) {
    showAppDialog<void>(
      context,
      builder: (ctx) {
        return Dialog(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.qr_code_2_rounded, color: AppTheme.readableFamily(context, AppFeature.inventory.accentFamily), size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Cihaz Karekodu (${device.formattedSerial})',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Kapat',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: QrImageView(data: device.qrClaimUrl, version: QrVersions.auto, size: 200, backgroundColor: Colors.white),
                ),
                const SizedBox(height: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    device.deviceUuid,
                    maxLines: 1,
                    softWrap: false,
                    style: SetupText.mono(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.readableFamily(context, AppFeature.inventory.accentFamily),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'MAC: ${device.macAddress} • ${device.model}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppText.badge, color: AppTheme.getTextMuted(context)),
                ),
                const SizedBox(height: 8),
                Text(
                  device.qrClaimUrl.toLowerCase().contains('pin=')
                      ? 'DİKKAT: Bu karekod kurulum PIN\'ini içerir. Ekranı başkalarına göstermeyin, bağlantıyı paylaşmayın.'
                      : 'Bu bağlantı PIN içermez (PIN yalnızca fiziksel etiketteki karekod ve yazıdadır).',
                  key: const Key('qr_pin_note'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppText.badge, color: AppTheme.getTextMuted(context)),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('btn_copy_qr_link'),
                  onPressed: () async {
                    final clock = context.read<AutomationState>().clock;
                    final messenger = ScaffoldMessenger.of(context);
                    final navigator = Navigator.of(ctx);
                    await SecretClipboard.copy(device.qrClaimUrl, clock: clock);
                    navigator.pop();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Karekod bağlantısı panoya kopyalandı (45 sn sonra silinir).')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Karekod Bağlantısını Kopyala', textAlign: TextAlign.center),
                  style: accentOutlinedButtonStyle(context, AppFeature.inventory.accentFamily, minimumSize: const Size(64, AppTouch.minTarget)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
