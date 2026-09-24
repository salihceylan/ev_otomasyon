import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

class InviteFamilyDialog extends StatefulWidget {
  final String? initialInviteCode;
  final String? initialHomeName;

  const InviteFamilyDialog({
    super.key,
    this.initialInviteCode,
    this.initialHomeName,
  });

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const InviteFamilyDialog(),
      ),
    );
  }

  @override
  State<InviteFamilyDialog> createState() => _InviteFamilyDialogState();
}

class _InviteFamilyDialogState extends State<InviteFamilyDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _guestNameController = TextEditingController();

  // Aile Üyesi State
  bool _isLoadingMember = false;
  String? _memberInviteCode;
  String? _memberQrPayload;
  String? _memberExpiresAtStr;
  String? _memberError;

  // Misafir State
  bool _isLoadingGuest = false;
  String? _guestInviteCode;
  String? _guestQrPayload;
  String? _guestValidUntilStr;
  String? _guestError;
  int _guestDurationHours = 8; // Varsayılan 8 saat (mesai)

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    if (widget.initialInviteCode != null) {
      _memberInviteCode = widget.initialInviteCode;
      _memberQrPayload = 'AHBU-INVITE:${widget.initialInviteCode}';
      _memberExpiresAtStr = '24 saat geçerli';
    } else {
      _generateMemberCode();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _guestNameController.dispose();
    super.dispose();
  }

  Future<void> _generateMemberCode() async {
    final state = context.read<AutomationState>();
    if (state.activeHome == null) {
      setState(() => _memberError = 'Aktif bir ev bulunamadı');
      return;
    }

    setState(() {
      _isLoadingMember = true;
      _memberError = null;
    });

    try {
      final res = await state.createHomeInvitation(state.activeHome!.id, role: 'member');
      final code = res['inviteCode'] ?? res['invite_code'];
      final exp = res['expiresAt'] ?? res['expires_at'];
      final qr = res['qrPayload'] ?? 'AHBU-INVITE:$code';

      if (mounted) {
        setState(() {
          _memberInviteCode = code?.toString();
          _memberQrPayload = qr.toString();
          if (exp != null) {
            final dt = DateTime.tryParse(exp.toString());
            if (dt != null) {
              _memberExpiresAtStr =
                  '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} (${dt.day}.${dt.month}.${dt.year})';
            }
          }
          _isLoadingMember = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _memberError = e.toString().replaceAll('Exception: ', '');
          _isLoadingMember = false;
        });
      }
    }
  }

  Future<void> _generateGuestCode() async {
    final state = context.read<AutomationState>();
    if (state.activeHome == null) {
      setState(() => _guestError = 'Aktif bir ev bulunamadı');
      return;
    }

    setState(() {
      _isLoadingGuest = true;
      _guestError = null;
    });

    try {
      final guestName = _guestNameController.text.trim();
      final res = await state.createHomeInvitation(
        state.activeHome!.id,
        role: 'guest',
        durationHours: _guestDurationHours,
        guestName: guestName.isNotEmpty ? guestName : null,
      );

      final code = res['inviteCode'] ?? res['invite_code'];
      final until = res['guestValidUntil'] ?? res['guest_valid_until'];
      final qr = res['qrPayload'] ?? 'AHBU-INVITE:$code';

      if (mounted) {
        setState(() {
          _guestInviteCode = code?.toString();
          _guestQrPayload = qr.toString();
          if (until != null) {
            final dt = DateTime.tryParse(until.toString());
            if (dt != null) {
              _guestValidUntilStr =
                  '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} (${dt.day}.${dt.month}.${dt.year})';
            }
          }
          _isLoadingGuest = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _guestError = e.toString().replaceAll('Exception: ', '');
          _isLoadingGuest = false;
        });
      }
    }
  }

  void _copyToClipboard(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.copy_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text('Davet kodu ($code) panoya kopyalandı!')),
          ],
        ),
        backgroundColor: AppTheme.accentGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final homeName = widget.initialHomeName ?? state.activeHome?.name ?? 'Evim';

    return Dialog(
      backgroundColor: AppTheme.surfaceDark,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.cardBorder, width: 1.2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Başlık
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.group_add_outlined, color: AppTheme.primaryBlueLight, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Erişim Paylaş & Davet Et',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          homeName,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppTheme.textMuted, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Tab Bar
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppTheme.primaryBlue,
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                labelColor: Colors.white,
                unselectedLabelColor: AppTheme.textMuted,
                labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                tabs: const [
                  Tab(icon: Icon(Icons.family_restroom, size: 18), text: 'Aile Bireyi'),
                  Tab(icon: Icon(Icons.hourglass_top_outlined, size: 18), text: 'Süreli Misafir'),
                ],
              ),
            ),

            // Tab Views
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildFamilyTab(homeName),
                  _buildGuestTab(homeName),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFamilyTab(String homeName) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '"$homeName" evini sürekli kontrol edebilmesi için aile fertlerine 24 saat geçerli dinamik QR kod ve katılım kodu üretildi.',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12.5, height: 1.3),
          ),
          const SizedBox(height: 16),
          if (_isLoadingMember) ...[
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            ),
          ] else if (_memberError != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accentRed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.3)),
              ),
              child: Text(
                _memberError!,
                style: const TextStyle(color: AppTheme.accentRed, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _generateMemberCode,
              child: const Text('Tekrar Dene'),
            ),
          ] else if (_memberInviteCode != null) ...[
            // Dinamik QR Görseli
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.25),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: _memberQrPayload ?? _memberInviteCode!,
                  version: QrVersions.auto,
                  size: 160,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Kod Kartı
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.cardDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.primaryBlueLight.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  const Text(
                    'AİLE KATILIM KODU',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    _memberInviteCode!,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                      color: AppTheme.primaryBlueLight,
                    ),
                  ),
                  if (_memberExpiresAtStr != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Son Geçerlilik: $_memberExpiresAtStr',
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => _copyToClipboard(_memberInviteCode!),
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Kodu Kopyala & Paylaş'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '📷 Aile bireyiniz AHBU uygulamasını açıp sağ üstteki QR Tarayıcıya bu kodu gösterdiğinde anında eve bağlanacaktır.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5, height: 1.3),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGuestTab(String homeName) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.accentAmber.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.shield_outlined, color: AppTheme.accentAmber, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Süreli Misafir / Temizlikçi Modu: Süre bittiğinde yetki otomatik olarak kapanır.',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.accentAmber),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Süre Seçimi
          const Text('Erişim Süresi Belirleyin:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildDurationChip(2, '2 Saat'),
              _buildDurationChip(4, '4 Saat'),
              _buildDurationChip(8, '8 Saat (Mesai)'),
              _buildDurationChip(24, '24 Saat (1 Gün)'),
            ],
          ),
          const SizedBox(height: 12),

          // Misafir Adı / Açıklama
          TextField(
            controller: _guestNameController,
            decoration: InputDecoration(
              labelText: 'Misafir / Görevli Adı (İsteğe Bağlı)',
              hintText: 'Örn: Temizlikçi Fatma Hanım, Misafir Ali',
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 12),

          // QR Üret Butonu
          ElevatedButton.icon(
            onPressed: _isLoadingGuest ? null : _generateGuestCode,
            icon: _isLoadingGuest
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.qr_code_2_rounded, size: 18),
            label: Text(_guestInviteCode == null ? 'Geçici Misafir QR\'ı Üret' : 'Yeni Misafir QR\'ı Üret'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentPurple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),

          if (_guestError != null) ...[
            const SizedBox(height: 10),
            Text(
              _guestError!,
              style: const TextStyle(color: AppTheme.accentRed, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],

          if (_guestInviteCode != null) ...[
            const SizedBox(height: 16),
            // QR Görseli
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accentPurple.withValues(alpha: 0.25),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: _guestQrPayload ?? _guestInviteCode!,
                  version: QrVersions.auto,
                  size: 160,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.cardDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentPurple.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  const Text(
                    'GEÇİCİ MİSAFİR KODU',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    _guestInviteCode!,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                  if (_guestValidUntilStr != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '⏳ Son Erişim Saati: $_guestValidUntilStr',
                      style: const TextStyle(color: AppTheme.accentAmber, fontWeight: FontWeight.bold, fontSize: 11.5),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _copyToClipboard(_guestInviteCode!),
              icon: const Icon(Icons.copy_rounded, size: 16, color: AppTheme.accentPurple),
              label: const Text('Kodu Kopyala & Paylaş', style: TextStyle(color: AppTheme.accentPurple)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.accentPurple),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDurationChip(int hours, String label) {
    final isSelected = _guestDurationHours == hours;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : AppTheme.textPrimary)),
      selected: isSelected,
      selectedColor: AppTheme.accentPurple,
      backgroundColor: const Color(0xFF0F172A),
      side: BorderSide(color: isSelected ? AppTheme.accentPurple : AppTheme.cardBorder),
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _guestDurationHours = hours;
            // Seçilen süre değişince yeni kod üret
            _generateGuestCode();
          });
        }
      },
    );
  }
}
