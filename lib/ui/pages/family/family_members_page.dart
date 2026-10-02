import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/capabilities.dart';
import '../../../models/cloud_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';
import 'invite_family_dialog.dart';
import 'transfer_ownership_dialog.dart';

/// Aile & misafir yönetimi: üye listesi (UUID **String** kimlikler), davet ve devir girişleri.
///
/// Yükleme durumu her zaman bir çıkış yoluna sahiptir: zaman aşımı (20 sn) -> hata kartı -> "Tekrar
/// dene". Üye silme onaylıdır ve sonucu **listeyi yeniden okuyarak** doğrulanır.
class FamilyMembersPage extends StatefulWidget {
  const FamilyMembersPage({super.key});

  @override
  State<FamilyMembersPage> createState() => _FamilyMembersPageState();
}

class _FamilyMembersPageState extends State<FamilyMembersPage> {
  static const Duration _loadTimeout = Duration(seconds: 20);

  bool _isLoading = true;
  List<HomeMember> _members = const <HomeMember>[];
  String? _errorMessage;
  String? _removingId;
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadMembers());
    });
  }

  @override
  void dispose() {
    _loadSeq++;
    super.dispose();
  }

  /// Üye listesini yükler. Dönüş: liste **başarıyla** yenilendi mi (hata / bayat yanıt / kapanma = `false`).
  Future<bool> _loadMembers({bool silent = false}) async {
    final state = context.read<AutomationState>();
    if (state.activeHome == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = null;
        _members = const <HomeMember>[];
      });
      return false;
    }
    final seq = ++_loadSeq;
    if (!silent) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }
    try {
      final list = await state.fetchHomeMembers().timeout(_loadTimeout);
      if (!mounted || seq != _loadSeq) return false;
      setState(() {
        _members = list;
        _isLoading = false;
        _errorMessage = null;
      });
      return true;
    } catch (e) {
      if (!mounted || seq != _loadSeq) return false;
      setState(() {
        _errorMessage = friendlyError(e, fallback: 'Üye listesi alınamadı. Lütfen tekrar deneyin.');
        _isLoading = false;
      });
      return false;
    }
  }

  bool _isExpired(HomeMember m, DateTime now) {
    if (m.isExpired) return true;
    final until = m.validUntil;
    return m.isGuest && until != null && now.isAfter(until);
  }

  Future<void> _confirmRemoveMember(HomeMember member) async {
    if (_removingId != null) return;
    final state = context.read<AutomationState>();
    final name = member.fullName.isNotEmpty ? member.fullName : 'Bu kullanıcı';
    final isGuest = member.isGuest;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.getSurfaceColor(ctx),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppTheme.getCardBorder(ctx)),
        ),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppTheme.accentRed, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isGuest ? 'Misafir Yetkisini İptal Et' : 'Üyeyi Evden Çıkar',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(ctx)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Text(
          '"$name" kullanıcısının bu ev üzerindeki tüm erişim ve kontrol yetkisi iptal edilecek ve açık '
          'bağlantıları kesilecek. Devam etmek istiyor musunuz?',
          style: TextStyle(fontSize: 13, color: AppTheme.getTextMuted(ctx), height: 1.35),
        ),
        actions: [
          TextButton(
            key: const Key('btn_remove_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Vazgeç', style: TextStyle(color: AppTheme.getTextMuted(ctx))),
          ),
          ElevatedButton(
            key: const Key('btn_remove_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentRed, foregroundColor: Colors.white),
            child: const Text('Yetkiyi İptal Et'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _removingId = member.userId);
    var message = '';
    var color = AppTheme.accentRed;
    try {
      final done = await state.removeHomeMember(member.userId);
      if (!mounted) return;
      if (!done) {
        message = 'Kullanıcı kaldırılamadı. Lütfen tekrar deneyin.';
      } else {
        // Sonucu doğrula: listeyi yeniden oku. Yeniden okuma başarısızsa sonuç BİLİNMEZ: eski liste
        // "hâlâ listede" kanıtı sayılmaz (silme büyük olasılıkla gerçekleşmiştir).
        final refreshed = await _loadMembers(silent: true);
        if (!mounted) return;
        if (!refreshed) {
          color = AppTheme.accentAmber;
          message = 'Yetki iptal isteği gönderildi ancak üye listesi yenilenemedi; sonuç doğrulanamadı. '
              'Listeyi aşağı çekip yenileyerek kontrol edin.';
        } else if (_members.any((m) => m.userId == member.userId)) {
          message = 'İşlem tamamlandı ancak "$name" listede görünmeye devam ediyor. Listeyi yenileyip tekrar deneyin.';
        } else {
          color = AppTheme.accentGreen;
          message = '"$name" kullanıcısının yetkisi iptal edildi.';
        }
      }
    } catch (e) {
      if (!mounted) return;
      message = friendlyError(e, fallback: 'Kullanıcı kaldırılamadı. Lütfen tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _removingId = null);
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        key: const Key('snack_member_removal'),
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final caps = state.capabilities;
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
                errorBuilder: (context, error, stack) => const Icon(Icons.home_work_rounded, size: 24),
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
              _buildHeaderCard(context, state, caps, homeName),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Expanded: dar ekranda / büyük yazıda başlık alt satıra sarar (sabit genişlik taşardı).
                  Expanded(
                    child: Text(
                      'Kayıtlı Kişiler & Yetkiler',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.getTextPrimary(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_isLoading)
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Text(
                      '${_members.length} Kişi',
                      style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (state.activeHome == null)
                const InlineMessage.warning('Aktif bir daire seçili değil.', key: Key('members_no_home'))
              else if (_errorMessage != null) ...[
                InlineMessage.error(
                  _errorMessage!,
                  key: const Key('members_error'),
                  trailing: TextButton(
                    key: const Key('btn_members_retry'),
                    onPressed: _isLoading ? null : _loadMembers,
                    child: const Text('Tekrar Dene'),
                  ),
                ),
                const SizedBox(height: 12),
              ] else if (!_isLoading && _members.isEmpty)
                Container(
                  key: const Key('members_empty'),
                  padding: const EdgeInsets.all(28),
                  alignment: Alignment.center,
                  child: Column(
                    children: [
                      Icon(Icons.group_outlined, size: 44, color: AppTheme.getTextMuted(context)),
                      const SizedBox(height: 10),
                      Text(
                        'Henüz kayıtlı başka bir üye bulunamadı',
                        style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              for (final m in _members) _buildMemberCard(context, m, state, caps),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(BuildContext context, AutomationState state, Capabilities caps, String homeName) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
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
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Aile bireylerinizi kalıcı olarak, temizlik görevlisi ve misafirlerinizi süreli olarak evinize davet edebilirsiniz.',
            style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context), height: 1.3),
          ),
          if (caps.canInvite) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const Key('btn_invite_family'),
                onPressed: () async {
                  await InviteFamilyDialog.show(context);
                  if (mounted) await _loadMembers(silent: true);
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
          ],
          if (caps.canTransferOwnership) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('btn_transfer_home'),
                onPressed: () async {
                  await TransferOwnershipDialog.show(context);
                  if (mounted) await _loadMembers(silent: true);
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
    );
  }

  Widget _buildMemberCard(BuildContext context, HomeMember member, AutomationState state, Capabilities caps) {
    final now = state.clock.now();
    final isExpired = _isExpired(member, now);
    final isCurrentUser = state.currentUser?.id == member.userId;
    final role = member.homeRole;
    final isOwner = role == HomeRole.owner;
    final isGuest = role == HomeRole.guest;

    Color roleColor = AppTheme.primaryBlueLight;
    String roleLabel = 'AİLE ÜYESİ';
    IconData roleIcon = Icons.family_restroom;
    switch (role) {
      case HomeRole.owner:
        roleColor = AppTheme.accentAmber;
        roleLabel = 'EV SAHİBİ';
        roleIcon = Icons.admin_panel_settings_outlined;
      case HomeRole.guest:
        roleColor = isExpired ? AppTheme.accentRed : AppTheme.accentPurple;
        roleLabel = isExpired ? 'MİSAFİR (SÜRESİ DOLDU)' : 'SÜRELİ MİSAFİR';
        roleIcon = Icons.hourglass_top_outlined;
      case HomeRole.serviceUser:
      case HomeRole.serviceSession:
        roleColor = AppTheme.accentCyan;
        roleLabel = 'SERVİS PERSONELİ';
        roleIcon = Icons.build_circle_outlined;
      case HomeRole.resident:
        break;
      case HomeRole.unknown:
        roleLabel = 'KULLANICI';
        roleIcon = Icons.person_outline;
    }

    String? remainingText;
    final until = member.validUntil;
    if (isGuest && until != null) {
      remainingText = isExpired ? 'Süresi sona erdi' : '${formatRemaining(until.difference(now))} kaldı';
    }

    final contact = member.email.isNotEmpty
        ? member.email
        : (member.phone.isNotEmpty ? member.phone : 'Davet ile katıldı');
    final removing = _removingId == member.userId;
    final canRemove = caps.canManageMembers && !isCurrentUser && !isOwner;

    return Container(
      key: Key('card_member_${member.userId}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isExpired ? AppTheme.accentRed.withValues(alpha: 0.3) : AppTheme.getCardBorder(context),
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
                        member.fullName.isNotEmpty ? member.fullName : 'İsimsiz Kullanıcı',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                          color: AppTheme.getTextPrimary(context),
                        ),
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
                  contact,
                  style: TextStyle(fontSize: 11.5, color: AppTheme.getTextMuted(context)),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
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
                    if (remainingText != null)
                      Text(
                        remainingText,
                        key: Key('member_remaining_${member.userId}'),
                        style: TextStyle(
                          fontSize: 11,
                          color: isExpired ? AppTheme.accentRed : AppTheme.accentAmber,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                if (isGuest && until != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      'Erişim bitişi: ${formatLocalDateTime(until)}',
                      key: Key('member_until_${member.userId}'),
                      style: TextStyle(fontSize: 11, color: AppTheme.getTextMuted(context)),
                    ),
                  ),
              ],
            ),
          ),
          if (canRemove)
            removing
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    key: Key('btn_remove_member_${member.userId}'),
                    icon: const Icon(Icons.delete_outline, color: AppTheme.accentRed, size: 20),
                    tooltip: 'Yetkiyi İptal Et',
                    onPressed: _removingId == null ? () => _confirmRemoveMember(member) : null,
                  ),
        ],
      ),
    );
  }
}
