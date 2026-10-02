import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/cloud_models.dart';
import '../../models/json_utils.dart';
import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../common/confirm_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/circuit_background.dart';
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

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final state = context.read<AutomationState>();
    _items = state.inventoryDevices;
    _stats = state.inventoryStats;
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
    final state = context.watch<AutomationState>();
    final manage = state.capabilities.canManageInventory;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: !_reissuing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _reissuing) {
          _snack('Yeni etiket bilgileri alınıyor. Bu bilgiler yalnızca bir kez gösterilir: işlem bitene kadar sayfadan çıkılamaz.');
        }
      },
      child: _scaffold(context, manage, isDark),
    );
  }

  Widget _scaffold(BuildContext context, bool manage, bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0B1120) : const Color(0xFFF1F5F9),
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Cihaz Envanteri', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text('Karekodlar, Seri No & Donanım Takibi', style: TextStyle(fontSize: 11, color: AppTheme.accentCyan)),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('btn_refresh'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: _loading ? null : () => _load(reset: true),
          ),
        ],
      ),
      body: CircuitBackground(
        child: RefreshIndicator(
          onRefresh: () => _load(reset: true),
          color: AppTheme.accentCyan,
          child: Column(
            children: [
              _statsHeader(context),
              _searchAndFilters(context),
              Expanded(child: _list(context, manage)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statsHeader(BuildContext context) {
    final total = _stats['total'] ?? _items.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.getCardBorder(context)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _statItem(context, 'Toplam', '$total', AppTheme.primaryBlueLight),
          _statItem(context, 'Stokta', '${_stats['in_stock'] ?? 0}', AppTheme.accentGreen),
          _statItem(context, 'Devrede', '${_stats['claimed'] ?? 0}', AppTheme.accentCyan),
          _statItem(context, 'Askıda', '${_stats['suspended'] ?? 0}', AppTheme.accentAmber),
        ],
      ),
    );
  }

  Widget _statItem(BuildContext context, String label, String value, Color color) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
          ),
        ],
      ),
    );
  }

  Widget _searchAndFilters(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          TextField(
            key: const Key('field_search'),
            controller: _search,
            onChanged: _onSearchChanged,
            style: TextStyle(color: primary, fontSize: 13.5),
            decoration: InputDecoration(
              hintText: 'UUID, MAC, Seri No veya Daire Ara...',
              hintStyle: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13),
              prefixIcon: const Icon(Icons.search, color: AppTheme.accentCyan, size: 20),
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
              filled: true,
              fillColor: AppTheme.getCardColor(context),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.getCardBorder(context)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
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
        ],
      ),
    );
  }

  Widget _filterChip(String value, String label) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      key: Key('chip_filter_$value'),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: selected ? Colors.black : AppTheme.getTextPrimary(context),
        ),
      ),
      selected: selected,
      onSelected: (_) => _onFilterChanged(value),
      selectedColor: AppTheme.accentCyan,
      backgroundColor: AppTheme.getCardColor(context),
      side: BorderSide(color: selected ? AppTheme.accentCyan : AppTheme.getCardBorder(context)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }

  Widget _list(BuildContext context, bool manage) {
    if (_loading && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator(key: Key('inventory_loading'), color: AppTheme.accentCyan)),
        ],
      );
    }
    if (_error != null && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 40),
          Column(
            key: const Key('inventory_error'),
            children: [
              const Icon(Icons.error_outline_rounded, color: AppTheme.accentRed, size: 48),
              const SizedBox(height: 12),
              Text(
                'Envanter Yüklenemedi',
                style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                key: const Key('btn_retry'),
                onPressed: () => _load(reset: true),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Tekrar Dene'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
              ),
            ],
          ),
        ],
      );
    }
    if (_loaded && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        children: [
          Column(
            key: const Key('inventory_empty'),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.accentCyan.withValues(alpha: 0.1)),
                child: const Icon(Icons.inventory_2_outlined, color: AppTheme.accentCyan, size: 54),
              ),
              const SizedBox(height: 16),
              Text(
                'Envanterde Cihaz Bulunmuyor',
                style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Masaüstü servis yazılımından "Karekod Üret & Etiket Bas" sekmesiyle cihaza etiket basıp '
                'kaydettiğinizde burada tüm detaylarıyla listelenecektir.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 12.5),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: () => _load(reset: true),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yenile'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accentCyan,
                  side: const BorderSide(color: AppTheme.accentCyan),
                ),
              ),
            ],
          ),
        ],
      );
    }
    final offset = _error != null ? 1 : 0;
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: offset + _items.length + 1,
      itemBuilder: (context, index) {
        if (index < offset) return _staleBanner(context);
        final i = index - offset;
        if (i < _items.length) return _card(context, _items[i], manage);
        return _footer(context);
      },
    );
  }

  Widget _staleBanner(BuildContext context) {
    return Container(
      key: const Key('inventory_stale'),
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
          TextButton(key: const Key('btn_retry'), onPressed: () => _load(reset: true), child: const Text('Tekrar dene')),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    if (_loadingMore) {
      return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
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
    return const SizedBox(height: 24);
  }

  // ---------------------------------------------------------------------------
  // Kart
  // ---------------------------------------------------------------------------

  Widget _card(BuildContext context, InventoryDeviceModel device, bool manage) {
    final Color statusColor;
    final IconData statusIcon;
    if (device.isInStock) {
      statusColor = AppTheme.accentGreen;
      statusIcon = Icons.inventory;
    } else if (device.isClaimed) {
      statusColor = AppTheme.accentCyan;
      statusIcon = Icons.verified;
    } else if (device.isSuspended) {
      statusColor = AppTheme.accentAmber;
      statusIcon = Icons.pause_circle_outline;
    } else {
      statusColor = AppTheme.accentRed;
      statusIcon = Icons.cancel_outlined;
    }
    final dateText = DateFormat('dd.MM.yyyy HH:mm').format(device.createdAt.toLocal());
    final busy = _busyDevices.contains(device.deviceUuid);
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);

    return Container(
      key: Key('card_inventory_${device.deviceUuid}'),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: device.isSuspended ? AppTheme.accentAmber.withValues(alpha: 0.5) : AppTheme.getCardBorder(context),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.accentAmber.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          device.formattedSerial,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: SetupColors.readable(context, AppTheme.accentAmber),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          device.model.isEmpty ? 'Model bilgisi yok' : device.model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: primary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 13),
                      const SizedBox(width: 4),
                      Text(
                        device.statusLabel,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: SetupColors.readable(context, statusColor),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Divider(color: AppTheme.getCardBorder(context), height: 18),
            _copyRow(context, Icons.fingerprint, 'Cihaz UUID', device.deviceUuid, AppTheme.primaryBlueLight),
            const SizedBox(height: 8),
            _copyRow(context, Icons.memory, 'MAC Adresi', device.macAddress, AppTheme.accentCyan),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _infoItem(context, Icons.tag, 'Parti No', device.batchNo.isEmpty ? '-' : device.batchNo)),
                Expanded(child: _infoItem(context, Icons.calendar_today_outlined, 'Kayıt Tarihi', dateText)),
              ],
            ),
            if (device.claimedHomeName != null || device.claimedUserEmail != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.accentCyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.home_work_outlined, color: AppTheme.accentCyan, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Sahipli: ${device.claimedHomeName ?? 'Bilinmeyen Daire'} (${device.claimedUserEmail ?? 'Sahipsiz'})',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: muted),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.end,
                children: [
                  ElevatedButton.icon(
                    key: Key('btn_qr_${device.deviceUuid}'),
                    onPressed: () => _showQrDialog(device),
                    icon: const Icon(Icons.qr_code, size: 16),
                    label: const Text('Karekod Gör'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(48, 44),
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (manage && canSuspend(device))
                    OutlinedButton.icon(
                      key: Key('btn_suspend_${device.deviceUuid}'),
                      onPressed: busy ? null : () => _changeStatus(device, 'SUSPENDED'),
                      icon: const Icon(Icons.pause_rounded, size: 16, color: AppTheme.accentAmber),
                      label: const Text('Askıya Al', style: TextStyle(fontSize: 12, color: AppTheme.accentAmber)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 44),
                        side: const BorderSide(color: AppTheme.accentAmber),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  if (manage && canRestore(device))
                    OutlinedButton.icon(
                      key: Key('btn_restore_${device.deviceUuid}'),
                      onPressed: busy ? null : () => _changeStatus(device, 'IN_STOCK'),
                      icon: const Icon(Icons.play_arrow_rounded, size: 16, color: AppTheme.accentGreen),
                      label: const Text('Stoğa Al', style: TextStyle(fontSize: 12, color: AppTheme.accentGreen)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 44),
                        side: const BorderSide(color: AppTheme.accentGreen),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  if (manage && canReissue(device))
                    OutlinedButton.icon(
                      key: Key('btn_reissue_label_${device.deviceUuid}'),
                      onPressed: busy ? null : () => _reissueLabel(device),
                      icon: const Icon(Icons.print_rounded, size: 16),
                      label: const Text('Etiketi Yeniden Üret', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 44),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  if (manage && canDelete(device))
                    IconButton(
                      key: Key('btn_delete_${device.deviceUuid}'),
                      icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.accentRed, size: 22),
                      tooltip: 'Envanterden Sil',
                      onPressed: busy ? null : () => _confirmDelete(device),
                    ),
                ],
              ),
            ),
            if (manage && device.isClaimed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Devredeki cihaz askıya alınamaz veya silinemez. Daire değişikliği için acil sıfırlama kullanın.',
                  key: Key('note_claimed_${device.deviceUuid}'),
                  style: TextStyle(fontSize: 11.5, color: muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _copyRow(BuildContext context, IconData icon, String label, String value, Color color) {
    return InkWell(
      onTap: () => _copy(label, value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 8),
            Text('$label: ', style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context))),
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  color: SetupColors.readable(context, color),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.copy_rounded, color: AppTheme.getTextMuted(context), size: 14),
          ],
        ),
      ),
    );
  }

  Widget _infoItem(BuildContext context, IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.getTextMuted(context), size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: TextStyle(fontSize: 10.5, color: AppTheme.getTextMuted(context))),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: AppTheme.getTextPrimary(context), fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ],
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
      confirm = await showDialog<bool>(
            context: context,
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
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Vazgeç'),
                ),
                ElevatedButton(
                  key: const Key('btn_status_confirm'),
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(backgroundColor: suspending ? AppTheme.accentAmber : AppTheme.accentGreen),
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
      _snack(friendlyError(e), color: AppTheme.accentRed);
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
      _snack(friendlyError(e), color: AppTheme.accentRed);
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
    });
    try {
      final res = await state.cloudApi.reissueInventoryLabel(device.deviceUuid);
      final result = LabelReissueResult.fromJson(res);
      if (result.isEmpty) {
        _snack('Sunucu yeni etiket bilgisini vermedi. Lütfen tekrar deneyin.', color: AppTheme.accentRed);
      } else if (mounted) {
        await LabelReissueDialog.show(context, deviceUuid: device.deviceUuid, result: result);
      } else if (rootContext.mounted) {
        await LabelReissueDialog.show(rootContext, deviceUuid: device.deviceUuid, result: result);
      }
    } catch (e) {
      _snack(friendlyError(e), color: AppTheme.accentRed);
    } finally {
      if (mounted) {
        setState(() {
          _busyDevices.remove(device.deviceUuid);
          _reissuing = false;
        });
      }
    }
  }

  void _showQrDialog(InventoryDeviceModel device) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: AppTheme.getCardColor(context),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.qr_code_2_rounded, color: AppTheme.accentCyan, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Cihaz Karekodu (${device.formattedSerial})',
                        maxLines: 1,
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
                Text(
                  device.deviceUuid,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.accentCyan),
                ),
                const SizedBox(height: 4),
                Text(
                  'MAC: ${device.macAddress} • ${device.model}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
                ),
                const SizedBox(height: 8),
                Text(
                  device.qrClaimUrl.toLowerCase().contains('pin=')
                      ? 'DİKKAT: Bu karekod kurulum PIN\'ini içerir. Ekranı başkalarına göstermeyin, bağlantıyı paylaşmayın.'
                      : 'Bu bağlantı PIN içermez (PIN yalnızca fiziksel etiketteki karekod ve yazıdadır).',
                  key: const Key('qr_pin_note'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
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
                  label: const Text('Karekod Bağlantısını Kopyala'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    foregroundColor: AppTheme.accentCyan,
                    side: const BorderSide(color: AppTheme.accentCyan),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
