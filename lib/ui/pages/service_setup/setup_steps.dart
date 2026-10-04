import 'package:flutter/foundation.dart';

/// Sihirbazın bir adımının sabit bilgisi: başlık ve "Ne yapacaksın?" maddeleri.
@immutable
class SetupStepInfo {
  const SetupStepInfo({
    required this.number,
    required this.title,
    required this.shortTitle,
    required this.instructions,
  });

  final int number;
  final String title;
  final String shortTitle;

  /// Teknik olmayan bir teknisyenin ne yapacağını adım adım anlatan maddeler.
  final List<String> instructions;
}

/// Servis kurulum sihirbazının 10 adımı (plan §4).
class SetupSteps {
  SetupSteps._();

  static const int total = 10;

  static const int preparation = 1;
  static const int identify = 2;
  static const int customer = 3;
  static const int claim = 4;
  static const int wifi = 5;
  static const int cloud = 6;
  static const int relays = 7;
  static const int shutters = 8;
  static const int buttons = 9;
  static const int handover = 10;

  static const List<SetupStepInfo> all = <SetupStepInfo>[
    SetupStepInfo(
      number: 1,
      title: 'Hazırlık',
      shortTitle: 'Hazırlık',
      instructions: <String>[
        'Telefonunuzun şarjının ve internet bağlantınızın (mobil veri veya Wi-Fi) olduğundan emin olun.',
        'Gerekenler aşağıdaki "Yanınızda olması gerekenler" listesindedir; pano elektriğe bağlı olmalı ve ışıkları yanmalı.',
        'Aşağıdaki kontrol, oturumunuzu ve sunucu bağlantısını doğrular.',
      ],
    ),
    SetupStepInfo(
      number: 2,
      title: 'Cihazı Tanı',
      shortTitle: 'Cihaz',
      instructions: <String>[
        'Pano üzerindeki etiketin karekodunu okutun.',
        'Okutamıyorsanız etiketteki seri numarasını (AHBU-...) ve 6 haneli kurulum PIN\'ini elle yazın.',
        'Sistem, cihazın kuruluma uygun olup olmadığını sunucudan kontrol eder.',
      ],
    ),
    SetupStepInfo(
      number: 3,
      title: 'Müşteri',
      shortTitle: 'Müşteri',
      instructions: <String>[
        'Cihazın bağlanacağı müşterinin e-posta adresini (veya telefonunu) yazın. Kendi hesabınızı yazamazsınız.',
        '"Kod Gönder"e basın. Müşteri 6 haneli kodu e-postasında görür ve size söyler.',
        'Kodu aşağıya yazın. Kod gelmediyse bekleme süresi bitince yeniden gönderebilirsiniz.',
      ],
    ),
    SetupStepInfo(
      number: 4,
      title: 'Daireye Bağla',
      shortTitle: 'Bağla',
      instructions: <String>[
        'Özeti kontrol edin: cihaz ve müşteri doğru mu?',
        'İsterseniz dairenin adını yazın (ör. Daire 5).',
        '"Daireye Bağla"ya basın. Sunucu cihazı müşterinin dairesine tanımlar; bu işlem geri alınamaz.',
      ],
    ),
    SetupStepInfo(
      number: 5,
      title: 'Wi-Fi Kurulumu',
      shortTitle: 'Wi-Fi',
      instructions: <String>[
        'Telefonunuzun Wi-Fi ayarlarından panonun kurulum ağına bağlanın: ağ adı aşağıda yazar, parolası pano '
            'etiketindeki "AĞ PAROLASI (AP)" satırındadır. Etiketteki ikinci karekodu telefon kamerasıyla okutup '
            '"Bağlan"a dokunursanız parolayı yazmanız gerekmez.',
        'Bu adım internet GEREKTİRMEZ: telefon "bu ağda internet yok" derse "Yine de bağlı kal" deyin; gerekirse '
            'mobil veriyi geçici olarak kapatın.',
        '"Bağlandım: Panoyu Kontrol Et"e basın. Sonra müşterinin ev Wi-Fi adını listeden seçin (ya da modem '
            'karekodunu okutun), şifresini yazıp gönderin ve pano bağlanana kadar bekleyin.',
        'Pano bağlanınca telefonunuzu kurulum ağından çıkarıp müşterinin ev Wi-Fi ağına geri alın (sonraki adım internet ister).',
      ],
    ),
    SetupStepInfo(
      number: 6,
      title: 'Bulut Bağlantısı',
      shortTitle: 'Bulut',
      instructions: <String>[
        'ÖNCE telefonunuzu panonun kurulum ağından çıkarıp müşterinin ev Wi-Fi ağına geri bağlayın (internet gerekir: '
            'cihaz anahtarı ve bulut kimliği sunucudan alınır).',
        '"Panoya Bağlan"a basın. Sistem panoya ev ağındaki adresinden bağlanır ve bulut kimliğini yazar. Pano internete '
            'çıkıp sunucuyla konuşana kadar bekler (en fazla 90 saniye).',
        'Bağlantı kurulursa sunucuda "çevrimiçi" görünür ve bu adım tamamlanır.',
      ],
    ),
    SetupStepInfo(
      number: 7,
      title: 'Röle Testi',
      shortTitle: 'Röleler',
      instructions: <String>[
        'Her röle için "Aç" ve "Kapat"a basın. Pano komuta cevap verirse işaretlenir.',
        'Lamba veya yük gerçekten yandı mı? "Evet" ya da "Hayır" deyin.',
        'Bağlı olmayan çıkışı "Kullanılmıyor" olarak işaretleyin.',
      ],
    ),
    SetupStepInfo(
      number: 8,
      title: 'Panjur Testi ve Kalibrasyon',
      shortTitle: 'Panjurlar',
      instructions: <String>[
        'Her panjur için önce yönü deneyin: "Yukarı"ya basınca panjur yukarı çıkmalı.',
        'Yön ters ise: panoda o panjurun YUKARI ve AŞAĞI kablolarını yer değiştirin ve yeniden deneyin.',
        'Sonra süreyi ölçün: panjuru en alta indirin, "Ölçümü Başlat"a basın, panjur tam açılınca "Bitti"ye basın. Süre panoya kaydedilir.',
      ],
    ),
    SetupStepInfo(
      number: 9,
      title: 'Duvar Butonları',
      shortTitle: 'Butonlar',
      instructions: <String>[
        '"Dinlemeyi Başlat"a basın, sonra duvardaki her butona sırayla basın (bir saniye basılı tutun).',
        'Pano basışı algılayınca ilgili giriş işaretlenir.',
        'Butonu bağlı olmayan girişi "Buton yok" olarak işaretleyin.',
      ],
    ),
    SetupStepInfo(
      number: 10,
      title: 'Teslim',
      shortTitle: 'Teslim',
      instructions: <String>[
        'Özet listesini kontrol edin; gerekirse not yazın.',
        'Müşteriye kurulumu gösterin ve teslimi onaylatın.',
        '"Devreye Almayı Tamamla"ya basın. Sunucu tüm testleri doğrularsa kurulum biter.',
      ],
    ),
  ];

  static SetupStepInfo of(int number) => all[(number - 1).clamp(0, total - 1)];
}
