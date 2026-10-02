import '../../../../config/app_config.dart';
import '../../../../models/api_models.dart';
import '../../../../models/cloud_models.dart';
import '../../../../models/json_utils.dart';
import '../../../../utils/qr_claim_parser.dart';
import '../../../../utils/qr_router.dart';
import '../service_target.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';

/// Cihazın sunucudaki envanter durumu (kuruluma uygunluk).
enum InventoryCheck {
  /// Henüz kontrol edilmedi.
  notChecked,

  /// Envanterde bulundu ve `IN_STOCK` (kuruluma uygun).
  inStock,

  /// Bu hesapla envanter satırı görünmüyor (servis personeli yalnız kendi stokunu görür):
  /// kesin kontrol, müşteri kodu istenirken sunucu tarafında yapılır.
  notVisible,

  /// Cihaz kuruluma uygun değil (askıda / iptal / zaten bir daireye bağlı).
  blocked,
}

/// Adım 2 - Cihazı Tanı.
///
/// * Personel / süper kullanıcı: etiket karekodu (`QrRouter` -> `QrClaim`) ya da elle UID + PIN; sunucu
///   envanterinde `IN_STOCK` mi kontrol edilir (görülebiliyorsa).
/// * Geçici servis (PIN) oturumu: claim yoktur; cihaz dairedeki kayıtlı panolar arasından seçilir ve
///   sunucu cihazın bu dairede olduğunu doğrular.
///
/// Kurulum PIN'i yalnızca **bellekte** tutulur (kalıcı kayıt/log/rapor yok); claim başarısında silinir.
class IdentifyLogic extends SetupLogic {
  IdentifyLogic(super.ctx);

  @override
  int get number => SetupSteps.identify;

  String? _uid;
  String? _pin;
  InventoryCheck _inventory = InventoryCheck.notChecked;
  InventoryDeviceModel? _inventoryDevice;

  // Geçici servis oturumu
  List<DeviceInfo> _homeDevices = const <DeviceInfo>[];
  bool _devicesLoaded = false;
  String? _selectedDevice;

  String? get uid => _uid;
  bool get hasPin => _pin != null;
  InventoryCheck get inventory => _inventory;
  InventoryDeviceModel? get inventoryDevice => _inventoryDevice;
  List<DeviceInfo> get homeDevices => _homeDevices;
  bool get devicesLoaded => _devicesLoaded;
  String? get selectedDevice => _selectedDevice;

  /// Claim için kurulum PIN'i (yalnızca [ClaimLogic] okur).
  String? get pinForClaim => _pin;

  /// Kurulum ağı (AP) adresi: kurulum bu adresle başlar.
  static String get apHost => AppConfig.current.deviceApHost;

  @override
  bool get isComplete {
    if (ctx.access.isPinSession) return _selectedDevice != null && ctx.target != null;
    // Sunucu kontrolü başarısız olduysa (ağ hatası) adım tamamlanmış sayılmaz.
    return _uid != null &&
        _pin != null &&
        (_inventory == InventoryCheck.inStock || _inventory == InventoryCheck.notVisible);
  }

  /// Etiket karekodundan okunan ham metin.
  Future<bool> acceptLabel(String? raw) async {
    final payload = QrRouter.route(raw);
    switch (payload) {
      case QrClaim(:final uid, :final pin):
        return _accept(uid, pin);
      case QrWifi():
        _fail('Bu bir Wi-Fi karekodu',
            'Okuttuğunuz karekod bir Wi-Fi bilgisi. Cihaz etiketinde değil, modem etiketinde olabilir.',
            'Pano üzerindeki etiketin karekodunu okutun. Ev Wi-Fi bilgisi 5. adımda istenecek.');
        return false;
      case QrInvite() || QrTransfer():
        _fail('Bu bir cihaz etiketi değil',
            'Okuttuğunuz karekod bir davet veya daire devri kodu.',
            'Pano üzerindeki etiketin karekodunu okutun.');
        return false;
      case QrUnknown(:final message):
        _fail('Karekod tanınmadı', message,
            'Etiketin karekodunu düzgün ışıkta tekrar okutun ya da seri numarasını ve PIN\'i elle yazın.');
        return false;
    }
  }

  /// Elle girilen seri numarası ve PIN.
  Future<bool> acceptManual(String uidText, String pinText) {
    final uid = QrClaimParser.normalizeUid(uidText);
    if (uid == null) {
      _fail('Seri numarası geçersiz',
          'Seri numarası AHBU- ile başlamalı (ör. AHBU-S3-A1B2C3).',
          'Etiketteki "CİHAZ SERİ NO" satırını aynen yazın.');
      return Future<bool>.value(false);
    }
    if (!QrClaimParser.isValidPin(pinText)) {
      _fail('PIN geçersiz', 'Kurulum PIN\'i tam 6 rakam olmalıdır.',
          'Etiketteki "KURULUM PIN" satırını (6 rakam) yazın.');
      return Future<bool>.value(false);
    }
    return _accept(uid, pinText.trim());
  }

  void _fail(String title, String why, String todo) {
    fail(SetupProblem(kind: SetupProblemKind.validation, title: title, why: why, todo: todo, retryable: false));
  }

  Future<bool> _accept(String uid, String pin) async {
    _uid = uid;
    _pin = pin;
    _inventory = InventoryCheck.notChecked;
    _inventoryDevice = null;
    clearProblem();
    final ok = await checkInventory();
    if (!ok && _inventory == InventoryCheck.blocked) {
      // Uygun olmayan cihazın PIN'i bellekte tutulmaz.
      _pin = null;
    }
    ctx.notify();
    return ok;
  }

  /// Cihazın envanter durumunu sunucudan kontrol eder (bu hesap görebiliyorsa).
  Future<bool> checkInventory() => run('Cihaz sunucuda kontrol ediliyor', () async {
        final uid = _uid;
        if (uid == null) return;
        _inventory = InventoryCheck.notChecked;
        _inventoryDevice = null;
        if (!ctx.state.capabilities.canViewInventory) {
          _inventory = InventoryCheck.notVisible;
          return;
        }
        final res = await ctx.cloud.fetchDeviceInventory(search: uid, limit: 20);
        final items = parseList(res['items'], InventoryDeviceModel.fromJson, label: 'Inventory');
        InventoryDeviceModel? match;
        for (final item in items) {
          if (item.deviceUuid.toUpperCase() == uid) match = item;
        }
        if (match == null) {
          if (ctx.access.isSuperUser) {
            // Süper kullanıcı tüm envanteri görür: bulunmayan cihaz gerçekten kayıtlı değildir.
            _inventory = InventoryCheck.blocked;
            throw const SetupProblemException(SetupProblem(
              kind: SetupProblemKind.notFound,
              title: 'Bu cihaz envanterde kayıtlı değil',
              why: 'Etiketteki seri numarası sunucudaki cihaz kayıtlarında yok.',
              todo: 'Etiketi yeniden okutun. Cihaz fabrika aracıyla envantere kaydedilmemiş olabilir.',
              retryable: false,
            ));
          }
          _inventory = InventoryCheck.notVisible;
          return;
        }
        _inventoryDevice = match;
        if (match.isInStock) {
          _inventory = InventoryCheck.inStock;
          return;
        }
        _inventory = InventoryCheck.blocked;
        throw SetupProblemException(blockedProblem(match));
      });

  static SetupProblem blockedProblem(InventoryDeviceModel device) {
    if (device.isSuspended) {
      return const SetupProblem(
        kind: SetupProblemKind.forbidden,
        title: 'Bu cihaz askıya alınmış',
        why: 'Yönetici bu cihazı askıya almış; kurulum yapılamaz.',
        todo: 'Yöneticiden cihazı stoğa almasını isteyin ya da başka bir cihaz kullanın.',
        retryable: false,
      );
    }
    if (device.isRevoked) {
      return const SetupProblem(
        kind: SetupProblemKind.forbidden,
        title: 'Bu cihaz iptal edilmiş',
        why: 'Cihaz arıza veya iade gerekçesiyle iptal edilmiş.',
        todo: 'Bu pano kurulamaz. Başka bir cihaz kullanın veya yetkili servisle iletişime geçin.',
        retryable: false,
      );
    }
    final home = device.claimedHomeName;
    return SetupProblem(
      kind: SetupProblemKind.conflict,
      title: 'Bu cihaz zaten bir daireye bağlı',
      why: home == null
          ? 'Cihaz daha önce sahiplenilmiş.'
          : 'Cihaz daha önce "$home" dairesine bağlanmış.',
      todo: 'Yanlış etiketi okutmuş olabilirsiniz; etiketi kontrol edin. Cihaz gerçekten başka bir daireden alındıysa '
          'önce yöneticinin acil sıfırlama yapması gerekir.',
      retryable: false,
    );
  }

  /// Claim, PIN'i reddettiğinde: PIN bellekten silinir (yeniden girilmeli).
  void clearPin() {
    _pin = null;
    ctx.notify();
  }

  /// Claim başarıyla bitince gizli veriler silinir.
  void clearSecrets() {
    _pin = null;
  }

  /// Etiketi baştan okutmak için.
  void reset() {
    _uid = null;
    _pin = null;
    _inventory = InventoryCheck.notChecked;
    _inventoryDevice = null;
    clearProblem();
    ctx.notify();
  }

  // ---------------------------------------------------------------------------
  // Geçici servis oturumu: dairedeki panolar
  // ---------------------------------------------------------------------------

  Future<bool> loadHomeDevices() => run('Dairedeki panolar alınıyor', () async {
        final homeId = ctx.access.sessionHomeId;
        if (homeId == null) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.validation,
            title: 'Servis oturumunun dairesi bilinmiyor',
            why: 'Oturum bilgisinde daire kimliği yok.',
            todo: 'Servis PIN\'i ile yeniden giriş yapın.',
            retryable: false,
          ));
        }
        final devices = await ctx.cloud.devices(homeId);
        _homeDevices = devices;
        _devicesLoaded = true;
        if (devices.isEmpty) {
          throw const SetupProblemException(SetupProblem(
            kind: SetupProblemKind.notFound,
            title: 'Bu dairede kayıtlı pano yok',
            why: 'Sunucuda bu daireye bağlı bir pano bulunamadı.',
            todo: 'Ev sahibine cihazı önce kendi hesabıyla eşlemesini söyleyin ya da yetkili servisle iletişime geçin.',
          ));
        }
        if (devices.length == 1 && _selectedDevice == null) {
          _choose(devices.single.deviceUuid);
        }
      });

  /// Dairedeki panolardan birini kurulum hedefi olarak seçer.
  bool selectHomeDevice(String deviceUuid) {
    final known = _homeDevices.any((d) => d.deviceUuid.toUpperCase() == deviceUuid.toUpperCase());
    if (!known) return false;
    _choose(deviceUuid);
    ctx.notify();
    ctx.persist();
    return true;
  }

  void _choose(String deviceUuid) {
    final uid = QrClaimParser.normalizeUid(deviceUuid) ?? deviceUuid.toUpperCase();
    _selectedDevice = uid;
    _uid = uid;
    ctx.target = ServiceTarget(
      homeId: ctx.access.sessionHomeId!,
      deviceUuid: uid,
      homeName: ctx.access.sessionHomeName ?? '',
      ip: apHost,
    );
  }

  /// Mevcut cihazda kurulum (devam / pano değişimi): hedef dışarıdan verilir.
  void adoptTarget(ServiceTarget target) {
    ctx.target = target;
    _uid = target.deviceUuid;
    _selectedDevice = target.deviceUuid;
  }
}
