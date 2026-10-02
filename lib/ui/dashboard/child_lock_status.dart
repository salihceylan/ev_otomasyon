import '../../services/automation_state.dart';
import 'labels.dart';

/// Çocuk kilidinin arayüz görünümü (değer eşitliği vardır: `context.select` ile kullanılır).
typedef ChildLockVm = ({
  ChildLockStatus status,
  bool pending,
  bool stale,
  DateTime? updatedAt,
  bool canChange,
  bool awaitingDevices,
  int offlineDeviceCount,
});

/// Durumdan çocuk kilidi görünümünü türetir. **Bilinmeyen durum "kilit kapalı" değildir**
/// ([ChildLockStatus.unknown]); beklenen (uygulanıyor) ve bayat ("son bilinen") durumlar ayrıdır.
ChildLockVm childLockVmOf(AutomationState s) => (
      status: s.childLockStatus,
      pending: s.childLockPending,
      stale: s.childLockStale,
      updatedAt: s.childLockUpdatedAt,
      canChange: s.capabilities.canChangeChildLock,
      awaitingDevices: s.childLockAwaitingDevices,
      offlineDeviceCount: s.childLockOfflineDevices.length,
    );

/// Kullanıcıya gösterilen durum metni (jargon yok):
///
/// * `unknown` -> "Durum alınıyor…"
/// * bekleyen komut -> "Uygulanıyor…"
/// * `locked` -> "Kilitli: duvar anahtarları devre dışı"
/// * `unlocked` -> "Kilit kapalı: duvar anahtarları serbest"
/// * `mixed` -> "Panolar farklı durumda"
/// * bayat bilgi -> "Son bilinen: Kilitli (14:32)"
String childLockStatusLabel(ChildLockVm vm, {DateTime? now}) {
  if (vm.pending) return 'Uygulanıyor…';
  switch (vm.status) {
    case ChildLockStatus.unknown:
      return 'Durum alınıyor…';
    case ChildLockStatus.mixed:
      return 'Panolar farklı durumda';
    case ChildLockStatus.locked:
    case ChildLockStatus.unlocked:
      final locked = vm.status == ChildLockStatus.locked;
      if (vm.stale) {
        final when = vm.updatedAt;
        final suffix = when == null ? '' : ' (${formatWhen(when, now: now)})';
        return 'Son bilinen: ${locked ? 'Kilitli' : 'Kilit kapalı'}$suffix';
      }
      return locked
          ? 'Kilitli: duvar anahtarları devre dışı'
          : 'Kilit kapalı: duvar anahtarları serbest';
  }
}

/// Ekran okuyucuya duyurulan kısa durum cümlesi.
String childLockAnnouncement(ChildLockVm vm) {
  if (vm.pending) return 'Çocuk kilidi uygulanıyor.';
  switch (vm.status) {
    case ChildLockStatus.unknown:
      return 'Çocuk kilidi durumu alınıyor.';
    case ChildLockStatus.mixed:
      return 'Çocuk kilidi: panolar farklı durumda.';
    case ChildLockStatus.locked:
      return 'Çocuk kilidi etkin. Duvar anahtarları devre dışı.';
    case ChildLockStatus.unlocked:
      return 'Çocuk kilidi kapalı. Duvar anahtarları çalışıyor.';
  }
}
