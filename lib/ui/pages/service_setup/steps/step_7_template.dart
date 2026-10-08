import 'package:flutter/material.dart';

import '../../../../models/install_template_models.dart';
import '../../../theme/tokens.dart';
import '../logic/template_logic.dart';
import '../panel/service_glass.dart';
import '../service_setup_controller.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';

/// 7. adımın başındaki **isteğe bağlı** "Şablon uygula" kartı (plan K-Ş10, İP-4.3).
///
/// Yalnız servis personeli / süper kullanıcı oturumunda ve pano bağlıyken görünür ([TemplateLogic.available]); servis
/// PIN oturumunda hiç çizilmez (sihirbaz bugünkü gibi). Seçim: site (ya da genel) → şablon → özet → "Panoya Uygula".
/// Uygulanınca röle listesi panodan (şablon değerleriyle) yeniden okunur; yalnız test kalır.
class TemplateApplyCard extends StatelessWidget {
  const TemplateApplyCard({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final t = c.template;
    if (!t.available || !c.conn.ready) return const SizedBox.shrink();
    final busy = t.busy || c.isBusy;
    final problem = t.problem;
    final applied = t.applied;
    return SetupCard(
      key: const Key('template_card'),
      accent: t.supported == false ? SetupColors.warn : (applied != null ? SetupColors.ok : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SetupMiniOrb(family: AppFamilies.violet, icon: Icons.dashboard_customize_rounded, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Şablon uygula (isteğe bağlı)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _boardLine(context, t),
          if (applied != null)
            SetupInfoRow(
              key: const Key('template_applied_info'),
              icon: Icons.check_circle_rounded,
              color: SetupColors.ok,
              text: '"${applied.name}" (v${applied.version}) panoya yazıldı. Röle adları ve türleri şablondan geldi; '
                  'şimdi yalnız test kalır.',
            ),
          if (t.recordFailed)
            const SetupInfoRow(
              key: Key('template_record_failed'),
              icon: Icons.cloud_off_rounded,
              color: SetupColors.warn,
              text: 'Yazım sunucuya kaydedilemedi (internet?). Panodaki şablon geçerlidir.',
            ),
          if (t.supported == false)
            const SetupInfoRow(
              key: Key('template_unsupported'),
              icon: Icons.system_update_rounded,
              color: SetupColors.warn,
              text: 'Pano yazılımı şablonu desteklemiyor, v1.3.0\'a güncelleyin. Şablonsuz devam edebilirsiniz.',
            ),
          ..._body(context, t, busy),
          if (problem != null)
            SetupProblemBox(
              key: const Key('template_problem'),
              problem: problem,
              onRetry: t.canRetry ? () => t.retry() : null,
              retrySecondary: true,
            ),
        ],
      ),
    );
  }

  Widget _boardLine(BuildContext context, TemplateLogic t) {
    final ref = controller.relays.boardTemplate;
    final board = t.board;
    final id = board?.templateId ?? ref?.id;
    if (id == null) {
      return Text(
        'Hazır bir site/daire şablonu seçerseniz röle, panjur, giriş ve güvenlik ayarları panoya tek seferde yazılır. '
        'Seçmezseniz kuruluma bugünkü gibi devam edin.',
        style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
      );
    }
    final version = (board?.templateId != null ? board!.version : ref?.version) ?? 0;
    return SetupInfoRow(
      key: const Key('template_board_current'),
      icon: Icons.memory_rounded,
      color: SetupColors.info,
      text: 'Panoda yüklü şablon: ${templateDisplayName(id, t)} (v$version)',
    );
  }

  /// Şablon kimliğinin okunur adı: bu oturumda görülen şablonun adı, yoksa kısa kimlik.
  static String templateDisplayName(String id, TemplateLogic t) {
    final applied = t.applied;
    if (applied != null && (applied.templateId == id || applied.id == id)) return '"${applied.name}"';
    for (final s in t.templates) {
      if (s.id == id) return '"${s.name}"';
    }
    return id.length > 8 ? '${id.substring(0, 8)}…' : id;
  }

  List<Widget> _body(BuildContext context, TemplateLogic t, bool busy) {
    switch (t.stage) {
      case TemplateStage.closed:
        if (t.supported == false) return const <Widget>[];
        return <Widget>[
          const SizedBox(height: 10),
          SetupSecondaryButton(
            key: const Key('btn_template_open'),
            label: t.applied == null ? 'Şablon Seç' : 'Başka Şablon Seç',
            icon: Icons.dashboard_customize_rounded,
            family: AppFamilies.violet,
            busy: t.busy,
            onPressed: busy ? null : () => t.open(),
          ),
        ];
      case TemplateStage.site:
        return <Widget>[
          _stageTitle(context, 'Site seçin'),
          _ChoiceRow(
            key: const Key('template_site_global'),
            icon: Icons.public_rounded,
            title: 'Genel (standart) şablonlar',
            subtitle: 'Herhangi bir siteye bağlı olmayan şablonlar',
            onTap: busy ? null : () => t.chooseSite(null),
          ),
          for (final s in t.sites)
            _ChoiceRow(
              key: Key('template_site_${s.id}'),
              icon: Icons.apartment_rounded,
              title: s.name,
              subtitle: s.place.isEmpty ? null : s.place,
              onTap: busy ? null : () => t.chooseSite(s),
            ),
          _backRow(t, busy, label: 'Vazgeç'),
        ];
      case TemplateStage.template:
        return <Widget>[
          _stageTitle(context, t.globalChosen ? 'Genel şablonlar' : (t.site?.name ?? 'Şablonlar')),
          if (t.templates.isEmpty)
            const SetupInfoRow(
              key: Key('template_list_empty'),
              icon: Icons.info_outline_rounded,
              color: SetupColors.info,
              text: 'Bu seçimde şablon yok. Şablonlar servis yazılımında oluşturulur.',
            ),
          for (final s in t.templates)
            _ChoiceRow(
              key: Key('template_item_${s.id}'),
              icon: Icons.description_outlined,
              title: s.name,
              subtitle: <String>[if (s.flatType.isNotEmpty) s.flatType, 'v${s.currentVersion}'].join(' · '),
              onTap: busy ? null : () => t.chooseTemplate(s),
            ),
          _backRow(t, busy),
        ];
      case TemplateStage.preview:
        final selected = t.selected;
        if (selected == null) return const <Widget>[];
        return <Widget>[
          _stageTitle(context, '${selected.name} (v${selected.version})'),
          _PreviewPills(preview: selected.preview),
          const SizedBox(height: 8),
          const SetupInfoRow(
            icon: Icons.info_outline_rounded,
            color: SetupColors.info,
            text: 'Uygulanınca panodaki röle, panjur, giriş ve güvenlik ayarları bu şablonla değişir; 7-9. adımlardaki '
                'test ilerlemesi sıfırlanır.',
          ),
          const SizedBox(height: 10),
          SetupPrimaryButton(
            key: const Key('btn_template_apply'),
            label: 'Panoya Uygula',
            icon: Icons.upload_rounded,
            busy: t.busy,
            onPressed: busy ? null : () => t.apply(),
          ),
          _backRow(t, busy),
        ];
    }
  }

  Widget _stageTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(
          text,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
        ),
      );

  Widget _backRow(TemplateLogic t, bool busy, {String label = 'Geri'}) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('btn_template_back'),
          style: setupInlineActionStyle(),
          onPressed: busy ? null : t.back,
          child: Text(label),
        ),
      );
}

/// Önizleme sayıları (röle / panjur / giriş / güvenlik) ayrı haplar olarak; dar ekranda alta sarar.
class _PreviewPills extends StatelessWidget {
  const _PreviewPills({required this.preview});

  final TemplatePreview preview;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    return Wrap(
      key: const Key('template_preview'),
      spacing: 8,
      runSpacing: 6,
      children: [
        if (p.flatType.isNotEmpty) ServiceStatusPill(label: p.flatType, color: AppFamilies.violet.base),
        ServiceStatusPill(label: '${p.lights} lamba/priz', color: AppFamilies.amber.base),
        ServiceStatusPill(label: '${p.shutters} panjur', color: AppFamilies.sky.base),
        if (p.impulses > 0) ServiceStatusPill(label: '${p.impulses} darbe', color: AppFamilies.amber.base),
        ServiceStatusPill(label: '${p.inputs} giriş', color: AppFamilies.slate.base),
        ServiceStatusPill(
          label: '${p.sensors} sensör, ${p.actuators} güvenlik cihazı',
          color: p.hasSafety ? AppFamilies.rose.base : AppFamilies.slate.base,
        ),
        if (p.dimmers > 0) ServiceStatusPill(label: '${p.dimmers} dimmer', color: AppFamilies.amber.base),
        if (p.extChannels > 0) ServiceStatusPill(label: 'Ek modül ${p.extChannels} kanal', color: AppFamilies.slate.base),
      ],
    );
  }
}

/// Seçim satırı: simge + başlık (+ alt satır) + ok; tüm satır ≥ 48 dp dokunma hedefi, metin sarar (kırpılmaz).
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({super.key, required this.icon, required this.title, this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                Icon(icon, size: 22, color: SetupColors.muted(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: SetupColors.text(context)),
                      ),
                      if (sub != null && sub.isNotEmpty)
                        Text(sub, style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context))),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: SetupColors.muted(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
