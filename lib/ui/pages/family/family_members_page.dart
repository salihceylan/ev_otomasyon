import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';
import 'invite_family_dialog.dart';
import 'transfer_ownership_dialog.dart';

class FamilyMembersPage extends StatefulWidget {
  const FamilyMembersPage({super.key});

  @override
  State<FamilyMembersPage> createState() => _FamilyMembersPageState();
}

class _FamilyMembersPageState extends State<FamilyMembersPage> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _members = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMembers();
    });
  }

  Future<void> _loadMembers() async {
    final state = context.read<AutomationState>();
    if (state.activeHome == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final list = await state.fetchHomeMembers();
      if (mounted) {
        setState(() {
          _members = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _confirmRemoveMember(Map<String, dynamic> member) async {
    final state = context.read<AutomationState>();
    final fullName = member['fullName'] ?? member['full_name'] ?? 'Kullanıcı';
    final userId = member['userId'] ?? member['user_id'];
    final role = member['role'];

    if (userId == null) return;

    final isGuest = role == 'guest';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppTheme.accentRed, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isGuest ? 'Misafir Yetkisini İptal Et' : 'Üyeyi Evden Çıkar',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Text(
          '"$fullName" kullanıcısının bu ev üzerindeki tüm erişim ve kontrol yetkisini iptal etmek istediğinizden emin misiniz?',
          style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentRed,
              foregroundColor: Colors.white,
            ),
            child: const Text('Yetkiyi İptal Et'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await state.removeHomeMember(userId as int);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ "$fullName" kullanıcısının yetkisi iptal edildi.'),
            backgroundColor: AppTheme.accentGreen,
          ),
        );
        await _loadMembers();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hata: $e'),
            backgroundColor: AppTheme.accentRed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final homeName = state.activeHome?.name ?? 'Evim';

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
                'Aile & Misafir Yönetimi',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _loadMembers,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Üst Bilgilendirme ve Ekleme Kartı
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.home_outlined, color: AppTheme.primaryBlueLight, size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            homeName,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Aile bireylerinizi kalıcı olarak veya temizlik görevlisi ve misafirlerinizi süreli olarak evinize davet edebilirsiniz.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.3),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          await InviteFamilyDialog.show(context);
                          if (mounted) {
                            await _loadMembers();
                          }
                        },
                        icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                        label: const Text('Yeni Birey / Misafir Davet Et (QR Üret)'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    if (state.isOwner) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await TransferOwnershipDialog.show(context);
                            if (mounted) {
                              await _loadMembers();
                            }
                          },
                          icon: const Icon(Icons.transfer_within_a_station, size: 18, color: AppTheme.accentAmber),
                          label: const Text(
                            'Daireyi Devret (Mülkiyet Transferi)',
                            style: TextStyle(color: AppTheme.accentAmber, fontWeight: FontWeight.bold),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppTheme.accentAmber),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Liste Başlığı
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Kayıtlı Kişiler & Yetkiler',
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                  ),
                  if (_isLoading)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      '${_members.length} Kişi',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.accentRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.accentRed.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: AppTheme.accentRed, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              if (!_isLoading && _members.isEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(28),
                  alignment: Alignment.center,
                  child: const Column(
                    children: [
                      Icon(Icons.group_outlined, size: 44, color: AppTheme.textMuted),
                      SizedBox(height: 10),
                      Text('Henüz kayıtlı başka bir üye bulunamadı', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                    ],
                  ),
                ),
              ],

              // Üye Kartları
              ..._members.map((m) => _buildMemberCard(context, m, state)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMemberCard(BuildContext context, Map<String, dynamic> member, AutomationState state) {
    final fullName = member['fullName'] ?? member['full_name'] ?? 'İsimsiz Kullanıcı';
    final email = member['email'] ?? '';
    final phone = member['phone'] ?? '';
    final role = (member['role'] ?? 'member').toString().toLowerCase();
    final validUntil = member['validUntil'] ?? member['valid_until'];
    final isExpired = member['isExpired'] == true || member['is_expired'] == true;
    final userId = member['userId'] ?? member['user_id'];
    final isCurrentUser = state.currentUser?.id == userId;
    final isOwner = role == 'owner';
    final isGuest = role == 'guest';

    Color roleColor = AppTheme.primaryBlueLight;
    String roleLabel = 'AİLE ÜYESİ';
    IconData roleIcon = Icons.family_restroom;

    if (isOwner) {
      roleColor = AppTheme.accentAmber;
      roleLabel = 'EV SAHİBİ (ADMIN)';
      roleIcon = Icons.admin_panel_settings_outlined;
    } else if (isGuest) {
      roleColor = isExpired ? AppTheme.accentRed : AppTheme.accentPurple;
      roleLabel = isExpired ? 'MİSAFİR (SÜRESİ DOLDU)' : 'SÜRELİ MİSAFİR';
      roleIcon = Icons.hourglass_top_outlined;
    }

    String? remainingTimeStr;
    if (isGuest && validUntil != null) {
      final dt = DateTime.tryParse(validUntil.toString());
      if (dt != null) {
        final now = DateTime.now();
        if (dt.isAfter(now)) {
          final diff = dt.difference(now);
          if (diff.inHours > 0) {
            remainingTimeStr = '⏳ ${diff.inHours} saat ${diff.inMinutes % 60} dk kaldı';
          } else {
            remainingTimeStr = '⏳ ${diff.inMinutes} dakika kaldı';
          }
        } else {
          remainingTimeStr = '❌ Süresi Sona Erdi';
        }
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isExpired ? AppTheme.accentRed.withValues(alpha: 0.3) : AppTheme.cardBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: roleColor.withValues(alpha: 0.15),
            child: Icon(roleIcon, color: roleColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        fullName.toString(),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isCurrentUser) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('Sen', style: TextStyle(fontSize: 10, color: AppTheme.primaryBlueLight)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  email.isNotEmpty ? email.toString() : (phone.isNotEmpty ? phone.toString() : 'Davet ile katıldı'),
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: roleColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: roleColor.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        roleLabel,
                        style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: roleColor),
                      ),
                    ),
                    if (remainingTimeStr != null) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          remainingTimeStr,
                          style: TextStyle(
                            fontSize: 11,
                            color: isExpired ? AppTheme.accentRed : AppTheme.accentAmber,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (state.isOwner && !isCurrentUser && !isOwner)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppTheme.accentRed, size: 20),
              tooltip: 'Yetkiyi İptal Et',
              onPressed: () => _confirmRemoveMember(member),
            ),
        ],
      ),
    );
  }
}

