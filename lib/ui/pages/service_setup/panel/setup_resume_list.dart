import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../common/confirm_dialogs.dart';
import '../service_target.dart';
import '../setup_steps.dart';
import '../setup_store.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';

/// "Devam eden kurulumlar": bu telefonda **bu teknisyene / bu oturuma** ait yarım kalmış kurulumlar.
///
/// Kayıt cihaz bazlıdır; bir kayda dokunmak sihirbazı kaldığı adımdan açar. Başka teknisyenin ya da
/// başka bir PIN oturumunun kayıtları [SetupStore.list] tarafından zaten süzülür.
class SetupResumeList extends StatefulWidget {
  const SetupResumeList({
    super.key,
    required this.access,
    required this.onOpen,
    this.store,
  });

  final ServiceSetupAccess access;
  final SetupStore? store;

  /// Kayıtla sihirbazı açar (dönüşte liste yenilenir).
  final Future<void> Function(SetupProgressRecord record) onOpen;

  @override
  State<SetupResumeList> createState() => _SetupResumeListState();
}

class _SetupResumeListState extends State<SetupResumeList> {
  static const Duration _readTimeout = Duration(seconds: 10);

  late final SetupStore _store = widget.store ?? SetupStore();
  List<SetupProgressRecord>? _records;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final list = await _store.list(widget.access.ownerKey).timeout(_readTimeout);
      if (!mounted) return;
      setState(() => _records = list);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _records ??= const <SetupProgressRecord>[];
      });
    }
  }

  Future<void> _discard(SetupProgressRecord record) async {
    final ok = await showSimpleConfirm(
      context,
      title: 'Kurulum kaydı silinsin mi?',
      message: '${record.deviceUuid} için bu telefondaki kurulum ilerlemesi silinir. Cihaz daireye bağlandıysa '
          'sunucudaki bağlantı kalır; yalnızca adım ilerlemesi silinir.',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _store.delete(record.ownerKey, record.deviceUuid);
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    return Column(
      key: const Key('setup_resume_list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SetupSectionTitle('Devam eden kurulumlar'),
        if (records == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator(key: Key('resume_loading'))),
          )
        else ...[
          if (_failed)
            SetupCard(
              key: const Key('resume_error'),
              accent: SetupColors.error,
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Kayıtlı kurulumlar okunamadı.'),
                  ),
                  TextButton(
                    key: const Key('btn_resume_retry'),
                    onPressed: _load,
                    child: const Text('Tekrar dene'),
                  ),
                ],
              ),
            ),
          if (records.isEmpty && !_failed)
            SetupCard(
              key: const Key('resume_empty'),
              child: Text(
                'Yarım kalan kurulum yok. "Yeni Kurulum Başlat" ile başlayabilirsiniz.',
                style: TextStyle(color: SetupColors.muted(context), height: 1.35),
              ),
            ),
          for (final record in records) _RecordCard(record: record, onOpen: widget.onOpen, onDiscard: _discard),
        ],
      ],
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record, required this.onOpen, required this.onDiscard});

  final SetupProgressRecord record;
  final Future<void> Function(SetupProgressRecord record) onOpen;
  final Future<void> Function(SetupProgressRecord record) onDiscard;

  @override
  Widget build(BuildContext context) {
    final step = record.currentStep;
    final info = SetupSteps.of(step);
    final title = record.homeName.isEmpty ? record.deviceUuid : record.homeName;
    final updated = DateFormat('dd.MM.yyyy HH:mm').format(record.updatedAt.toLocal());
    return SetupCard(
      key: Key('card_setup_${record.deviceUuid}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 2),
          Text(
            record.deviceUuid,
            style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: SetupColors.muted(context)),
          ),
          const SizedBox(height: 8),
          Text(
            'Kaldığı yer: Adım $step / ${SetupSteps.total} - ${info.title}',
            style: TextStyle(fontSize: 13.5, color: SetupColors.text(context)),
          ),
          if (record.customerHint.isNotEmpty)
            Text('Müşteri: ${record.customerHint}', style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context))),
          Text('Son işlem: $updated', style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context))),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: ((step - 1) / SetupSteps.total).clamp(0.0, 1.0),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    key: Key('btn_resume_${record.deviceUuid}'),
                    onPressed: () => onOpen(record),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Devam Et'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('btn_discard_setup_${record.deviceUuid}'),
                tooltip: 'Kaydı sil',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => onDiscard(record),
                icon: const Icon(Icons.delete_outline_rounded, color: SetupColors.error),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
