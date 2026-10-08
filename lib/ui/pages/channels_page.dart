import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/cloud_models.dart';
import '../../services/automation_state.dart';
import '../../utils/friendly_error.dart';
import '../common/app_dialogs.dart';
import '../common/confirm_dialogs.dart' show AuthDialogActions, AuthDialogShell, authPrimaryLabel, authSecondaryLabel;
import '../common/inline_message.dart';
import '../theme/app_theme.dart';
import '../theme/feature_accent.dart';
import '../theme/tokens.dart';
import '../widgets/neon_app_bar.dart';
import '../widgets/settings/accent_button.dart';
import '../widgets/settings/settings_card.dart';
import '../widgets/surface_card.dart';

/// "Kanallar ve Panjurlar" (bireysel-10): kendi kuran ev sahibi (ve personel / servis oturumu / süper: `canCalibrate`)
/// kanal adını ve odasını, lamba <-> priz tipini ve panjur çiftinin süresini değiştirir (`PUT /homes/:homeId/endpoints/:id`).
///
/// * Güvenlik eylemcileri (vana, siren, fan) listelenmez; panjur çifti tek satırdır (birincil YUKARI satırı).
/// * Tip yalnız lamba <-> priz değişir (panjur / darbe donanım anlamlıdır; sunucu da reddeder).
/// * Panjur süresi panoya iletilir: pano çevrimdışıyken alan pasif ve açıklamalıdır; sunucu `409 NOT_APPLIED` (panjur hareket
///   halinde) ve `409 TYPE_CHANGED` (yerleşim eşitlemesi kanalı değiştirdi: liste yenilenir) ayrı ele alınır.
class ChannelsPage extends StatelessWidget {
  const ChannelsPage({super.key});

  /// Yerleşim eşitlemesi panonun bildirdiği adı yazabilir (WP-L).
  static const String syncNote = 'Panonun bildirdiği ad değişirse yerleşim eşitlemesi adınızı güncelleyebilir.';

  @override
  Widget build(BuildContext context) {
    final endpoints = context.select<AutomationState, List<EndpointModel>>((s) => s.cloudEndpoints);
    final items = <EndpointModel>[
      for (final e in endpoints)
        if (!e.isActuator && (!e.isShutter || e.isPrimaryShutterRow)) e,
    ];
    return Scaffold(
      appBar: const NeonAppBar(title: 'Kanallar ve Panjurlar', feature: AppFeature.settings, icon: Icons.tune_rounded),
      body: ListView(
        key: const Key('view_channels'),
        padding: const EdgeInsets.all(16),
        children: [
          const InlineMessage.info(syncNote, key: Key('channels_sync_note')),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Text(
              'Bu dairede düzenlenecek kanal yok.',
              key: const Key('channels_empty'),
              style: TextStyle(color: AppTheme.getTextMuted(context)),
            ),
          for (final ep in items) _ChannelTile(endpoint: ep),
        ],
      ),
    );
  }
}

/// Cihaz ayarlarındaki giriş kartı (bulut kipi + `canCalibrate`).
class ChannelsCard extends StatelessWidget {
  const ChannelsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('card_channels'),
      child: SettingsCard(
        icon: Icons.tune_rounded,
        title: 'Kanallar ve Panjurlar',
        accent: AppFeature.settings.accentFamily.base,
        children: [
          const CardCaption('Kanal adlarını ve odalarını, lamba / priz tipini ve panjur sürelerini düzenleyin.'),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_open_channels'),
              onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const ChannelsPage())),
              icon: Icon(Icons.edit_note_rounded, size: accentIconSize(context)),
              label: const Text('Kanalları Düzenle', style: TextStyle(fontWeight: FontWeight.bold)),
              style: accentOutlinedButtonStyle(context, AppFeature.settings.accentFamily),
            ),
          ),
        ],
      ),
    );
  }
}

String _typeLabel(EndpointModel e) => switch (e.endpointType) {
      'light' => 'Lamba',
      'plug' => 'Priz',
      'shutter' => 'Panjur',
      'impulse' => 'Darbe rölesi',
      _ => e.endpointType,
    };

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.endpoint});

  final EndpointModel endpoint;

  @override
  Widget build(BuildContext context) {
    final e = endpoint;
    final muted = AppTheme.getTextMuted(context);
    final detail = <String>[
      _typeLabel(e),
      e.room,
      e.isShutter ? 'Panjur ${e.pair} • ${e.shutterDurationSec} sn' : 'Kanal ${e.channel}',
    ].join(' • ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SurfaceCard(
        key: Key('channel_${e.id}'),
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.name, style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.getTextPrimary(context))),
                  const SizedBox(height: 2),
                  Text(detail, style: TextStyle(fontSize: AppText.caption, color: muted)),
                ],
              ),
            ),
            IconButton(
              key: Key('btn_edit_channel_${e.id}'),
              tooltip: 'Düzenle',
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => _ChannelEditDialog.show(context, e),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelEditDialog extends StatefulWidget {
  const _ChannelEditDialog({required this.endpoint});

  final EndpointModel endpoint;

  static Future<void> show(BuildContext context, EndpointModel endpoint) {
    final state = context.read<AutomationState>();
    return showAppDialog<void>(
      context,
      barrierDismissible: false,
      builder: (_) => ChangeNotifierProvider<AutomationState>.value(value: state, child: _ChannelEditDialog(endpoint: endpoint)),
    );
  }

  @override
  State<_ChannelEditDialog> createState() => _ChannelEditDialogState();
}

class _ChannelEditDialogState extends State<_ChannelEditDialog> {
  static const String notAppliedMessage = 'Panjur hareket halinde; durdurup yeniden deneyin.';

  late final TextEditingController _name = TextEditingController(text: widget.endpoint.name);
  late final TextEditingController _room = TextEditingController(text: widget.endpoint.room);
  late final TextEditingController _duration = TextEditingController(text: '${widget.endpoint.shutterDurationSec}');
  late String _type = widget.endpoint.endpointType;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _room.dispose();
    _duration.dispose();
    super.dispose();
  }

  /// Panjur süresi panoya iletilir: pano çevrimiçi olmalı (uç noktanın bildirdiği; yoksa canlı varlık bilgisi).
  bool _boardOnline(AutomationState state) => widget.endpoint.deviceOnline ?? state.deviceOnline;

  Future<void> _save() async {
    if (_busy) return;
    final state = context.read<AutomationState>();
    final ep = widget.endpoint;
    final name = _name.text.trim();
    final room = _room.text.trim();
    if (name.isEmpty || name.length > 100) {
      setState(() => _error = 'Ad 1 ile 100 karakter arasında olmalı.');
      return;
    }
    if (room.isEmpty || room.length > 50) {
      setState(() => _error = 'Oda 1 ile 50 karakter arasında olmalı.');
      return;
    }
    int? duration;
    if (ep.isShutter && _boardOnline(state)) {
      final d = int.tryParse(_duration.text.trim());
      if (d == null || d < 1 || d > 300) {
        setState(() => _error = 'Panjur süresi 1 ile 300 saniye arasında olmalıdır.');
        return;
      }
      if (d != ep.shutterDurationSec) duration = d;
    }
    final newName = name != ep.name ? name : null;
    final newRoom = room != ep.room ? room : null;
    final newType = _type != ep.endpointType ? _type : null;
    if (newName == null && newRoom == null && newType == null && duration == null) {
      Navigator.of(context).pop();
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.updateEndpoint(
        endpointId: ep.id,
        name: newName,
        room: newRoom,
        type: newType,
        shutterDurationSec: duration,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger?.showSnackBar(const SnackBar(content: Text('Kanal kaydedildi.'), behavior: SnackBarBehavior.floating));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409 && e.reason == 'TYPE_CHANGED') {
        // Yerleşim eşitlemesi kanalı değiştirdi: liste yenilenir, kullanıcı güncel satırdan yeniden dener.
        unawaited(state.fetchEndpoints());
        Navigator.of(context).pop();
        messenger?.showSnackBar(
          const SnackBar(content: Text('Kanal tipi değişti; liste yenilendi.'), behavior: SnackBarBehavior.floating),
        );
        return;
      }
      setState(() {
        _busy = false;
        _error = e.statusCode == 409 && e.reason == 'NOT_APPLIED' ? notAppliedMessage : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e, fallback: 'Kanal kaydedilemedi. Lütfen tekrar deneyin.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ep = widget.endpoint;
    final state = context.read<AutomationState>();
    final online = _boardOnline(state);
    final cosmetic = ep.isLight || ep.isPlug;
    return AuthDialogShell(
      key: const Key('channel_edit_dialog'),
      icon: Icons.edit_note_rounded,
      family: AppFeature.settings.accentFamily,
      title: ep.isShutter ? 'Panjur ${ep.pair}' : 'Kanal ${ep.channel}',
      subtitle: _typeLabel(ep),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('field_channel_name'),
            controller: _name,
            enabled: !_busy,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'Ad'),
          ),
          TextField(
            key: const Key('field_channel_room'),
            controller: _room,
            enabled: !_busy,
            maxLength: 50,
            decoration: const InputDecoration(labelText: 'Oda'),
          ),
          if (cosmetic) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('chip_type_light'),
                  label: const Text('Lamba'),
                  selected: _type == 'light',
                  onSelected: _busy ? null : (_) => setState(() => _type = 'light'),
                ),
                ChoiceChip(
                  key: const Key('chip_type_plug'),
                  label: const Text('Priz'),
                  selected: _type == 'plug',
                  onSelected: _busy ? null : (_) => setState(() => _type = 'plug'),
                ),
              ],
            ),
          ],
          if (ep.isShutter) ...[
            const SizedBox(height: 8),
            TextField(
              key: const Key('field_channel_duration'),
              controller: _duration,
              enabled: online && !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Panjur süresi (sn, 1-300)',
                helperText: online
                    ? 'Süre panoya iletilir; panjur hareket halindeyken uygulanmaz.'
                    : 'Pano çevrimdışı: panjur süresi yalnız pano çevrimiçiyken değiştirilebilir.',
                helperMaxLines: 3,
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            InlineMessage.error(_error!, key: const Key('channel_edit_error')),
          ],
        ],
      ),
      actions: AuthDialogActions(
        primaryLabel: 'Kaydet',
        primary: ElevatedButton(
          key: const Key('btn_channel_save'),
          onPressed: _busy ? null : _save,
          child: authPrimaryLabel('Kaydet'),
        ),
        secondaryLabel: 'Vazgeç',
        secondary: TextButton(
          key: const Key('btn_channel_cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: authSecondaryLabel(context, 'Vazgeç'),
        ),
      ),
    );
  }
}
