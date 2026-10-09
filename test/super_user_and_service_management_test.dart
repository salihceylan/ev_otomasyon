import 'dart:async';

import 'package:ev_otomasyon/models/capabilities.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_management_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/admin_account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// Servis yönetimi (hesaplar): rol matrisi, dondurma korumaları, parola/yeniden doğrulama kuralları,
/// form doğrulaması, çift gönderim koruması, görünür hatalar ve sayfalama (davranış testleri).
///
/// Not: Süper yönetici çekmecesi ve gösterge paneli konsolu testleri bu dosyadan çıkarıldı; o ekranlar
/// WP-E1 paketinindir (test/ui/e1_*).

Map<String, dynamic> acct(
  String id,
  String name, {
  String role = 'user',
  bool active = true,
  String status = 'active',
  String? email,
  String? phone,
  String? notes,
}) =>
    <String, dynamic>{
      'id': id,
      'full_name': name,
      'email': email ?? '$id@ornek.test',
      'phone': phone,
      'role': role,
      'is_active': active,
      'account_status': active ? status : 'suspended',
      'admin_notes': notes,
    };

List<Map<String, dynamic>> defaultUsers() => <Map<String, dynamic>>[
      acct('super-1', 'Yönetici', role: 'super_user', email: 'yonetici@ornek.test'),
      acct('super-2', 'Diğer Süper', role: 'super_user'),
      acct('staff-1', 'Servis Ali', role: 'service_user', email: 'servis@ornek.test'),
      acct('cust-1', 'Müşteri Mehmet', status: 'pending_invite', phone: '05551112233'),
      acct('cust-2', 'Müşteri Zeynep'),
    ];

Future<ServiceHarness> mgmtEnv({String role = 'super', List<Map<String, dynamic>>? users}) async {
  final env = await serviceHarness(role: role, flush: () async {});
  env.cloud.adminUsers = users ?? defaultUsers();
  if (role == 'staff') {
    env.cloud.actorId = 'staff-1';
    env.cloud.actorIsSuper = false;
  }
  return env;
}

Future<void> openManagement(
  WidgetTester tester,
  ServiceHarness env, {
  int pageSize = 30,
  int tab = 0,
  Size size = const Size(900, 3200),
  double textScale = 1.0,
}) async {
  await pumpPage(tester, env, ServiceManagementPage(pageSize: pageSize, initialTabIndex: tab), size: size, textScale: textScale);
  await settle(tester);
}

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Future<void> openCreate(WidgetTester tester) async {
  await tapKey(tester, 'btn_add_account');
  await settle(tester);
}

void main() {
  group('AccountRules (istemci ön denetimi)', () {
    AdminAccount a(String id, {required GlobalRole role, bool active = true}) => AdminAccount(
          id: id,
          fullName: id,
          email: '$id@x.y',
          role: role,
          isActive: active,
          status: active ? AccountStatus.active : AccountStatus.suspended,
        );

    test('kullanıcı kendi hesabını donduramaz', () {
      final me = a('me', role: GlobalRole.superUser);
      expect(
        AccountRules.freezeBlock(target: me, currentUserId: 'me', loaded: [me, a('x', role: GlobalRole.superUser)], allSupersLoaded: true),
        FreezeBlock.self,
      );
    });

    test('tüm süperler yüklüyse ve başka aktif süper yoksa son aktif süper donduramaz', () {
      final last = a('last', role: GlobalRole.superUser);
      final frozen = a('frozen', role: GlobalRole.superUser, active: false);
      expect(
        AccountRules.freezeBlock(target: last, currentUserId: 'other', loaded: [last, frozen], allSupersLoaded: true),
        FreezeBlock.lastSuper,
      );
    });

    test('süperlerin tamamı yüklü değilse karar sunucuya bırakılır', () {
      final last = a('last', role: GlobalRole.superUser);
      expect(AccountRules.freezeBlock(target: last, currentUserId: 'other', loaded: [last], allSupersLoaded: false), isNull);
    });

    test('başka aktif süper varsa süper dondurulabilir; müşteri her zaman dondurulabilir', () {
      final s1 = a('s1', role: GlobalRole.superUser);
      final s2 = a('s2', role: GlobalRole.superUser);
      expect(AccountRules.freezeBlock(target: s1, currentUserId: 'me', loaded: [s1, s2], allSupersLoaded: true), isNull);
      final c = a('c', role: GlobalRole.user);
      expect(AccountRules.freezeBlock(target: c, currentUserId: 'me', loaded: [c], allSupersLoaded: true), isNull);
    });

    AdminAccount acc(String id, {required GlobalRole role, AccountStatus status = AccountStatus.active, bool active = true}) =>
        AdminAccount(id: id, fullName: id, email: '$id@x.y', role: role, isActive: active, status: status);

    group('roleChangeBlock / hardDeleteBlock', () {
      test('kendi hesabı: ikisi de engellenir', () {
        final me = acc('me', role: GlobalRole.superUser);
        final other = acc('o', role: GlobalRole.superUser);
        for (final block in [AccountRules.roleChangeBlock, AccountRules.hardDeleteBlock]) {
          expect(block(target: me, currentUserId: 'me', loaded: [me, other], allSupersLoaded: true), AccountBlock.self);
        }
      });

      test('silinmiş hesap: rol değiştirilemez (sunucu 409) ama kalıcı silinebilir', () {
        final gone = acc('gone', role: GlobalRole.user, status: AccountStatus.deleted, active: false);
        expect(
          AccountRules.roleChangeBlock(target: gone, currentUserId: 'me', loaded: [gone], allSupersLoaded: true),
          AccountBlock.deleted,
        );
        expect(AccountRules.hardDeleteBlock(target: gone, currentUserId: 'me', loaded: [gone], allSupersLoaded: true), isNull);
      });

      test('son aktif süper: rol düşürme ve kalıcı silme engellenir (donuk olsa bile); davet bekleyen süper "aktif" sayılmaz', () {
        final last = acc('last', role: GlobalRole.superUser);
        final frozenLast = acc('frozen-last', role: GlobalRole.superUser, active: false, status: AccountStatus.suspended);
        final pending = acc('pending', role: GlobalRole.superUser, status: AccountStatus.pendingInvite);
        final loaded = [last, frozenLast, pending];
        for (final block in [AccountRules.roleChangeBlock, AccountRules.hardDeleteBlock]) {
          expect(block(target: last, currentUserId: 'me', loaded: loaded, allSupersLoaded: true), AccountBlock.lastSuper);
          // Donuk süper de "başka aktif süper var mı" kuralına tabidir (sunucu hedefin durumuna bakmaz).
          expect(block(target: frozenLast, currentUserId: 'me', loaded: [frozenLast, pending], allSupersLoaded: true),
              AccountBlock.lastSuper);
          expect(block(target: frozenLast, currentUserId: 'me', loaded: loaded, allSupersLoaded: true), isNull,
              reason: 'başka aktif süper (last) var');
          // Tüm süperler yüklü değilse karar sunucuya bırakılır.
          expect(block(target: last, currentUserId: 'me', loaded: loaded, allSupersLoaded: false), isNull);
        }
      });

      test('başka aktif süper varsa ya da hedef süper değilse engel yok', () {
        final s1 = acc('s1', role: GlobalRole.superUser);
        final s2 = acc('s2', role: GlobalRole.superUser);
        final c = acc('c', role: GlobalRole.user);
        for (final block in [AccountRules.roleChangeBlock, AccountRules.hardDeleteBlock]) {
          expect(block(target: s1, currentUserId: 'me', loaded: [s1, s2], allSupersLoaded: true), isNull);
          expect(block(target: c, currentUserId: 'me', loaded: [c], allSupersLoaded: true), isNull);
        }
      });

      test('engel metinleri', () {
        expect(AccountRules.blockText(AccountBlock.deleted), 'Silinmiş hesabın rolü değiştirilemez.');
        expect(AccountRules.blockText(AccountBlock.lastSuper), contains('Son aktif süper yönetici'));
        expect(AccountRules.blockText(AccountBlock.self), contains('Kendi hesabınız'));
      });
    });

    test('assignableRoles: mevcut rol hariç, sunucunun kabul ettiği üç rolden', () {
      expect(AccountRules.assignableRoles(acc('c', role: GlobalRole.user)), [GlobalRole.superUser, GlobalRole.serviceUser]);
      expect(AccountRules.assignableRoles(acc('s', role: GlobalRole.serviceUser)), [GlobalRole.superUser, GlobalRole.user]);
      expect(AccountRules.assignableRoles(acc('u', role: GlobalRole.superUser)), [GlobalRole.serviceUser, GlobalRole.user]);
      expect(AccountRules.assignableRoles(acc('x', role: GlobalRole.unknown)), hasLength(3));
    });

    test('roleName: ekran adları sunucudaki üç rolle eşleşir', () {
      expect(AccountRules.roleName(GlobalRole.user), 'Müşteri');
      expect(AccountRules.roleName(GlobalRole.serviceUser), 'Servis sorumlusu');
      expect(AccountRules.roleName(GlobalRole.superUser), 'Süper yönetici');
    });
  });

  group('AdminAccount ayrıştırma', () {
    test('rol dizgisi büyük/küçük harf, boşluk ve eski adlarla normalleştirilir', () {
      expect(AdminAccount.tryParse(acct('1', 'A', role: 'Super_User'))!.role, GlobalRole.superUser);
      expect(AdminAccount.tryParse(acct('2', 'B', role: '  SERVICE_USER '))!.role, GlobalRole.serviceUser);
      expect(AdminAccount.tryParse(acct('3', 'C', role: 'installer'))!.role, GlobalRole.serviceUser);
      expect(AdminAccount.tryParse(acct('4', 'D', role: 'garip'))!.role, GlobalRole.unknown);
    });

    test('kimliği olmayan kayıt atılır; kimlik sayı gelirse metne çevrilir', () {
      expect(AdminAccount.tryParse(<String, dynamic>{'full_name': 'Kimliksiz'}), isNull);
      expect(AdminAccount.tryParse(<String, dynamic>{'id': 7, 'full_name': 'Yedi', 'role': 'user'})!.id, '7');
    });

    test('hesap durumu: dondurulmuş, davet bekliyor ve aktif ayrımı', () {
      expect(AdminAccount.tryParse(acct('1', 'A', active: false))!.statusLabel, 'Donduruldu');
      expect(AdminAccount.tryParse(acct('2', 'B', status: 'pending_invite'))!.statusLabel, 'Davet bekliyor');
      expect(AdminAccount.tryParse(acct('3', 'C'))!.statusLabel, 'Aktif');
    });

    test('silinmiş (anonimleştirilmiş) hesap ayrı durumdur: isDeleted ve "Silinmiş" etiketi', () {
      final gone = AdminAccount.tryParse(<String, dynamic>{...acct('9', 'Z'), 'is_active': false, 'account_status': 'deleted'})!;
      expect(gone.status, AccountStatus.deleted);
      expect(gone.isDeleted, isTrue);
      expect(gone.statusLabel, 'Silinmiş');
      expect(AdminAccount.tryParse(acct('8', 'Y'))!.isDeleted, isFalse);
    });
  });

  group('erişim (rol matrisi)', () {
    testWidgets('süper yönetici hesapları, sistem özetini ve Hesap Ekle düğmesini görür', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      expect(exists('card_account_super-2'), isTrue);
      expect(exists('card_account_cust-1'), isTrue);
      expect(exists('management_summary'), isTrue);
      expect(find.text('Hesap Ekle'), findsOneWidget);
      expect(env.cloud.calls, contains('getServiceSummary'));
    });

    testWidgets('servis personeli yalnızca müşteri hesaplarını yönetir; özet istenmez; kendi kartında dondurma yoktur',
        (tester) async {
      final env = await mgmtEnv(role: 'staff', users: <Map<String, dynamic>>[
        acct('staff-1', 'Servis Ali', role: 'service_user'),
        acct('cust-1', 'Müşteri Mehmet', status: 'pending_invite'),
        acct('super-9', 'Sızan Süper', role: 'super_user'),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);

      expect(env.cloud.calls, isNot(contains('getServiceSummary')), reason: 'özet yalnızca süper yönetici içindir');
      expect(exists('management_summary'), isFalse);
      expect(exists('chip_filter_super'), isFalse, reason: 'rol süzgeci yalnızca süperde');
      expect(find.text('Müşteri Ekle'), findsOneWidget);
      // Müşteri: tam yönetim
      expect(exists('btn_edit_cust-1'), isTrue);
      expect(exists('btn_freeze_cust-1'), isTrue);
      expect(exists('btn_send_reset_cust-1'), isTrue);
      // Kendi hesabı: düzenleme var; dondurma/bağlantı yok
      expect(exists('btn_edit_staff-1'), isTrue);
      expect(exists('btn_freeze_staff-1'), isFalse);
      expect(exists('btn_send_reset_staff-1'), isFalse);
      // Savunma amaçlı: sunucu süper hesabı yanlışlıkla gönderse bile salt okunur
      expect(exists('note_readonly_super-9'), isTrue);
      expect(exists('btn_freeze_super-9'), isFalse);
      expect(exists('btn_edit_super-9'), isFalse);
    });

    testWidgets('geçici servis oturumu sayfayı açamaz ve sunucuya istek atılmaz', (tester) async {
      final env = await mgmtEnv(role: 'pin');
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(exists('management_denied'), isTrue);
      expect(env.cloud.calls.where((c) => c.startsWith('listAdminUsers')), isEmpty);
      expect(exists('btn_add_account'), isFalse);
    });

    testWidgets('Görevler ve Araçlar sekmesi rolün kullanabildiği araçları gösterir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env, tab: 1);
      expect(exists('card_tool_setup'), isTrue);
      expect(exists('card_tool_subscribers'), isTrue);
      expect(exists('card_tool_inventory'), isTrue);
      expect(exists('card_tool_doctor'), isTrue);
      expect(exists('card_tool_management'), isFalse, reason: 'sayfanın kendisine kart konmaz');
    });

    testWidgets('sınır dışı sekme indeksi (2) son sekmeye sığdırılır', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env, tab: 2);
      expect(exists('card_tool_doctor'), isTrue);
    });
  });

  group('liste', () {
    testWidgets('sunucu hiç yanıt vermezse sonsuz dönmez: 25 sn sonra zaman aşımı hatası ve Tekrar Dene çıkar', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.adminListGate = Completer<void>();
      await openManagement(tester, env);
      expect(exists('accounts_loading'), isTrue);

      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(exists('accounts_loading'), isFalse);
      expect(exists('accounts_error'), isTrue);
      expect(find.textContaining('zaman aşımına uğradı'), findsOneWidget);

      env.cloud.adminListGate!.complete();
      await tapKey(tester, 'btn_retry');
      await settle(tester);
      expect(exists('card_account_cust-2'), isTrue);
    });

    testWidgets('rol rozetleri normalleştirilmiş rolü gösterir (büyük/küçük harf ve eski adlar)', (tester) async {
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('a', 'Ayşe', role: 'Super_User'),
        acct('b', 'Bora', role: ' SERVICE_USER '),
        acct('c', 'Can', role: 'installer'),
        acct('d', 'Deniz', role: 'user'),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      Text badge(String id) => tester.widget<Text>(find.descendant(of: find.byKey(Key('role_$id')), matching: find.byType(Text)));
      expect(badge('a').data, 'SÜPER YÖNETİCİ');
      expect(badge('b').data, 'SERVİS SORUMLUSU');
      expect(badge('c').data, 'SERVİS SORUMLUSU');
      expect(badge('d').data, 'MÜŞTERİ');
    });

    testWidgets('liste hatasında boş liste yerine hata ve Tekrar Dene gösterilir (sessiz boş liste yok)', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.adminListErrorOnce = const ApiException(statusCode: 500, code: 'INTERNAL', message: 'Sunucu şu anda yanıt veremiyor.');
      await openManagement(tester, env);

      expect(exists('accounts_error'), isTrue);
      expect(exists('accounts_empty'), isFalse);
      expect(find.text('Sunucu şu anda yanıt veremiyor.'), findsOneWidget);
      await tapKey(tester, 'btn_retry');
      await settle(tester);
      expect(exists('accounts_error'), isFalse);
      expect(exists('card_account_cust-2'), isTrue);
    });

    testWidgets('özet alınamazsa hata özet kartında görünür ve hesap listesi engellenmez', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.summaryError = const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Bu işlem için yetkiniz yok.');
      await openManagement(tester, env);
      expect(exists('summary_error'), isTrue);
      expect(exists('card_account_cust-2'), isTrue);
    });

    testWidgets('yenileme başarısız olursa eski liste uyarıyla gösterilir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      env.cloud.adminListError = const ApiException(statusCode: 0, code: 'NETWORK', message: 'Sunucuya ulaşılamadı.');
      await tapKey(tester, 'btn_refresh');
      await settle(tester);
      expect(exists('accounts_stale'), isTrue);
      expect(exists('card_account_cust-2'), isTrue);
    });

    testWidgets('liste sayfalıdır: Daha fazla yükle sonraki sayfayı ekler', (tester) async {
      final env = await mgmtEnv(users: <Map<String, dynamic>>[for (var i = 1; i <= 5; i++) acct('u$i', 'Kişi $i')]);
      addTearDown(env.dispose);
      await openManagement(tester, env, pageSize: 2);
      expect(exists('card_account_u3'), isFalse);
      await tapKey(tester, 'btn_load_more');
      await settle(tester);
      expect(env.cloud.adminQueries, <String>['|0|', '|2|']);
      expect(exists('card_account_u1'), isTrue, reason: 'önceki sayfa korunur');
      expect(exists('card_account_u3'), isTrue);
    });

    testWidgets('arama 300 ms sessiz kalınca tek istek atar; rol süzgeci rolü sunucuya iletir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      env.cloud.adminQueries.clear();

      await tester.enterText(find.byKey(const Key('field_search')), 'Zey');
      await tester.pump();
      await tester.enterText(find.byKey(const Key('field_search')), 'Zeynep');
      await tester.pump();
      env.clock.advance(const Duration(milliseconds: 299));
      await settle(tester, frames: 2);
      expect(env.cloud.adminQueries, isEmpty);
      env.clock.advance(const Duration(milliseconds: 2));
      await settle(tester);
      expect(env.cloud.adminQueries, <String>['|0|Zeynep']);
      expect(exists('card_account_cust-2'), isTrue);
      expect(exists('card_account_cust-1'), isFalse);

      await tapKey(tester, 'chip_filter_service');
      await settle(tester);
      expect(env.cloud.adminQueries.last, startsWith('service_user|0|'));
    });
  });

  group('dondurma', () {
    testWidgets('süper yönetici kendi hesabını donduramaz: düğme pasif, neden yazılı, istek yok', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      expect(buttonEnabled(tester, 'btn_freeze_super-1'), isFalse);
      expect(find.byKey(const Key('note_freeze_block_super-1')), findsOneWidget);
      expect(find.text('Kendi hesabınızı donduramazsınız.'), findsOneWidget);
      expect(env.cloud.adminUpdates, isEmpty);
    });

    testWidgets('dondurma onay ister: vazgeçince istek atılmaz; onaylayınca hesap donar ve rozet güncellenir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_freeze_cust-2');
      expect(find.text('Hesap dondurulsun mu?'), findsOneWidget);
      await tapKey(tester, 'btn_simple_cancel');
      await settle(tester);
      expect(env.cloud.adminUpdates, isEmpty);

      await tapKey(tester, 'btn_freeze_cust-2');
      await tapKey(tester, 'btn_simple_confirm');
      await settle(tester);
      expect(env.cloud.adminUpdates.single['is_active'], false);
      expect(find.descendant(of: find.byKey(const Key('status_cust-2')), matching: find.text('Donduruldu')), findsOneWidget);
      expect(exists('btn_activate_cust-2'), isTrue);
      expect(exists('btn_freeze_cust-2'), isFalse);
    });

    testWidgets('dondurulmuş hesap tek dokunuşla yeniden aktifleştirilir', (tester) async {
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('super-1', 'Yönetici', role: 'super_user'),
        acct('cust-3', 'Donuk Müşteri', active: false),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await tapKey(tester, 'btn_activate_cust-3');
      await settle(tester);
      expect(env.cloud.adminUpdates.single['is_active'], true);
      expect(exists('btn_freeze_cust-3'), isTrue);
    });

    testWidgets('son aktif süper yönetici sunucuda reddedilirse (409) hata görünür ve hesap aktif kalır', (tester) async {
      // Sayfa yalnızca ilk kaydı yüklediği için istemci kesin konuşamaz; karar sunucudadır.
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('super-2', 'Diğer Süper', role: 'super_user'),
        acct('super-1', 'Yönetici', role: 'super_user', active: false),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env, pageSize: 1);
      expect(exists('card_account_super-2'), isTrue);

      await tapKey(tester, 'btn_freeze_super-2');
      await tapKey(tester, 'btn_simple_confirm');
      await settle(tester);
      expect(find.text('Son aktif Süper Yönetici dondurulamaz veya rolü düşürülemez.'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('status_super-2')), matching: find.text('Aktif')), findsOneWidget);
    });

    testWidgets('tüm süperler yüklüyken son aktif süper için dondurma istemcide engellenir', (tester) async {
      // Yalnızca bu kayıt aktif; işlemi yapan hesap (super-1) listede yok -> istemci kesin biçimde engeller.
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('super-2', 'Tek Aktif Süper', role: 'super_user'),
        acct('super-3', 'Donuk Süper', role: 'super_user', active: false),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(buttonEnabled(tester, 'btn_freeze_super-2'), isFalse);
      expect(find.textContaining('Son aktif süper yönetici dondurulamaz'), findsOneWidget);
      expect(env.cloud.adminUpdates, isEmpty);
    });

    testWidgets('dondurma sunucu hatasında hata gösterilir ve kart değişmez', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      env.cloud.adminWriteError = const ApiException(statusCode: 500, code: 'INTERNAL', message: 'Sunucu şu anda yanıt veremiyor.');

      await tapKey(tester, 'btn_freeze_cust-2');
      await tapKey(tester, 'btn_simple_confirm');
      await settle(tester);
      expect(find.byKey(const Key('snack_friendly_error')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('status_cust-2')), matching: find.text('Aktif')), findsOneWidget);
    });
  });

  group('hesap oluşturma', () {
    testWidgets('form doğrulanır: ad, e-posta biçimi, kısa parola; hata varken istek atılmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openCreate(tester);

      await tapKey(tester, 'btn_account_save');
      expect(find.text('Ad soyad en az 2 karakter olmalıdır.'), findsOneWidget);
      expect(find.text('Lütfen e-posta adresinizi girin'), findsOneWidget);

      await typeKey(tester, 'field_account_name', 'Yeni Kişi');
      await typeKey(tester, 'field_account_email', 'gecersiz-eposta');
      await typeKey(tester, 'field_account_password', 'kisa');
      await tapKey(tester, 'btn_account_save');
      expect(find.text('Geçerli bir e-posta adresi girin'), findsOneWidget);
      expect(find.textContaining('en az 10 karakter'), findsWidgets);
      expect(env.cloud.adminCreates, isEmpty);
    });

    testWidgets('parola kırpılmaz: baş/son boşlukları olduğu gibi gönderilir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openCreate(tester);

      await tapKey(tester, 'chip_role_user');
      await typeKey(tester, 'field_account_name', 'Yeni Kişi');
      await typeKey(tester, 'field_account_email', 'yeni@ornek.test');
      await typeKey(tester, 'field_account_password', '  bosluklu parola  ');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);

      expect(env.cloud.adminCreates, hasLength(1));
      expect(env.cloud.adminCreates.single['password_had_edge_space'], isTrue);
      expect(env.cloud.adminCreates.single['password_length'], '  bosluklu parola  '.length);
      expect(exists('card_account_u-1'), isTrue, reason: 'başarıdan sonra liste yenilenir');
    });

    testWidgets('diyalog yalnızca API başarısından sonra kapanır; hatada açık kalır ve alanlar korunur', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openCreate(tester);

      await typeKey(tester, 'field_account_name', 'Yeni Kişi');
      await typeKey(tester, 'field_account_email', 'cust-1@ornek.test'); // zaten kayıtlı
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(exists('dialog_create_account'), isTrue, reason: 'hata olursa diyalog kapanmaz');
      expect(find.text('Bu e-posta adresi sistemde zaten kayıtlı.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.descendant(of: find.byKey(const Key('field_account_name')), matching: find.byType(TextField))).controller!.text,
        'Yeni Kişi',
      );

      await typeKey(tester, 'field_account_email', 'benzersiz@ornek.test');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(exists('dialog_create_account'), isFalse);
      expect(env.cloud.adminCreates, hasLength(1));
    });

    testWidgets('çift dokunuş tek hesap oluşturur ve gönderim sürerken düğme pasiftir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.adminWriteGate = Completer<void>();
      await openManagement(tester, env);
      await openCreate(tester);

      await typeKey(tester, 'field_account_name', 'Yeni Kişi');
      await typeKey(tester, 'field_account_email', 'yeni@ornek.test');
      await tapKey(tester, 'btn_account_save');
      expect(buttonEnabled(tester, 'btn_account_save'), isFalse);
      await tester.tap(find.byKey(const Key('btn_account_save')), warnIfMissed: false);
      await tester.pump();
      env.cloud.adminWriteGate!.complete();
      await settle(tester);
      expect(env.cloud.adminCreates, hasLength(1));
    });

    testWidgets('servis personeli parola alanı görmez; hesap davet bekler; bağlantı gönder çalışır', (tester) async {
      final env = await mgmtEnv(role: 'staff', users: <Map<String, dynamic>>[acct('staff-1', 'Servis Ali', role: 'service_user')]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openCreate(tester);

      expect(exists('field_account_password'), isFalse, reason: 'personel parola belirleyemez');
      expect(exists('chip_role_user'), isFalse, reason: 'personel yalnızca müşteri hesabı açar');
      await typeKey(tester, 'field_account_name', 'Yeni Müşteri');
      await typeKey(tester, 'field_account_email', 'musteri@ornek.test');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);

      expect(env.cloud.adminCreates.single['password_length'], 0);
      expect(env.cloud.adminCreates.single['role'], 'user');
      expect(find.textContaining('etkinleştirme bağlantısı musteri@ornek.test adresine gönderildi'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('status_u-1')), matching: find.text('Davet bekliyor')), findsOneWidget);

      await tapKey(tester, 'btn_send_reset_u-1');
      await settle(tester);
      expect(env.cloud.adminResets, <String>['u-1']);
      expect(find.textContaining('Hesap etkinleştirme bağlantısı musteri@ornek.test adresine gönderildi'), findsOneWidget);
    });

    testWidgets('davet e-postası gönderilemezse kullanıcı uyarılır', (tester) async {
      final env = await mgmtEnv(role: 'staff', users: <Map<String, dynamic>>[acct('staff-1', 'Servis Ali', role: 'service_user')]);
      addTearDown(env.dispose);
      env.cloud.inviteMailFails = true;
      await openManagement(tester, env);
      await openCreate(tester);
      await typeKey(tester, 'field_account_name', 'Yeni Müşteri');
      await typeKey(tester, 'field_account_email', 'musteri@ornek.test');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(find.byKey(const Key('snack_account_error')), findsOneWidget);
      expect(find.textContaining('e-postası gönderilemedi'), findsWidgets);
    });

    testWidgets('süper yönetici parola verirse ilk girişte değiştirme bilgisi gösterilir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openCreate(tester);
      await tapKey(tester, 'chip_role_user');
      await typeKey(tester, 'field_account_name', 'Yeni Kişi');
      await typeKey(tester, 'field_account_email', 'yeni@ornek.test');
      await typeKey(tester, 'field_account_password', 'uzun-gecici-parola');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(find.textContaining('İlk girişte parolasını değiştirmesi istenecek'), findsOneWidget);
    });

    testWidgets('vazgeçilirse hiçbir istek atılmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openCreate(tester);
      await typeKey(tester, 'field_account_name', 'Yeni Kişi');
      await tapKey(tester, 'btn_account_cancel');
      await settle(tester);
      expect(exists('dialog_create_account'), isFalse);
      expect(env.cloud.adminCreates, isEmpty);
    });
  });

  group('hesap düzenleme', () {
    testWidgets('başka süper yöneticinin parolası için kendi parolanız istenir: eksik, yanlış ve doğru durumları', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_edit_super-2');
      await settle(tester);
      expect(exists('field_edit_current_password'), isFalse, reason: 'parola yazılmadan istenmez');
      await typeKey(tester, 'field_edit_password', 'yeni-uzun-parola-1');
      expect(exists('field_edit_current_password'), isTrue, reason: 'başka süperin parolası: yeniden doğrulama alanı açılır');

      // Eksik
      await tapKey(tester, 'btn_account_save');
      expect(find.textContaining('kendi mevcut parolanızı girin'), findsWidgets);
      expect(env.cloud.adminUpdates, isEmpty);
      // Yanlış -> sunucu REAUTH_REQUIRED
      await typeKey(tester, 'field_edit_current_password', 'yanlis-parola-99');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(find.text('Mevcut parolanız doğrulanamadı.'), findsOneWidget);
      expect(exists('dialog_edit_account'), isTrue);
      expect(env.cloud.adminUpdates, isEmpty);
      // Doğru
      await typeKey(tester, 'field_edit_current_password', kActorPassword);
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(exists('dialog_edit_account'), isFalse);
      expect(env.cloud.adminUpdates.single['sent_current_password'], isTrue);
      expect(env.cloud.adminUpdates.single['password_length'], 'yeni-uzun-parola-1'.length);
    });

    testWidgets('normal kullanıcının parolası değişirken mevcut parola istenmez', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_edit_cust-2');
      await settle(tester);
      await typeKey(tester, 'field_edit_password', 'yeni-uzun-parola-1');
      expect(exists('field_edit_current_password'), isFalse);
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(env.cloud.adminUpdates.single['sent_current_password'], isFalse);
      expect(exists('dialog_edit_account'), isFalse);
    });

    testWidgets('yeni parola kısa ya da yalnızca boşluksa kaydedilmez; parola kırpılmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_edit_cust-2');
      await settle(tester);
      await typeKey(tester, 'field_edit_password', 'kisa');
      await tapKey(tester, 'btn_account_save');
      expect(find.textContaining('en az 10 karakter'), findsWidgets);
      await typeKey(tester, 'field_edit_password', '            ');
      await tapKey(tester, 'btn_account_save');
      expect(find.text('Şifre yalnızca boşluktan oluşamaz'), findsOneWidget);
      expect(env.cloud.adminUpdates, isEmpty);

      await typeKey(tester, 'field_edit_password', ' baş ve son boşluklu 1 ');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(env.cloud.adminUpdates.single['password_had_edge_space'], isTrue);
    });

    testWidgets('kendi hesabında parola alanı yoktur (profil ekranına yönlendirir)', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await tapKey(tester, 'btn_edit_super-1');
      await settle(tester);
      expect(exists('field_edit_password'), isFalse);
      expect(find.textContaining('profil ekranındaki'), findsOneWidget);
    });

    testWidgets('servis personeli düzenleme formunda parola alanı görmez', (tester) async {
      final env = await mgmtEnv(role: 'staff', users: <Map<String, dynamic>>[
        acct('staff-1', 'Servis Ali', role: 'service_user'),
        acct('cust-1', 'Müşteri Mehmet'),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await tapKey(tester, 'btn_edit_cust-1');
      await settle(tester);
      expect(exists('field_edit_password'), isFalse);
      expect(find.textContaining('Bağlantı gönder'), findsWidgets);
    });

    testWidgets('ad, telefon ve not güncellenir; geçersiz telefon kaydı engeller; hata olursa diyalog açık kalır', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_edit_cust-2');
      await settle(tester);
      await typeKey(tester, 'field_edit_phone', '12');
      await tapKey(tester, 'btn_account_save');
      expect(find.textContaining('5 ile başlamalıdır'), findsOneWidget);
      expect(env.cloud.adminUpdates, isEmpty);

      env.cloud.adminWriteError = const ApiException(statusCode: 500, code: 'INTERNAL', message: 'Sunucu şu anda yanıt veremiyor.');
      await typeKey(tester, 'field_edit_phone', '0555 111 22 33');
      await typeKey(tester, 'field_edit_name', 'Zeynep Yeni');
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(exists('dialog_edit_account'), isTrue);
      expect(find.text('Sunucu şu anda yanıt veremiyor.'), findsOneWidget);

      env.cloud.adminWriteError = null;
      await tapKey(tester, 'btn_account_save');
      await settle(tester);
      expect(exists('dialog_edit_account'), isFalse);
      expect(env.cloud.adminUpdates.single['full_name'], 'Zeynep Yeni');
      expect(env.cloud.adminUpdates.single['phone'], '+905551112233');
    });
  });

  group('rol değiştirme (yalnız süper)', () {
    Map<String, dynamic> deletedAcct(String id) =>
        <String, dynamic>{...acct(id, 'Silinmiş Kişi'), 'is_active': false, 'account_status': 'deleted'};

    testWidgets('süper başka hesaplarda düğmeyi görür; kendi hesabında yoktur', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(exists('btn_change_role_cust-2'), isTrue);
      expect(exists('btn_change_role_staff-1'), isTrue);
      expect(exists('btn_change_role_super-2'), isTrue);
      expect(exists('btn_change_role_super-1'), isFalse, reason: 'kendi rolünü değiştiremez (sunucu 400)');
    });

    testWidgets('servis sorumlusu hiçbir hesapta Rol Değiştir görmez', (tester) async {
      final env = await mgmtEnv(role: 'staff', users: <Map<String, dynamic>>[
        acct('staff-1', 'Servis Ali', role: 'service_user'),
        acct('cust-1', 'Müşteri Mehmet'),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(exists('btn_edit_cust-1'), isTrue, reason: 'sayfa açık, müşteriyi yönetiyor');
      expect(exists('btn_change_role_cust-1'), isFalse);
      expect(exists('btn_change_role_staff-1'), isFalse);
    });

    testWidgets('mevcut rol seçenek değildir; rol seçilmeden Devam pasif; onay adımı istek atmadan önce gelir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_change_role_cust-2');
      await settle(tester);
      expect(exists('dialog_change_role'), isTrue);
      expect(exists('chip_new_role_service_user'), isTrue);
      expect(exists('chip_new_role_super_user'), isTrue);
      expect(exists('chip_new_role_user'), isFalse, reason: 'müşteri zaten müşteri');
      expect(buttonEnabled(tester, 'btn_role_next'), isFalse);

      await tapKey(tester, 'chip_new_role_service_user');
      expect(buttonEnabled(tester, 'btn_role_next'), isTrue);
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      // Onay adımı: ne değişeceği yazılı, henüz istek yok.
      expect(exists('role_confirm_text'), isTrue);
      expect(find.textContaining('"Müşteri" iken "Servis sorumlusu" olarak değiştirilecek'), findsOneWidget);
      expect(find.textContaining('oturumları kapanır'), findsOneWidget);
      expect(env.cloud.adminUpdates, isEmpty);
    });

    testWidgets('onayla: PATCH rolü gönderir, başarı iletisi çıkar, liste yenilenir ve rozet güncellenir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_change_role_cust-2');
      await settle(tester);
      await tapKey(tester, 'chip_new_role_service_user');
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      await tapKey(tester, 'btn_role_confirm');
      await settle(tester);

      expect(env.cloud.adminUpdates, hasLength(1));
      expect(env.cloud.adminUpdates.single['id'], 'cust-2');
      expect(env.cloud.adminUpdates.single['role'], 'service_user');
      expect(exists('dialog_change_role'), isFalse);
      expect(find.text('Müşteri Zeynep hesabının rolü "Servis sorumlusu" olarak değiştirildi.'), findsOneWidget);
      expect(env.cloud.calls.where((c) => c.startsWith('listAdminUsers')).length, greaterThanOrEqualTo(2),
          reason: 'başarıdan sonra liste yenilenir');
      expect(find.descendant(of: find.byKey(const Key('role_cust-2')), matching: find.text('SERVİS SORUMLUSU')), findsOneWidget);
    });

    testWidgets('servis sorumlusundan müşteriye düşürmede evlerdeki servis üyeliklerinin kalkacağı yazılır', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await tapKey(tester, 'btn_change_role_staff-1');
      await settle(tester);
      await tapKey(tester, 'chip_new_role_user');
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      expect(find.textContaining('servis üyelikleri kaldırılır'), findsOneWidget);
    });

    testWidgets('onay adımında Geri seçime döner; Vazgeç hiçbir istek atmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);

      await tapKey(tester, 'btn_change_role_cust-2');
      await settle(tester);
      await tapKey(tester, 'chip_new_role_super_user');
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      expect(find.textContaining('tüm hesap ve dairelere erişebilir'), findsOneWidget);
      await tapKey(tester, 'btn_role_back');
      await settle(tester);
      expect(exists('chip_new_role_service_user'), isTrue);
      await tapKey(tester, 'btn_role_cancel');
      await settle(tester);
      expect(exists('dialog_change_role'), isFalse);
      expect(env.cloud.adminUpdates, isEmpty);
    });

    testWidgets('sunucu reddederse (409 son süper) hata diyalogda görünür; rol değişmez, diyalog açık kalır', (tester) async {
      // pageSize 1: yalnızca ilk kayıt yüklü -> istemci kesin konuşamaz, karar sunucudadır.
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('super-2', 'Diğer Süper', role: 'super_user'),
        acct('super-1', 'Yönetici', role: 'super_user', active: false),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env, pageSize: 1);
      expect(buttonEnabled(tester, 'btn_change_role_super-2'), isTrue);

      await tapKey(tester, 'btn_change_role_super-2');
      await settle(tester);
      await tapKey(tester, 'chip_new_role_user');
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      await tapKey(tester, 'btn_role_confirm');
      await settle(tester);

      expect(exists('dialog_change_role'), isTrue);
      expect(exists('role_change_error'), isTrue);
      expect(find.text('Son aktif Süper Yönetici dondurulamaz veya rolü düşürülemez.'), findsOneWidget);
      expect(env.cloud.adminUpdates, isEmpty);
      expect(buttonEnabled(tester, 'btn_role_confirm'), isTrue, reason: 'hata sonrası yeniden denenebilir');
    });

    testWidgets('ağ/sunucu hatasında dostça ileti gösterilir ve ham istisna metni sızmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      env.cloud.adminWriteError = Exception('SELECT * FROM users -- ham');
      await tapKey(tester, 'btn_change_role_cust-2');
      await settle(tester);
      await tapKey(tester, 'chip_new_role_service_user');
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      await tapKey(tester, 'btn_role_confirm');
      await settle(tester);
      expect(exists('role_change_error'), isTrue);
      expect(find.textContaining('SELECT'), findsNothing);
      expect(find.textContaining('Rol değiştirilemedi'), findsOneWidget);
    });

    testWidgets('çift dokunuş tek istek atar; gönderim sürerken düğme pasiftir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.adminWriteGate = Completer<void>();
      await openManagement(tester, env);
      await tapKey(tester, 'btn_change_role_cust-2');
      await settle(tester);
      await tapKey(tester, 'chip_new_role_service_user');
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      await tapKey(tester, 'btn_role_confirm');
      expect(buttonEnabled(tester, 'btn_role_confirm'), isFalse);
      await tester.tap(find.byKey(const Key('btn_role_confirm')), warnIfMissed: false);
      await tester.pump();
      env.cloud.adminWriteGate!.complete();
      await settle(tester);
      expect(env.cloud.adminUpdates, hasLength(1));
    });

    testWidgets('tüm süperler yüklüyken son aktif süper için düğmeler pasif ve neden yazılı', (tester) async {
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('super-2', 'Tek Aktif Süper', role: 'super_user'),
        acct('super-3', 'Donuk Süper', role: 'super_user', active: false),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(buttonEnabled(tester, 'btn_change_role_super-2'), isFalse);
      expect(buttonEnabled(tester, 'btn_hard_delete_super-2'), isFalse);
      expect(find.byKey(const Key('note_action_block_super-2')), findsOneWidget);
      expect(find.textContaining('Son aktif süper yönetici silinemez ve rolü değiştirilemez'), findsOneWidget);
    });

    testWidgets('silinmiş hesapta Rol Değiştir pasif, Kalıcı Sil açık', (tester) async {
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('super-1', 'Yönetici', role: 'super_user'),
        deletedAcct('gone-1'),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(buttonEnabled(tester, 'btn_change_role_gone-1'), isFalse);
      expect(buttonEnabled(tester, 'btn_hard_delete_gone-1'), isTrue);
      expect(find.text('Silinmiş hesabın rolü değiştirilemez.'), findsOneWidget);
    });
  });

  group('kalıcı silme (yalnız süper)', () {
    Future<void> openDialog(WidgetTester tester, String id) async {
      await tapKey(tester, 'btn_hard_delete_$id');
      await settle(tester);
      expect(exists('dialog_hard_delete'), isTrue);
    }

    testWidgets('süper başka hesaplarda düğmeyi görür; kendi hesabında yoktur', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(exists('btn_hard_delete_cust-2'), isTrue);
      expect(exists('btn_hard_delete_staff-1'), isTrue);
      expect(exists('btn_hard_delete_super-2'), isTrue);
      expect(exists('btn_hard_delete_super-1'), isFalse, reason: 'kendi hesabını silemez (sunucu 400)');
    });

    testWidgets('servis sorumlusu hiçbir hesapta Kalıcı Sil görmez', (tester) async {
      final env = await mgmtEnv(role: 'staff', users: <Map<String, dynamic>>[
        acct('staff-1', 'Servis Ali', role: 'service_user'),
        acct('cust-1', 'Müşteri Mehmet'),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      expect(exists('btn_freeze_cust-1'), isTrue, reason: 'sayfa açık, müşteriyi yönetiyor');
      expect(exists('btn_hard_delete_cust-1'), isFalse);
      expect(exists('btn_hard_delete_staff-1'), isFalse);
    });

    testWidgets('onaysız silinmez: onay düğmesi pasif; yanlış e-posta pasif bırakır; Vazgeç istek atmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openDialog(tester, 'cust-2');

      expect(find.textContaining('Bu işlem geri alınamaz'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('hard_delete_phrase'))).data, 'cust-2@ornek.test',
          reason: 'yazılacak ifade gösterilir');
      expect(buttonEnabled(tester, 'btn_hard_delete_confirm'), isFalse);

      await typeKey(tester, 'field_hard_delete_confirm', 'baska@ornek.test');
      expect(buttonEnabled(tester, 'btn_hard_delete_confirm'), isFalse);
      await typeKey(tester, 'field_hard_delete_confirm', 'cust-2@ornek');
      expect(buttonEnabled(tester, 'btn_hard_delete_confirm'), isFalse, reason: 'eksik yazım');

      await tapKey(tester, 'btn_hard_delete_confirm'); // pasif düğme: dokunuş etkisiz
      await settle(tester);
      expect(env.cloud.adminDeletes, isEmpty);

      await tapKey(tester, 'btn_hard_delete_cancel');
      await settle(tester);
      expect(exists('dialog_hard_delete'), isFalse);
      expect(env.cloud.adminDeletes, isEmpty);
      expect(env.cloud.calls.where((c) => c.startsWith('deleteAdminUser')), isEmpty);
    });

    testWidgets('doğru e-posta (büyük/küçük harf fark etmez) yazılınca silinir; sunucu iletisi snackbar ile gösterilir, liste yenilenir',
        (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openDialog(tester, 'cust-2');

      await typeKey(tester, 'field_hard_delete_confirm', ' CUST-2@Ornek.TEST ');
      expect(buttonEnabled(tester, 'btn_hard_delete_confirm'), isTrue);
      await tapKey(tester, 'btn_hard_delete_confirm');
      await settle(tester);

      expect(env.cloud.adminDeletes, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'cust-2', 'hard': true},
      ]);
      expect(exists('dialog_hard_delete'), isFalse);
      expect(find.text('Kullanıcı kalıcı olarak silindi.'), findsOneWidget);
      expect(exists('card_account_cust-2'), isFalse, reason: 'liste yenilenir');
      expect(exists('card_account_cust-1'), isTrue);
    });

    testWidgets('sunucunun "N daire kaydı da silindi" iletisi aynen gösterilir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.adminHardDeleteHomes = 2;
      await openManagement(tester, env);
      await openDialog(tester, 'cust-2');
      await typeKey(tester, 'field_hard_delete_confirm', 'cust-2@ornek.test');
      await tapKey(tester, 'btn_hard_delete_confirm');
      await settle(tester);
      expect(find.text('Kullanıcı kalıcı olarak silindi (üyesi ve panosu olmayan 2 daire kaydı da silindi).'), findsOneWidget);
    });

    testWidgets('409 SOLE_OWNER_WITH_DEVICES iletisi olduğu gibi gösterilir; diyalog açık kalır, hesap silinmez', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.soleOwnerWithDevices.add('cust-2');
      await openManagement(tester, env);
      await openDialog(tester, 'cust-2');
      await typeKey(tester, 'field_hard_delete_confirm', 'cust-2@ornek.test');
      await tapKey(tester, 'btn_hard_delete_confirm');
      await settle(tester);

      expect(exists('dialog_hard_delete'), isTrue);
      expect(exists('hard_delete_error'), isTrue);
      expect(
        find.text(
          'Kullanıcı, panosu olan bir dairenin tek sahibi. Kalıcı silmeden önce daireyi devredin ya da panoya acil '
          'sıfırlama yapın.',
        ),
        findsOneWidget,
      );
      expect(env.cloud.adminDeletes, isEmpty);
      expect(find.text('Kullanıcı kalıcı olarak silindi.'), findsNothing);

      await tapKey(tester, 'btn_hard_delete_cancel');
      await settle(tester);
      expect(exists('card_account_cust-2'), isTrue);
    });

    testWidgets('e-postası olmayan hesapta ad yazdırılır', (tester) async {
      final env = await mgmtEnv(users: <Map<String, dynamic>>[
        acct('super-1', 'Yönetici', role: 'super_user'),
        acct('cust-9', 'Ayşe Yılmaz', email: ''),
      ]);
      addTearDown(env.dispose);
      await openManagement(tester, env);
      await openDialog(tester, 'cust-9');
      expect(find.textContaining('hesabın adını yazın'), findsOneWidget);
      await typeKey(tester, 'field_hard_delete_confirm', 'ayşe yılmaz');
      expect(buttonEnabled(tester, 'btn_hard_delete_confirm'), isTrue);
      await tapKey(tester, 'btn_hard_delete_confirm');
      await settle(tester);
      expect(env.cloud.adminDeletes.single['id'], 'cust-9');
    });

    testWidgets('çift dokunuş tek istek atar; gönderim sürerken düğme pasiftir', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.adminWriteGate = Completer<void>();
      await openManagement(tester, env);
      await openDialog(tester, 'cust-2');
      await typeKey(tester, 'field_hard_delete_confirm', 'cust-2@ornek.test');
      await tapKey(tester, 'btn_hard_delete_confirm');
      expect(buttonEnabled(tester, 'btn_hard_delete_confirm'), isFalse);
      await tester.tap(find.byKey(const Key('btn_hard_delete_confirm')), warnIfMissed: false);
      await tester.pump();
      env.cloud.adminWriteGate!.complete();
      await settle(tester);
      expect(env.cloud.adminDeletes, hasLength(1));
    });

    testWidgets('beklenmeyen hatada dostça ileti gösterilir; ham metin sızmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      env.cloud.adminDeleteError = Exception('FATAL: kötü sorgu');
      await openManagement(tester, env);
      await openDialog(tester, 'cust-2');
      await typeKey(tester, 'field_hard_delete_confirm', 'cust-2@ornek.test');
      await tapKey(tester, 'btn_hard_delete_confirm');
      await settle(tester);
      expect(exists('hard_delete_error'), isTrue);
      expect(find.textContaining('FATAL'), findsNothing);
      expect(find.textContaining('Hesap silinemedi'), findsOneWidget);
    });
  });

  group('yerleşim', () {
    testWidgets('dar ekranda ve büyük yazıda taşma olmadan çalışır', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env, size: const Size(360, 800), textScale: 1.5);
      expect(tester.takeException(), isNull);
      expect(exists('card_account_super-1'), isTrue);
      await openCreate(tester);
      expect(exists('dialog_create_account'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rol değiştirme ve kalıcı silme pencereleri dar ekranda ve büyük yazıda taşmaz', (tester) async {
      final env = await mgmtEnv();
      addTearDown(env.dispose);
      await openManagement(tester, env, size: const Size(360, 800), textScale: 1.5);
      // Liste tembeldir: alt kart ekrana gelene dek kaydır.
      await tester.scrollUntilVisible(
        find.byKey(const Key('btn_change_role_cust-2')),
        300,
        scrollable: find.descendant(of: find.byKey(const Key('accounts_list')), matching: find.byType(Scrollable)).first,
      );

      await tapKey(tester, 'btn_change_role_cust-2');
      await settle(tester);
      await tapKey(tester, 'chip_new_role_service_user');
      await tapKey(tester, 'btn_role_next');
      await settle(tester);
      expect(exists('role_confirm_text'), isTrue);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'btn_role_cancel');
      await settle(tester);

      await tapKey(tester, 'btn_hard_delete_cust-2');
      await settle(tester);
      expect(exists('dialog_hard_delete'), isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
