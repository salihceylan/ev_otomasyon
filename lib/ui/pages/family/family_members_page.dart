import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/capabilities.dart';
import '../../../models/cloud_models.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/confirm_dialogs.dart' show showSimpleConfirm;
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../motion/motion.dart';
import '../../theme/app_theme.dart';
import '../../theme/feature_accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/neon_app_bar.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/settings/accent_button.dart';
import '../../widgets/settings/status_badge.dart';
import '../../widgets/surface_card.dart';
import 'invite_family_dialog.dart';
import 'transfer_ownership_dialog.dart';

/// Sayfanın durumdan okuduğu değerler (PF-06: `context.select`; `Capabilities` yerine skalerler; ilgisiz bildirim
/// sayfayı yeniden kurmaz).
typedef _MembersView = ({
  bool hasHome,
  String homeName,
  bool canInvite,
  bool canTransfer,
  bool canManageMembers,
  String? currentUserId,
});

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

  /// Bekleyen davetler (ev_uyelik-6; yalnız üye yönetebilen rolde). `null` = yüklenmedi / desteklenmiyor.
  List<PendingInvitation>? _invites;
  String? _invitesError;
  String? _revokingId;
  int _inviteSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadMembers());
      unawaited(_loadInvites());
    });
  }

  @override
  void dispose() {
    _loadSeq++;
    _inviteSeq++;
    super.dispose();
  }

  /// Bekleyen davetleri yükler (ev_uyelik-6). Yetkisiz rolde istek atılmaz; eski sunucu (404/405) bölümü gizler.
  Future<void> _loadInvites() async {
    final state = context.read<AutomationState>();
    if (state.activeHome == null || !state.capabilities.canManageMembers) {
      if (_invites != null || _invitesError != null) {
        setState(() {
          _invites = null;
          _invitesError = null;
        });
      }
      return;
    }
    final seq = ++_inviteSeq;
    try {
      final list = await state.fetchPendingInvitations().timeout(_loadTimeout);
      if (!mounted || seq != _inviteSeq) return;
      setState(() {
        _invites = list;
        _invitesError = null;
      });
    } catch (e) {
      if (!mounted || seq != _inviteSeq) return;
      final unsupported = e is ApiException && (e.statusCode == 404 || e.statusCode == 405);
      setState(() {
        _invites = unsupported ? null : (_invites ?? const <PendingInvitation>[]);
        _invitesError = unsupported ? null : friendlyError(e, fallback: 'Bekleyen davetler alınamadı.');
      });
    }
  }

  Future<void> _confirmRevokeInvite(PendingInvitation invite) async {
    if (_revokingId != null) return;
    final state = context.read<AutomationState>();
    final who = invite.isGuest
        ? (invite.guestName == null ? 'misafir davetini' : '"${invite.guestName}" misafir davetini')
        : 'aile bireyi davetini';
    final confirmed = await showSimpleConfirm(
      context,
      title: 'Davet iptal edilsin mi?',
      message: 'Bu $who iptal ederseniz kod artık kullanılamaz.',
      confirmLabel: 'İptal Et',
      cancelLabel: 'Vazgeç',
      destructive: true,
      icon: Icons.cancel_schedule_send_rounded,
    );
    if (!confirmed || !mounted) return;
    setState(() => _revokingId = invite.id);
    var message = 'Davet iptal edildi.';
    var color = AppTheme.accentGreen;
    try {
      await state.revokeInvitation(invite.id);
    } catch (e) {
      if (e is ApiException && e.statusCode == 404) {
        // Davet bu arada kullanıldı / süresi doldu: liste yenilenir.
        message = 'Davet zaten kullanılmış ya da süresi dolmuş; liste yenilendi.';
        color = AppTheme.accentAmber;
      } else {
        message = friendlyError(e, fallback: 'Davet iptal edilemedi. Lütfen tekrar deneyin.');
        color = AppTheme.accentRed;
      }
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
    if (!mounted) return;
    await _loadInvites();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        key: const Key('snack_invite_revoke'),
        content: Text(message),
        backgroundColor: AppTheme.filledAccent(color),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildPendingInvites(BuildContext context) {
    final invites = _invites ?? const <PendingInvitation>[];
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    return Column(
      key: const Key('pending_invitations'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Bekleyen davetler', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: primary)),
        const SizedBox(height: 8),
        if (_invitesError != null)
          InlineMessage.error(_invitesError!, key: const Key('pending_invitations_error'))
        else if (invites.isEmpty)
          Text('Bekleyen davet yok.', key: const Key('pending_invitations_empty'), style: TextStyle(fontSize: 12.5, color: muted))
        else
          for (final inv in invites)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SurfaceCard(
                key: Key('pending_invite_${inv.id}'),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      inv.isGuest ? 'Misafir${inv.guestName == null ? '' : ': ${inv.guestName}'}' : 'Aile bireyi',
                      style: TextStyle(fontWeight: FontWeight.w700, color: primary),
                    ),
                    if (inv.expiresAt != null)
                      Text(
                        'Kod son geçerlilik: ${formatLocalDateTime(inv.expiresAt!)}',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    if (inv.guestValidUntil != null)
                      Text(
                        'Misafir erişimi: ${inv.guestValidFrom == null ? '' : '${formatLocalDateTime(inv.guestValidFrom!)} - '}'
                        '${formatLocalDateTime(inv.guestValidUntil!)}',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: Key('btn_revoke_invite_${inv.id}'),
                        onPressed: _revokingId != null ? null : () => _confirmRevokeInvite(inv),
                        icon: const Icon(Icons.cancel_outlined, size: 18),
                        label: const Text('İptal Et'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
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

    // Ortak onay kabuğu (orb başlık + hap eylemler; ham `AlertDialog` değil). Anahtarlar/metinler aynen (testlerle pinli).
    final confirmed = await showSimpleConfirm(
      context,
      title: isGuest ? 'Misafir Yetkisini İptal Et' : 'Üyeyi Evden Çıkar',
      message:
          '"$name" kullanıcısının bu ev üzerindeki tüm erişim ve kontrol yetkisi iptal edilecek ve açık '
          'bağlantıları kesilecek. Devam etmek istiyor musunuz?',
      confirmLabel: 'Yetkiyi İptal Et',
      cancelLabel: 'Vazgeç',
      destructive: true,
      icon: Icons.person_remove_rounded,
      cancelKey: const Key('btn_remove_cancel'),
      confirmKey: const Key('btn_remove_confirm'),
    );
    if (!confirmed || !mounted) return;

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
          message =
              'Yetki iptal isteği gönderildi ancak üye listesi yenilenemedi; sonuç doğrulanamadı. '
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
        // Beyaz yazılı dolgu: ham amber/yeşil/kırmızı zeminde beyaz metin 2.1–3.8:1 idi.
        backgroundColor: AppTheme.filledAccent(color),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static _MembersView _viewOf(AutomationState state) {
    final caps = state.capabilities;
    return (
      hasHome: state.activeHome != null,
      homeName: state.activeHome?.name ?? 'Evim',
      canInvite: caps.canInvite,
      canTransfer: caps.canTransferOwnership,
      canManageMembers: caps.canManageMembers,
      currentUserId: state.currentUser?.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = context.select<AutomationState, _MembersView>(_viewOf);
    // Misafir "kalan süre" metni build anındaki saatle hesaplanır (okuma: izleme yok).
    final now = context.read<AutomationState>().clock.now();

    return Scaffold(
      // Ortak Neon Glass üst çubuk (geri diski + özellik orb'u + başlık): başlık kesilmez, sığmazsa küçülür.
      appBar: const NeonAppBar(
        title: 'Aile & Misafir Yönetimi',
        feature: AppFeature.family,
        icon: Icons.family_restroom_rounded,
      ),
      body: RefreshIndicator(
        onRefresh: _loadMembers,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeaderCard(context, view),
              if (view.canManageMembers && view.hasHome && (_invites != null || _invitesError != null)) ...[
                const SizedBox(height: 20),
                _buildPendingInvites(context),
              ],
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
                    AnimatedCount(
                      value: _members.length,
                      format: (v) => '$v Kişi',
                      style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // Durum geçişi (yükleme → içerik → boş/hata): ağaçta her an TEK durum çocuğu (eski+yeni metin birlikte yok).
              StateSwitcher(
                stateKey: _listStateKey(view),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!view.hasHome)
                      const InlineMessage.warning('Aktif bir daire seçili değil.', key: Key('members_no_home'))
                    else if (_errorMessage != null) ...[
                      InlineMessage.error(
                        _errorMessage!,
                        key: const Key('members_error'),
                        // Tek kurtarma eylemi düz metin bağlantısı DEĞİL, sayfanın diğer eylemleri gibi çerçeveli hap düğme
                        // (rose = hata ailesi, yenile simgesi): mesaj metniyle aynı sol kenardan başlar (TextButton'ın 12 dp
                        // iç boşluğu yüzünden 11.5 dp hizasızdı), hedef ≥ 48 dp.
                        trailing: OutlinedButton.icon(
                          key: const Key('btn_members_retry'),
                          onPressed: _isLoading ? null : _loadMembers,
                          icon: Icon(Icons.refresh_rounded, size: accentIconSize(context)),
                          label: const Text('Tekrar Dene', style: TextStyle(fontWeight: FontWeight.bold)),
                          style: accentOutlinedButtonStyle(
                            context,
                            AppFamilies.rose,
                            minimumSize: const Size(0, AppTouch.minTarget),
                          ),
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
                            // Boş durum orb'u devre dışı gri (slate) değil, özellik renginde (aile = sky) ve yumuşak parıltılıdır
                            // (üstteki NeonAppBar orb'uyla aynı aile; gri orb sayfanın en "ölü" öğesiydi).
                            OrbIconBadge(
                              icon: Icons.group_rounded,
                              family: AppFeature.family.accentFamily,
                              size: OrbSize.lg,
                              glow: true,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Henüz kayıtlı başka bir üye bulunamadı',
                              style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    if (_isLoading && _members.isEmpty && _errorMessage == null && view.hasHome) ...[
                      // Gerçek üye kartıyla aynı iç boşluk (14) ve satır sayısı (3: ad, iletişim, rozet): ~92 dp (gerçek kartlar
                      // 96-136 dp); eskiden 74 dp idi ve veri gelince liste kart başına ≥ 22 dp zıplıyordu.
                      const SkeletonCard(lines: 3, padding: EdgeInsets.all(14)),
                      const SizedBox(height: 12),
                      const SkeletonCard(lines: 3, padding: EdgeInsets.all(14)),
                    ],
                    for (final (i, m) in _members.indexed)
                      StaggeredEntrance(
                        key: ValueKey<String>('enter_member_${m.userId}'),
                        index: i,
                        child: _buildMemberCard(context, m, view, now),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [StateSwitcher] anahtarı: build'deki dallarla aynı öncelik (daire yok → hata → yükleniyor → boş → içerik).
  String _listStateKey(_MembersView view) {
    if (!view.hasHome) return 'no_home';
    if (_errorMessage != null) return 'error';
    if (_members.isEmpty) return _isLoading ? 'loading' : 'empty';
    return 'content';
  }

  Widget _buildHeaderCard(BuildContext context, _MembersView view) {
    return SurfaceCard(
      accent: AppFeature.family.accentFamily.base,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OrbIconBadge(icon: Icons.home_rounded, family: AppFeature.family.accentFamily, active: true),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  view.homeName,
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
          if (view.canInvite) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const Key('btn_invite_family'),
                onPressed: () async {
                  await InviteFamilyDialog.show(context);
                  if (!mounted) return;
                  unawaited(_loadInvites());
                  await _loadMembers(silent: true);
                },
                icon: Icon(Icons.person_add_alt_1_rounded, size: accentIconSize(context)),
                // NBSP: "(QR Üret)" bölünmez (yetim "Üret)" satırı yok); iki satıra sararsa ortalı.
                label: const Text('Yeni Birey / Misafir Davet Et (QR Üret)', textAlign: TextAlign.center),
                style: accentButtonStyle(null),
              ),
            ),
          ],
          if (view.canTransfer) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('btn_transfer_home'),
                onPressed: () async {
                  await TransferOwnershipDialog.show(context);
                  if (mounted) await _loadMembers(silent: true);
                },
                icon: Icon(Icons.transfer_within_a_station, size: accentIconSize(context)),
                label: const Text(
                  'Daireyi Devret (Mülkiyet Transferi)',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                // Metin, simge ve çerçeve aynı aileden ve OKUNUR tonda (açık temada ham amber ≈2:1 idi); şekil temanın
                // hap (stadium) biçimi, yükseklik birincil düğmeyle aynı (52).
                style: accentOutlinedButtonStyle(
                  context,
                  AppFeature.ownershipTransfer.accentFamily,
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMemberCard(BuildContext context, HomeMember member, _MembersView view, DateTime now) {
    final isExpired = _isExpired(member, now);
    final isCurrentUser = view.currentUserId == member.userId;
    final role = member.homeRole;
    final isOwner = role == HomeRole.owner;
    final isGuest = role == HomeRole.guest;

    // Rol: renk ailesi + etiket + simge (renk tek ipucu değil). Etiket metinleri testlerle pinlidir (büyük harf).
    AccentFamily roleFamily = AppFamilies.sky;
    String roleLabel = 'AİLE ÜYESİ';
    IconData roleIcon = Icons.groups_rounded;
    switch (role) {
      case HomeRole.owner:
        roleFamily = AppFamilies.amber;
        roleLabel = 'EV SAHİBİ';
        roleIcon = Icons.verified_user_rounded;
      case HomeRole.guest:
        roleFamily = isExpired ? AppFamilies.rose : AppFamilies.violet;
        roleLabel = isExpired ? 'MİSAFİR (SÜRESİ DOLDU)' : 'SÜRELİ MİSAFİR';
        roleIcon = Icons.hourglass_top_rounded;
      case HomeRole.serviceUser:
      case HomeRole.serviceSession:
        roleFamily = AppFamilies.cyan;
        roleLabel = 'SERVİS PERSONELİ';
        roleIcon = Icons.build_circle_rounded;
      case HomeRole.resident:
        break;
      case HomeRole.unknown:
        roleFamily = AppFamilies.slate;
        roleLabel = 'KULLANICI';
        roleIcon = Icons.person_rounded;
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
    final canRemove = view.canManageMembers && !isCurrentUser && !isOwner;
    final muted = AppTheme.getTextMuted(context);

    return SurfaceCard(
      key: Key('card_member_${member.userId}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      accent: isExpired ? AppFamilies.rose.base : (isOwner ? AppFamilies.amber.base : null),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar orb: rol rengi + rol simgesi (süresi dolan misafir soluk).
          OrbIconBadge(icon: roleIcon, family: roleFamily, enabled: !isExpired, active: isOwner),
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
                      const StatusBadge(label: 'Sen', family: AppFamilies.sky, maxLines: 1),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  contact,
                  style: TextStyle(fontSize: 12, color: muted),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusBadge(label: roleLabel, family: roleFamily),
                    if (remainingText != null)
                      Text(
                        remainingText,
                        key: Key('member_remaining_${member.userId}'),
                        style: TextStyle(
                          fontSize: 12,
                          // Okunur ton: ham amber/kırmızı açık temada ≈2–4:1 idi.
                          color: isExpired ? AppTheme.dangerText(context) : AppTheme.warningText(context),
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
                      style: TextStyle(fontSize: 12, color: muted),
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
                : Tooltip(
                    message: 'Yetkiyi İptal Et',
                    excludeFromSemantics: true,
                    child: GlassIconButton(
                      key: Key('btn_remove_member_${member.userId}'),
                      icon: Icons.delete_outline_rounded,
                      iconColor: AppTheme.dangerText(context),
                      semanticLabel: 'Yetkiyi İptal Et',
                      size: 40,
                      onTap: _removingId == null ? () => _confirmRemoveMember(member) : null,
                    ),
                  ),
        ],
      ),
    );
  }
}
