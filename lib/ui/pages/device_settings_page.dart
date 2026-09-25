import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../widgets/user_profile_dialog.dart';
import 'wifi_recovery_dialog.dart';
import 'system_doctor_dialog.dart';
import 'replace_board_dialog.dart';
import 'scheduled_rules_page.dart';

class DeviceSettingsPage extends StatefulWidget {
  const DeviceSettingsPage({super.key});

  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage> {
  late TextEditingController _hostCtrl;
  String? _generatedPin;
  bool _isGeneratingPin = false;

  @override
  void initState() {
    super.initState();
    final currentHost = context.read<AutomationState>().host;
    _hostCtrl = TextEditingController(text: currentHost);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final status = state.status;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_logo.png',
                width: 28,
                height: 28,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Cihaz & Sistem Ayarları',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Donanım & Motor Koruma Bilgilendirme Kartı
            _buildHardwareProtectionNotice(state),
            const SizedBox(height: 16),

            // ADIM 16: Sistem Doktoru Kartı (Herkes Kullanabilir)
            _buildSystemDoctorCard(context),
            const SizedBox(height: 16),

            // ADIM 17: Yazılımsal Çocuk Kilidi (Child Lock)
            _buildChildLockCard(context, state),
            const SizedBox(height: 16),

            // ADIM 17: Gece Huzur Bildirimi (Peace Notification)
            _buildPeaceNotificationCard(context, state),
            const SizedBox(height: 16),

            // ADIM 18: Zamanlı Otomasyon Kuralları
            _buildScheduledRulesCard(context, state),
            const SizedBox(height: 16),

            // ADIM 19: Biyometrik Giriş Güvenliği (Face ID / Parmak İzi)
            _buildBiometricCard(context, state),
            const SizedBox(height: 16),

            // Görünüm & Tema Seçici Kartı (Karanlık / Aydınlık Mod)
            _buildThemeSelectorCard(context, state),
            const SizedBox(height: 16),

            // Aile Üyesi Kısıtlama Uyarısı (Eğer Member ise)
            if (state.isMember) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.lock_outline, color: Colors.amber, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Aile Üyesi Hesabı: Ağ ve pano bağlantı parametrelerini yalnızca Ev Sahibi değiştirebilir.',
                        style: TextStyle(fontSize: 12, color: Colors.amberAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Yetkili İşlemler: Servis PIN'i, Wi-Fi Kurtarma ve Pano Değişimi
            if (!state.isMember) ...[
              if (state.isOwner) ...[
                _buildServicePinGeneratorCard(state),
                const SizedBox(height: 16),
              ],
              _buildWifiRecoveryCard(context),
              const SizedBox(height: 16),
              _buildDisasterRecoveryCard(context),
              const SizedBox(height: 16),
            ],

            // Yerel IP / Ağ Bağlantı Ayarları
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.cardDark,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ESP32-S3 Cihaz IP Adresi',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Cihazın ev modeminizden aldığı yerel IP adresini veya AP modundaki IP\'sini girin.',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _hostCtrl,
                    readOnly: state.isMember,
                    decoration: InputDecoration(
                      hintText: 'Örn: 192.168.1.197 veya 192.168.4.1',
                      prefixIcon: const Icon(Icons.lan_outlined, color: AppTheme.primaryBlue),
                      suffixIcon: state.isMember ? const Icon(Icons.lock, size: 18, color: Colors.amber) : null,
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
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
                        borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 1.5),
                      ),
                    ),
                  ),
                  if (!state.isMember) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildQuickIpChip('192.168.4.1 (AP Varsayılan)'),
                        _buildQuickIpChip('192.168.1.197 (Ev Ağı)'),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: state.isMember
                          ? null
                          : () async {
                              final val = _hostCtrl.text.trim();
                              if (val.isNotEmpty) {
                                await state.setHost(val);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('IP $val olarak güncellendi!'),
                                      backgroundColor: AppTheme.accentGreen,
                                    ),
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(
                        state.isMember ? 'Değişiklik Yetkiniz Yok' : 'Kaydet ve Bağlan',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey.shade800,
                        disabledForegroundColor: Colors.grey.shade500,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Cihaz Telemetrisi
            if (status != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ℹ️ Cihaz Telemetrisi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
                    const SizedBox(height: 10),
                    _buildInfoRow('Cihaz Adı:', status.deviceName),
                    _buildInfoRow('Cihaz AP IP:', status.ip),
                    _buildInfoRow('Ev Wi-Fi (STA):', status.wifiConnected ? '${status.wifiStaSsid} (${status.wifiStaIp})' : 'Bağlı Değil'),
                    _buildInfoRow('Sinyal Gücü:', '${status.wifiStaRssi} dBm'),
                    _buildInfoRow('Kesintisiz Çalışma (Uptime):', '${status.uptimeSec ~/ 3600}s ${(status.uptimeSec % 3600) ~/ 60}d'),
                    _buildInfoRow('Toplam Röle / DI:', '${status.relays.length} Röle / ${status.dis.length} Giriş'),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Uygulama Bilgisi & Kullanıcı Profili
            Center(
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset(
                      'assets/images/app_logo.png',
                      width: 68,
                      height: 68,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'AHBU OTOMASYON',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Akıllı Ev & Bina Otomasyon Sistemleri v1.0.1',
                    style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            if (state.currentUser != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.account_circle_outlined, color: AppTheme.primaryBlueLight, size: 22),
                        SizedBox(width: 8),
                        Text(
                          'Kullanıcı Hesabı',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildInfoRow('Ad Soyad', state.currentUser!.fullName),
                    _buildInfoRow('E-Posta', state.currentUser!.email),
                    _buildInfoRow('Yetki Rolü', state.currentUser!.role.toUpperCase()),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => UserProfileDialog.show(context),
                        icon: const Icon(Icons.manage_accounts_outlined, color: AppTheme.primaryBlueLight, size: 18),
                        label: const Text('Profili Yönet & Oturumu Kapat', style: TextStyle(color: AppTheme.textPrimary)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.cardBorder),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHardwareProtectionNotice(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.3)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.security_outlined, color: AppTheme.primaryBlueLight, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🔒 Donanım & Motor Koruması',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                    color: AppTheme.primaryBlueLight,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Pano klemensleri ve motor çalışma süreleri kilitlidir. Elektrik kesintisi dönüşünde lambalar kapalı kalır, panjurlar hareket etmez. Tam açma/kapamada +2 sn mekanik limit oturması ve self-healing kalibrasyonu devrededir.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServicePinGeneratorCard(AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.accentPurple.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.key, color: AppTheme.accentPurple, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Yetkili Servis İçin Geçici PIN Üret',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Kurulum veya arıza için gelen yetkili servisin panoyu ayarlayabilmesi için 2 saat süreli PIN üretin.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          if (_generatedPin != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.accentGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_outline, color: AppTheme.accentGreen, size: 18),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      _generatedPin!,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 6,
                        color: AppTheme.accentGreen,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                '⏳ Bu PIN 2 saat sonra kendiliğinden geçerliliğini yitirecektir.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isGeneratingPin
                  ? null
                  : () async {
                      setState(() => _isGeneratingPin = true);
                      try {
                        final pin = await state.generateServiceToken();
                        if (!mounted) return;
                        setState(() => _generatedPin = pin);
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Hata: $e'), backgroundColor: AppTheme.accentRed),
                        );
                      } finally {
                        if (mounted) {
                          setState(() => _isGeneratingPin = false);
                        }
                      }
                    },
              icon: _isGeneratingPin
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentPurple),
                    )
                  : const Icon(Icons.vpn_key_outlined, size: 16, color: AppTheme.accentPurple),
              label: Text(
                _generatedPin == null ? '6 Haneli Servis PIN\'i Üret' : 'Yeni PIN Üret',
                style: const TextStyle(color: AppTheme.accentPurple, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.accentPurple),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWifiRecoveryCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.wifi_find_rounded, color: Colors.amber, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Wi-Fi Şifre Değişimi & Kurtarma',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Evinizdeki modem veya Wi-Fi şifresi değiştiyse panoya yeni bilgileri aktarmak için acil kurtarma sihirbazını başlatın.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => WifiRecoveryDialog.show(context),
              icon: const Icon(Icons.settings_ethernet, size: 16, color: Colors.amber),
              label: const Text(
                'Kurtarma Modu Sihirbazını Aç',
                style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.amber),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemDoctorCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.cyanAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.health_and_safety, color: Colors.cyanAccent, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Sistem Doktoru (Teşhis & Analiz)',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Uygulama veya otomasyon panosunda sorun mu yaşıyorsunuz? Bulut, modem/internet ve pano besleme durumunu tek tıkla analiz edin.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => SystemDoctorDialog.show(context),
              icon: const Icon(Icons.medical_services_outlined, size: 16, color: Colors.cyanAccent),
              label: const Text(
                'Sistem Doktorunu Çalıştır',
                style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.cyanAccent),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisasterRecoveryCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.deepPurpleAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.swap_horizontal_circle_outlined, color: Colors.deepPurpleAccent, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Felaket Kurtarma & Pano Değişimi',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Arızalanan veya yıldırım düşen panoyu yenisiyle değiştirdiğinizde, tüm oda isimleri ve ayarları 5 saniyede yeni panoya aktarın.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => ReplaceBoardDialog.show(context),
              icon: const Icon(Icons.settings_backup_restore, size: 16, color: Colors.deepPurpleAccent),
              label: const Text(
                'Pano Değişimi Sihirbazını Aç',
                style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.deepPurpleAccent),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickIpChip(String ipLabel) {
    final ip = ipLabel.split(' ')[0];
    return ActionChip(
      label: Text(ipLabel, style: const TextStyle(fontSize: 11)),
      backgroundColor: const Color(0xFF0F172A),
      side: const BorderSide(color: AppTheme.cardBorder),
      onPressed: () {
        _hostCtrl.text = ip;
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, color: AppTheme.textMuted)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChildLockCard(BuildContext context, AutomationState state) {
    final isLocked = state.childLock;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLocked ? Colors.amber.withValues(alpha: 0.6) : AppTheme.cardBorder,
          width: isLocked ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isLocked
                      ? Colors.amber.withValues(alpha: 0.2)
                      : AppTheme.primaryBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.child_care_rounded,
                  color: isLocked ? Colors.amber : AppTheme.primaryBlueLight,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Yazılımsal Çocuk Kilidi',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isLocked ? 'Aktif (Duvardaki Anahtarlar Kilitli)' : 'Devre Dışı (Anahtarlar Serbest)',
                      style: TextStyle(
                        fontSize: 12,
                        color: isLocked ? Colors.amberAccent : AppTheme.textMuted,
                        fontWeight: isLocked ? FontWeight.w600 : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Switch(
                value: isLocked,
                activeThumbColor: Colors.amber,
                onChanged: state.isMember
                    ? null
                    : (val) async {
                        final success = await state.toggleChildLock(val);
                        if (context.mounted && !success) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Çocuk kilidi güncellenemedi.'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Çocuk kilidi açıkken duvardaki fiziksel yaylı anahtarlara basılsa dahi lambalar ve panjurlar tetiklenmez. Kontrol yalnızca bu mobil uygulamadan sağlanır.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildPeaceNotificationCard(BuildContext context, AutomationState state) {
    final peaceData = state.peaceNotificationData;
    final enabled = peaceData?['enabled'] ?? true;
    final timeStr = peaceData?['time'] ?? '';
    final openLights = state.openLightsCount;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enabled ? Colors.indigoAccent.withValues(alpha: 0.5) : AppTheme.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.indigoAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.nightlight_round,
                  color: Colors.indigoAccent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Gece Huzur Bildirimi',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      enabled
                          ? (timeStr.isEmpty ? 'Aktif (Saat seçilmedi)' : 'Aktif (Saat $timeStr)')
                          : 'Kapalı',
                      style: TextStyle(
                        fontSize: 12,
                        color: enabled
                            ? (timeStr.isEmpty ? Colors.orange : Colors.indigoAccent)
                            : AppTheme.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                activeThumbColor: Colors.indigoAccent,
                onChanged: state.isMember
                    ? null
                    : (val) async {
                        await state.updatePeaceNotificationSettings(enabled: val);
                      },
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Her gece belirlenen saatte açık kalan lamba veya panjur varsa tek bir bildirim alırsınız ve tek tıkla hepsini kapatabilirsiniz.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          if (enabled) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Bildirim Saati:', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                TextButton.icon(
                  onPressed: state.isMember
                      ? null
                      : () async {
                          final now = TimeOfDay.now();
                          final parts = timeStr.split(':');
                          final initialTime = timeStr.isEmpty
                              ? now
                              : TimeOfDay(
                                  hour: int.tryParse(parts[0]) ?? now.hour,
                                  minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? now.minute) : now.minute,
                                );
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: initialTime,
                          );
                          if (picked != null) {
                            final h = picked.hour.toString().padLeft(2, '0');
                            final m = picked.minute.toString().padLeft(2, '0');
                            await state.updatePeaceNotificationSettings(time: '$h:$m');
                          }
                        },
                  icon: Icon(
                    Icons.access_time,
                    size: 16,
                    color: timeStr.isEmpty ? Colors.orange : Colors.indigoAccent,
                  ),
                  label: Text(
                    timeStr.isEmpty ? 'Saat Seç' : timeStr,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: timeStr.isEmpty ? Colors.orange : Colors.indigoAccent,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (openLights > 0) ...[
            const Divider(color: AppTheme.cardBorder, height: 24),
            Row(
              children: [
                const Icon(Icons.lightbulb, color: Colors.amber, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Şu an evde $openLights lamba açık',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final count = await state.closeAllOpenLights();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('$count açık lamba kapatıldı.'),
                          backgroundColor: AppTheme.accentGreen,
                        ),
                      );
                    }
                  },
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.amber.withValues(alpha: 0.15),
                    foregroundColor: Colors.amber,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                  child: const Text('Hepsini Kapat', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScheduledRulesCard(BuildContext context, AutomationState state) {
    final rules = state.scheduledRules;
    final activeCount = rules.where((r) => r.enabled).length;
    final isCloud = state.mode == AppMode.cloud;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: isCloud
          ? () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ScheduledRulesPage()),
              );
            }
          : null,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.getCardColor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: activeCount > 0
                ? Colors.cyanAccent.withValues(alpha: 0.4)
                : AppTheme.getCardBorder(context),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.schedule, color: Colors.cyanAccent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Zamanlı Otomasyon Kuralları',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isCloud
                        ? (rules.isEmpty
                            ? 'Henüz kural tanımlanmamış'
                            : '$activeCount aktif / ${rules.length} kural')
                        : 'Bulut modu gerektirir',
                    style: TextStyle(
                      fontSize: 12,
                      color: isCloud && activeCount > 0
                          ? Colors.cyanAccent
                          : AppTheme.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Işıklar ve panjurlar için otomatik açma/kapama saatleri belirleyin',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            if (isCloud)
              const Icon(Icons.chevron_right, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeSelectorCard(BuildContext context, AutomationState state) {
    final currentMode = state.themeMode;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.getCardBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.palette_outlined,
                  color: AppTheme.primaryBlueLight,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Görünüm & Tema Modu',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.getTextPrimary(context),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      switch (currentMode) {
                        ThemeMode.dark => 'Karanlık Mod (Varsayılan)',
                        ThemeMode.light => 'Aydınlık Mod',
                        ThemeMode.system => 'Sistem Teması',
                      },
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.getTextMuted(context),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Uygulama arka planında mikroçip ve devre yolları yer alır. İstediğiniz tema modunu seçebilirsiniz.',
            style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildThemeChoiceButton(
                  context: context,
                  label: 'Koyu',
                  icon: Icons.dark_mode_outlined,
                  isSelected: currentMode == ThemeMode.dark,
                  onTap: () => state.setThemeMode(ThemeMode.dark),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildThemeChoiceButton(
                  context: context,
                  label: 'Açık',
                  icon: Icons.light_mode_outlined,
                  isSelected: currentMode == ThemeMode.light,
                  onTap: () => state.setThemeMode(ThemeMode.light),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildThemeChoiceButton(
                  context: context,
                  label: 'Sistem',
                  icon: Icons.brightness_auto_outlined,
                  isSelected: currentMode == ThemeMode.system,
                  onTap: () => state.setThemeMode(ThemeMode.system),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildThemeChoiceButton({
    required BuildContext context,
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryBlue.withValues(alpha: 0.2)
              : (AppTheme.isDark(context) ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppTheme.primaryBlue : AppTheme.getCardBorder(context),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? AppTheme.primaryBlueLight : AppTheme.getTextMuted(context),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? AppTheme.primaryBlueLight : AppTheme.getTextPrimary(context),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBiometricCard(BuildContext context, AutomationState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.getCardBorder(context)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.accentGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.fingerprint_rounded, color: AppTheme.accentGreen, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${state.biometricLabel} Girişi',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.getTextPrimary(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  state.isBiometricSupported
                      ? 'Açılışta ${state.biometricLabel} ile anında giriş yapın'
                      : 'Cihazınızda biyometrik donanım bulunamadı',
                  style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                ),
              ],
            ),
          ),
          Switch(
            value: state.isBiometricEnabled,
            onChanged: state.isBiometricSupported
                ? (val) async {
                    if (val) {
                      await state.enableBiometricWithVerification();
                    } else {
                      await state.toggleBiometric(false);
                    }
                  }
                : null,
            activeThumbColor: AppTheme.accentGreen,
          ),
        ],
      ),
    );
  }
}
