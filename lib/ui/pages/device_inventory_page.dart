import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../models/cloud_models.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../widgets/circuit_background.dart';

/// AHBU Akıllı Ev & Bina Otomasyonu
/// Cihaz Envanteri ve Karekod Yönetim Paneli (Süper Yönetici & Yetkili Servis)
class DeviceInventoryPage extends StatefulWidget {
  final bool autoLoad;
  const DeviceInventoryPage({super.key, this.autoLoad = true});

  @override
  State<DeviceInventoryPage> createState() => _DeviceInventoryPageState();
}

class _DeviceInventoryPageState extends State<DeviceInventoryPage> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedStatusFilter = 'ALL';

  @override
  void initState() {
    super.initState();
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadInventory();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInventory() async {
    final state = Provider.of<AutomationState>(context, listen: false);
    debugPrint('[DeviceInventoryPage] _loadInventory filter: $_selectedStatusFilter, search: ${_searchController.text}');
    await state.fetchInventory(
      status: _selectedStatusFilter == 'ALL' ? null : _selectedStatusFilter,
      search: _searchController.text.trim().isEmpty ? null : _searchController.text.trim(),
    );
    debugPrint('[DeviceInventoryPage] _loadInventory finished, items: ${state.inventoryDevices.length}, stats: ${state.inventoryStats}, error: ${state.inventoryError}');
  }

  void _onFilterChanged(String status) {
    setState(() {
      _selectedStatusFilter = status;
    });
    _loadInventory();
  }

  void _onSearchSubmitted(String _) {
    _loadInventory();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AutomationState>(context);
    final isSuper = state.isSuperUser;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0B1120) : const Color(0xFFF1F5F9),
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Cihaz Envanteri',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            Text(
              'Karekodlar, Seri No & Donanım Takibi',
              style: TextStyle(fontSize: 11, color: AppTheme.accentCyan),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            tooltip: 'Yenile',
            onPressed: _loadInventory,
          ),
        ],
      ),
      body: CircuitBackground(
        child: RefreshIndicator(
          onRefresh: _loadInventory,
          color: AppTheme.accentCyan,
          child: Column(
            children: [
              // 1. Özet Sayaçlar (Metrics Overview)
              _buildStatsHeader(state.inventoryStats),

              // 2. Arama & Filtreleme Çubuğu
              _buildSearchAndFilterBar(),

              // 3. Envanter Cihaz Listesi
              Expanded(
                child: _buildDeviceList(state, isSuper),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // 1. İSTATİSTİK ÖZET SAYAÇLARI
  // ===========================================================================
  Widget _buildStatsHeader(Map<String, int> stats) {
    final total = stats['total'] ?? 0;
    final inStock = stats['in_stock'] ?? 0;
    final claimed = stats['claimed'] ?? 0;
    final suspended = stats['suspended'] ?? 0;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth = (constraints.maxWidth - 24) / 4;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStatItem('Toplam', '$total', AppTheme.primaryBlueLight, itemWidth),
              _buildStatItem('Stokta', '$inStock', AppTheme.accentGreen, itemWidth),
              _buildStatItem('Devrede', '$claimed', AppTheme.accentCyan, itemWidth),
              _buildStatItem('Askıda', '$suspended', AppTheme.accentAmber, itemWidth),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color, double width) {
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 2. ARAMA VE FİLTRELEME ÇUBUĞU
  // ===========================================================================
  Widget _buildSearchAndFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          // Arama Girişi
          TextField(
            controller: _searchController,
            onSubmitted: _onSearchSubmitted,
            style: const TextStyle(color: Colors.white, fontSize: 13.5),
            decoration: InputDecoration(
              hintText: 'UUID, MAC, Seri No veya Daire Ara...',
              hintStyle: const TextStyle(color: Colors.white54, fontSize: 13),
              prefixIcon: const Icon(Icons.search, color: AppTheme.accentCyan, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white70, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        _loadInventory();
                      },
                    )
                  : IconButton(
                      icon: const Icon(Icons.arrow_forward, color: AppTheme.accentCyan, size: 18),
                      onPressed: () => _onSearchSubmitted(_searchController.text),
                    ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              filled: true,
              fillColor: AppTheme.cardDark,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.cardBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.cardBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.accentCyan, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Filtre Butonları (SingleChildScrollView ile taşma engelli)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip('ALL', 'Tümü'),
                const SizedBox(width: 8),
                _buildFilterChip('IN_STOCK', 'Stokta Hazır'),
                const SizedBox(width: 8),
                _buildFilterChip('CLAIMED', 'Devrede / Aktif'),
                const SizedBox(width: 8),
                _buildFilterChip('SUSPENDED', 'Askıya Alınan'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final isSelected = _selectedStatusFilter == value;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Colors.black : Colors.white70,
        ),
      ),
      selected: isSelected,
      onSelected: (_) => _onFilterChanged(value),
      selectedColor: AppTheme.accentCyan,
      backgroundColor: AppTheme.cardDark,
      side: BorderSide(
        color: isSelected ? AppTheme.accentCyan : AppTheme.cardBorder,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

  // ===========================================================================
  // 3. CİHAZ LİSTESİ & KARTLARI
  // ===========================================================================
  Widget _buildDeviceList(AutomationState state, bool isSuper) {
    if (state.inventoryLoading && state.inventoryDevices.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.accentCyan),
      );
    }

    if (state.inventoryError != null && state.inventoryDevices.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppTheme.accentRed, size: 48),
              const SizedBox(height: 12),
              Text(
                'Envanter Yüklenemedi',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                state.inventoryError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadInventory,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Tekrar Dene'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentCyan),
              ),
            ],
          ),
        ),
      );
    }

    final devices = state.inventoryDevices;
    if (devices.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.accentCyan.withValues(alpha: 0.1),
                ),
                child: const Icon(Icons.inventory_2_outlined, color: AppTheme.accentCyan, size: 54),
              ),
              const SizedBox(height: 16),
              const Text(
                'Envanterde Cihaz Bulunmuyor',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Masaüstü servis yazılımından "Karekod Üret & Etiket Bas" sekmesiyle cihaza etiket basıp kaydettiğinizde burada tüm detaylarıyla listelenecektir.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 12.5),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _loadInventory,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yenile'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accentCyan,
                  side: const BorderSide(color: AppTheme.accentCyan),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return _buildDeviceCard(device, isSuper);
      },
    );
  }

  Widget _buildDeviceCard(InventoryDeviceModel device, bool isSuper) {
    Color statusColor;
    IconData statusIcon;

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

    final dateFormatted = DateFormat('dd.MM.yyyy HH:mm').format(device.createdAt.toLocal());

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: device.isSuspended
              ? AppTheme.accentAmber.withValues(alpha: 0.5)
              : AppTheme.cardBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Üst Satır: Sıra No, Model & Durum Rozeti (Taşma korumalı)
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
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.accentAmber,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          device.model,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                          color: statusColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(color: AppTheme.cardBorder, height: 18),

            // UUID Bilgisi (Kopyalanabilir)
            _buildCopyableRow(
              icon: Icons.fingerprint,
              label: 'Cihaz UUID',
              value: device.deviceUuid,
              color: AppTheme.primaryBlueLight,
            ),
            const SizedBox(height: 8),

            // MAC Adresi (Kopyalanabilir)
            _buildCopyableRow(
              icon: Icons.memory,
              label: 'MAC Adresi',
              value: device.macAddress,
              color: AppTheme.accentCyan,
            ),
            const SizedBox(height: 8),

            // Parti No & Tarih
            Row(
              children: [
                Expanded(
                  child: _buildInfoItem(
                    icon: Icons.tag,
                    label: 'Parti No',
                    value: device.batchNo,
                  ),
                ),
                Expanded(
                  child: _buildInfoItem(
                    icon: Icons.calendar_today_outlined,
                    label: 'Kayıt Tarihi',
                    value: dateFormatted,
                  ),
                ),
              ],
            ),

            // Sahiplenme (Claim) Bilgisi varsa
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
                        'Sahipli: ${device.claimedHomeName ?? "Bilinmeyen Daire"} (${device.claimedUserEmail ?? "Sahipsiz"})',
                        style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // Eylem Butonları (Karekod Gör, Askıya Al / Aktif Et, Sil - Wrap ile esnek)
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.end,
                children: [
                  // Karekod Göster Butonu
                  ElevatedButton.icon(
                    onPressed: () => _showQrDialog(device),
                    icon: const Icon(Icons.qr_code, size: 16),
                    label: const Text('Karekod Gör'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),

                  // Askıya Al / Aktif Et Butonu
                  if (isSuper)
                    OutlinedButton.icon(
                      onPressed: () => _toggleDeviceStatus(device),
                      icon: Icon(
                        device.isSuspended ? Icons.play_arrow_rounded : Icons.pause_rounded,
                        size: 16,
                        color: device.isSuspended ? AppTheme.accentGreen : AppTheme.accentAmber,
                      ),
                      label: Text(
                        device.isSuspended ? 'Aktif Et' : 'Askıya Al',
                        style: TextStyle(
                          fontSize: 12,
                          color: device.isSuspended ? AppTheme.accentGreen : AppTheme.accentAmber,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: device.isSuspended ? AppTheme.accentGreen : AppTheme.accentAmber,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),

                  // Sil Butonu
                  if (isSuper)
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.accentRed, size: 20),
                      tooltip: 'Envanterden Sil',
                      onPressed: () => _confirmDeleteDevice(device),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCopyableRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$label kopyalandı: $value'),
            duration: const Duration(seconds: 2),
            backgroundColor: AppTheme.cardDark,
          ),
        );
      },
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 8),
            Text(
              '$label: ',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.copy_rounded, color: Colors.white38, size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.white38, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
              ),
              Text(
                value,
                style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // 4. KAREKOD (QR) GÖRÜNTÜLEME DİYALOĞU
  // ===========================================================================
  void _showQrDialog(InventoryDeviceModel device) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: AppTheme.cardDark,
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
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(4),
                      icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // QR Kod Çerçevesi (Beyaz zemin termal etiket gibi net)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: device.qrClaimUrl,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),

                // Cihaz Detay Bilgisi
                Text(
                  device.deviceUuid,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accentCyan,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'MAC: ${device.macAddress} • ${device.model}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                // Bağlantıyı Kopyala Butonu
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: device.qrClaimUrl));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Karekod bağlantısı panoya kopyalandı.'),
                        backgroundColor: AppTheme.cardDark,
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Karekod Bağlantısını Kopyala'),
                  style: OutlinedButton.styleFrom(
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

  // ===========================================================================
  // 5. DURUM GÜNCELLEME (ASKIYA AL / AKTİF ET)
  // ===========================================================================
  Future<void> _toggleDeviceStatus(InventoryDeviceModel device) async {
    final newStatus = device.isSuspended ? 'IN_STOCK' : 'SUSPENDED';
    final actionLabel = device.isSuspended ? 'Aktif Etmek' : 'Askıya Almak';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: Text('$actionLabel İstiyor musunuz?'),
        content: Text(
          device.isSuspended
              ? '${device.deviceUuid} cihazı tekrar stoğa alınacak ve saha aktivasyonuna açılacaktır.'
              : '${device.deviceUuid} cihazı askıya alınacak ve eşleştirme/yetkilendirme durdurulacaktır.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: device.isSuspended ? AppTheme.accentGreen : AppTheme.accentAmber,
            ),
            child: Text(device.isSuspended ? 'Aktif Et' : 'Askıya Al'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final state = Provider.of<AutomationState>(context, listen: false);
    try {
      await state.updateInventoryStatus(device.deviceUuid, newStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${device.deviceUuid} durumu güncellendi: $newStatus'),
            backgroundColor: AppTheme.cardDark,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hata: $e'),
            backgroundColor: AppTheme.accentRed,
          ),
        );
      }
    }
  }

  // ===========================================================================
  // 6. CİHAZ SİLME ONAYI
  // ===========================================================================
  Future<void> _confirmDeleteDevice(InventoryDeviceModel device) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardDark,
        title: const Text('Cihazı Silmek İstiyor musunuz?'),
        content: Text(
          '${device.deviceUuid} (${device.formattedSerial}) cihazı envanterden tamamen silinecektir. Bu işlem geri alınamaz.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed),
            child: const Text('Evet, Sil'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final state = Provider.of<AutomationState>(context, listen: false);
    try {
      await state.deleteDeviceFromInventory(device.deviceUuid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${device.deviceUuid} envanterden silindi.'),
            backgroundColor: AppTheme.cardDark,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Silme hatası: $e'),
            backgroundColor: AppTheme.accentRed,
          ),
        );
      }
    }
  }
}
